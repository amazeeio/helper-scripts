#!/usr/bin/env bash

#
# What this script is for
# =======================
# This script will migrate a database user, access, database and contents from
# an existing cluster to a destination cluster.
#
# At the moment, this is geared towards the DBaaS, and does not support the
# Ansible Service Broker.
#
# It has been used successfully to migrate databases between Azure MariaDB clusters.
#
# There are a whole bunch of checks after the migration to check to ensure the
# migration was a success. Likely you should do additional testing as well.
#
# Requirements
# ============
# * You are logged into kubectl and have access to the NAMESPACE you want
#   to migrate.
# * You have MariaDBProviders created with root credentials in the
#   dbaas-operator namespace.
#
# Example command 1
# =================
# ./shared-to-shared-migrate-k8s-mydumper.sh \
# --destination MARIADB_PROVIDER \
# --namespace NAMESPACE \
# --consumer CONSUMER_OBJECT \
# --dry-run
#
set -euo pipefail

# Initialize our own variables:
DESTINATION_PROVIDER=""
NAMESPACE=""
CONSUMER="mariadb"
DRY_RUN=""
TIMESTAMP=$(date +%s)

# Colours.
shw_grey () {
  tput bold
	tput setaf 0
	echo "$@"
	tput sgr0
}
shw_norm () {
  tput bold
	tput setaf 9
	echo "$@"
	tput sgr0
}
shw_info () {
  tput bold
	tput setaf 4
	echo "$@"
	tput sgr0
}
shw_warn () {
  tput bold
	tput setaf 2
	echo "$@"
	tput sgr0
}
shw_err ()  {
  tput bold
	tput setaf 1
	echo "$@"
	tput sgr0
}

# Parse input arguments.
while [[ $# -gt 0 ]] ; do
  case $1 in
    -d|--destination)
    DESTINATION_PROVIDER="$2"
    shift # past argument
    shift # past value
    ;;
    -n|--namespace)
    NAMESPACE="$2"
    shift # past argument
    shift # past value
    ;;
    -c|--consumer)
    CONSUMER="$2"
    shift # past argument
    shift # past value
    ;;
    --dry-run)
    DRY_RUN="TRUE"
    shift # past argument
    ;;
    *)
		echo "Invalid Argument: $1"
		exit 3
    ;;
  esac
done

shw_grey "================================================"
shw_grey " START_TIMESTAMP='$(date +%Y-%m-%dT%H:%M:%S%z)'"
shw_grey "================================================"
shw_grey " DESTINATION_PROVIDER=$DESTINATION_PROVIDER"
shw_grey " CONSUMER=$CONSUMER"
shw_grey " NAMESPACE=$NAMESPACE"
shw_grey "================================================"

for util in kubectl jq mysql; do
	if ! command -v ${util} > /dev/null; then
		shw_err "Please install ${util}"
		exit 1
	fi
done

if [ "$DRY_RUN" ] ; then
  shw_warn "Dry run is enabled, so no network service changes will take place."
fi

# Load the existing DBaaS credentials for the project.
CONFIGMAP=$(kubectl -n "$NAMESPACE" get configmap lagoon-env --output=json)

DB_NETWORK_SERVICE=$(echo "$CONFIGMAP" | jq -er '.data.MARIADB_HOST')
if echo "$CONFIGMAP" | grep -q MARIADB_READREPLICA_HOSTS ; then
  DB_READREPLICA_HOSTS=$(echo "$CONFIGMAP" | jq -er '.data.MARIADB_READREPLICA_HOSTS')
else
  DB_READREPLICA_HOSTS=""
fi
DB_USER=$(echo "$CONFIGMAP" | jq -er '.data.MARIADB_USERNAME')
DB_PASSWORD=$(echo "$CONFIGMAP" | jq -er '.data.MARIADB_PASSWORD')
DB_NAME=$(echo "$CONFIGMAP" | jq -er '.data.MARIADB_DATABASE')
DB_NAME_LOWER=$(echo "$DB_NAME" | tr '[:upper:]' '[:lower:]')
DB_PORT=$(echo "$CONFIGMAP" | jq -er '.data.MARIADB_PORT')

shw_info "Project $NAMESPACE details:"
shw_grey "================================================"
shw_grey " DB_NETWORK_SERVICE=$DB_NETWORK_SERVICE"
shw_grey " DB_READREPLICA_HOSTS=$DB_READREPLICA_HOSTS"
shw_grey " DB_USER=$DB_USER"
shw_grey " DB_PASSWORD=$DB_PASSWORD"
shw_grey " DB_NAME=$DB_NAME"
shw_grey " DB_PORT=$DB_PORT"
shw_grey "================================================"

# Load the destination credentials from the dbaas-operator.
PROVIDER=$(kubectl -n dbaas-operator get MariaDBProvider "$DESTINATION_PROVIDER" --output=json | jq '.spec')
PROVIDER_ENVIRONMENT=$(echo "$PROVIDER" | jq -er '.environment')
PROVIDER_USER=$(echo "$PROVIDER" | jq -er '.user')
PROVIDER_PASSWORD=$(echo "$PROVIDER" | jq -er '.password')
PROVIDER_HOST=$(echo "$PROVIDER" | jq -er '.hostname')
PROVIDER_REPLICA=$(echo "$PROVIDER" | jq -er '.readReplicaHostnames[0]')
PROVIDER_PORT=$(echo "$PROVIDER" | jq -er '.port')

shw_info "Provider $DESTINATION_PROVIDER details:"
shw_grey "================================================"
shw_grey " PROVIDER_ENVIRONMENT=$PROVIDER_ENVIRONMENT"
shw_grey " PROVIDER_USER=$PROVIDER_USER"
shw_grey " PROVIDER_PASSWORD=$PROVIDER_PASSWORD"
shw_grey " PROVIDER_HOST=$PROVIDER_HOST"
shw_grey " PROVIDER_REPLICA=$PROVIDER_REPLICA"
shw_grey " PROVIDER_PORT=$PROVIDER_PORT"
shw_grey "================================================"

# Dump the database inside the CLI pod.
POD=$(kubectl -n "$NAMESPACE" get pods -o json --field-selector=status.phase=Running -l app=mydumper | jq -r '.items[0].metadata.name // empty')
if [ -z "$POD" ]; then
	shw_info "No running mydumper pod in namespace $NAMESPACE"
	shw_info "Creating MyDumper"
  kubectl -n "$NAMESPACE" create deploy --image=schnitzel/docker-mydumper mydumper -- sh -c 'while sleep 3600; do :; done'
	sleep 60 # hope for timely scheduling
	POD=$(kubectl -n "$NAMESPACE" get pods -o json --field-selector=status.phase=Running -l app=mydumper | jq -er '.items[0].metadata.name')
fi

# Ensure the destination has the schema and user created.
shw_info "> Preparing Database, User, and permissions on destination"
shw_info "================================================"
CONF_FILE="/tmp/.my.cnf-$DESTINATION_PROVIDER"
MIGRATE_FILE="/tmp/migrate.sh"
kubectl -n "$NAMESPACE" exec "$POD" -- bash -c "printf \"[client]\nhost=%s\nport=%s\nuser=%s\npassword='%s'\n\" '$PROVIDER_HOST' '$PROVIDER_PORT' '$PROVIDER_USER' '$PROVIDER_PASSWORD' > $CONF_FILE"
cat << EOF > $MIGRATE_FILE
#!/usr/bin/env bash
set -euo pipefail
echo "Creating database"
mysql --defaults-file="$CONF_FILE" -se "CREATE DATABASE IF NOT EXISTS \\\`${DB_NAME}\\\`;"
echo "Creating user"
mysql --defaults-file="$CONF_FILE" -se "CREATE USER IF NOT EXISTS \\\`${DB_USER}\\\`@'%' IDENTIFIED BY '${DB_PASSWORD}';"
echo "Grants"
mysql --defaults-file="$CONF_FILE" -se "GRANT SELECT, INSERT, UPDATE, DELETE, CREATE, DROP, REFERENCES, INDEX, ALTER, CREATE TEMPORARY TABLES, LOCK TABLES, EXECUTE, CREATE VIEW, SHOW VIEW, CREATE ROUTINE, ALTER ROUTINE, EVENT, TRIGGER ON \\\`${DB_NAME}\\\`.* TO \\\`${DB_USER}\\\`@'%';"
echo "Flush"
mysql --defaults-file="$CONF_FILE" -se "FLUSH PRIVILEGES;"
echo "Verify access"
mysql --defaults-file="$CONF_FILE" -se "SELECT * FROM mysql.db WHERE Db = '${DB_NAME_LOWER}'\\G;"
EOF
kubectl cp $MIGRATE_FILE $NAMESPACE/$POD:$MIGRATE_FILE
kubectl -n "$NAMESPACE" exec "$POD" -- bash -c "chmod 755 $MIGRATE_FILE";
kubectl -n "$NAMESPACE" exec "$POD" -- bash -c "$MIGRATE_FILE"

# Dump the database inside the CLI pod.
shw_info "> Dumping database $DB_NAME on pod $POD on host $DB_NETWORK_SERVICE"
shw_info "================================================"
kubectl -n "$NAMESPACE" exec "$POD" -- bash -c "mydumper -h '$DB_NETWORK_SERVICE' -u '$DB_USER' -p '$DB_PASSWORD' -B '$DB_NAME' --verbose 3 --outputdir /tmp/mydumper --lock-all-tables"
shw_norm "> Dump is done"
shw_norm "================================================"

# Import to new database.
shw_info "> Importing the dump into ${PROVIDER_HOST}"
shw_info "================================================"
kubectl -n "$NAMESPACE" exec "$POD" -- bash -c "time myloader -h '$PROVIDER_HOST' -u '$DB_USER' -p '$DB_PASSWORD' -B '$DB_NAME' --verbose 3 -d /tmp/mydumper --overwrite-tables"
kubectl -n "$NAMESPACE" exec "$POD" -- bash -c "rm -rf /tmp/mydumper && rm $MIGRATE_FILE && rm $CONF_FILE"
shw_norm "> Import is done"
shw_norm "================================================"

# Alter the network service(s).
shw_info "> Altering the Network Service $DB_NETWORK_SERVICE to point at $PROVIDER_HOST"
shw_info "================================================"
ORIGINAL_DB_HOST=$(kubectl -n "$NAMESPACE" get "svc/$DB_NETWORK_SERVICE" -o json | tee "/tmp/$NAMESPACE-svc.json" | jq -er '.spec.externalName')
if [ "$DRY_RUN" ] ; then
  echo "**DRY RUN** would have run:"
  echo kubectl -n "$NAMESPACE" patch "svc/$DB_NETWORK_SERVICE" -p "{\"spec\":{\"externalName\": \"$PROVIDER_HOST\"}}"
else
  kubectl -n "$NAMESPACE" patch "svc/$DB_NETWORK_SERVICE" -p "{\"spec\":{\"externalName\": \"$PROVIDER_HOST\"}}"
fi
if [ "$DB_READREPLICA_HOSTS" ]; then
  shw_info "> Altering the Network Service $DB_READREPLICA_HOSTS to point at $PROVIDER_REPLICA"
  shw_info "================================================"
  ORIGINAL_DB_READREPLICA_HOSTS=$(kubectl -n "$NAMESPACE" get "svc/$DB_READREPLICA_HOSTS" -o json | tee "/tmp/$NAMESPACE-svc-replica.json" | jq -er '.spec.externalName')
  if [ "$DRY_RUN" ] ; then
    echo "**DRY RUN** would have run"
    echo kubectl -n "$NAMESPACE" patch "svc/$DB_READREPLICA_HOSTS" -p "{\"spec\":{\"externalName\": \"$PROVIDER_REPLICA\"}}"
  else
    kubectl -n "$NAMESPACE" patch "svc/$DB_READREPLICA_HOSTS" -p "{\"spec\":{\"externalName\": \"$PROVIDER_REPLICA\"}}"
  fi
fi
# Alter the network service(s).
shw_info "> Altering the Consumerobject $CONSUMER to point at $DESTINATION_PROVIDER"
shw_info "================================================"
if [ "$DRY_RUN" ] ; then
  echo "**DRY RUN** would have run:"
  echo kubectl -n "$NAMESPACE" patch mariadbconsumer/$CONSUMER --type='json' -p="[{\"op\": \"replace\", \"path\": \"/spec/environment\", \"value\":\"$PROVIDER_ENVIRONMENT\"},{\"op\": \"replace\", \"path\": \"/spec/provider/name\", \"value\":\"$DESTINATION_PROVIDER\"},{\"op\": \"replace\", \"path\": \"/spec/provider/hostname\", \"value\":\"$PROVIDER_HOST\"},{\"op\": \"replace\", \"path\": \"/spec/provider/readReplicas/0\", \"value\":\"$PROVIDER_REPLICA\"}]"
else
  kubectl -n "$NAMESPACE" patch mariadbconsumer/$CONSUMER --type='json' -p="[{\"op\": \"replace\", \"path\": \"/spec/environment\", \"value\":\"$PROVIDER_ENVIRONMENT\"},{\"op\": \"replace\", \"path\": \"/spec/provider/name\", \"value\":\"$DESTINATION_PROVIDER\"},{\"op\": \"replace\", \"path\": \"/spec/provider/hostname\", \"value\":\"$PROVIDER_HOST\"},{\"op\": \"replace\", \"path\": \"/spec/provider/readReplicas/0\", \"value\":\"$PROVIDER_REPLICA\"}]"
fi

# Unsure what if any delay there is in this to take effect, but 1 second sounds
# completely reasonable.
sleep 1

# Verify the correct RDS cluster.
#shw_info "> Output the Database cluster that Drush is connecting to"
#shw_info "================================================"
#kubectl -n "$NAMESPACE" exec "$POD" -- bash -c "drush sqlq 'SELECT @@aurora_server_id;'"

# # Drush status.
# shw_info "> Drush status"
# shw_info "================================================"
# kubectl -n "$NAMESPACE" exec "$POD" -- bash -c "drush status"

# Get routes, and ensure a cache bust works.
ROUTE=$(kubectl -n "$NAMESPACE" get ingress -o json | jq -er '.items[0].spec.rules[0].host')
shw_info "> Testing the route https://${ROUTE}/?${TIMESTAMP}"
shw_info "================================================"
curl -skLIXGET "https://${ROUTE}/?${TIMESTAMP}" \
  -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_14_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/79.0.3945.130 Safari/537.36" \
  --cookie "NO_CACHE=1" | grep -iE "HTTP|Cache|Location|LAGOON" || true

shw_grey "================================================"
shw_grey ""
shw_grey "In order to rollback this change, edit the Network Service(s) like so:"
shw_grey ""
shw_grey "kubectl -n $NAMESPACE patch svc/$DB_NETWORK_SERVICE -p '{\"spec\":{\"externalName\": \"$ORIGINAL_DB_HOST\"}}'"
if [ "$DB_READREPLICA_HOSTS" ]; then
  shw_grey "kubectl -n $NAMESPACE patch svc/$DB_READREPLICA_HOSTS -p '{\"spec\":{\"externalName\": \"$ORIGINAL_DB_READREPLICA_HOSTS\"}}'"
fi

shw_info "> Removing Mydumper"
shw_info "================================================"
kubectl -n $NAMESPACE delete deploy mydumper

echo ""
shw_grey "================================================"
shw_grey " END_TIMESTAMP='$(date +%Y-%m-%dT%H:%M:%S%z)'"
shw_grey "================================================"
shw_norm "Done in $SECONDS seconds"
exit 0

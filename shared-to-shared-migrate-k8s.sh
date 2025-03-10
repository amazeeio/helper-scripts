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
# ./shared-to-shared-migrate-k8s.sh \
# --destination MARIADB_PROVIDER \
# --namespace NAMESPACE \
# --dry-run
#
set -euo pipefail

# Initialize our own variables:
DESTINATION_PROVIDER=""
NAMESPACE=""
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

# check for secret or configmap
if kubectl -n "$NAMESPACE" get secret lagoon-env &> /dev/null; then
  LAGOONENV=$(kubectl -n "$NAMESPACE" get secret lagoon-env --output=json | jq -cr '.data | map_values(@base64d)')
else
  LAGOONENV=$(kubectl -n "$NAMESPACE" get configmap lagoon-env --output=json | jq -cr '.data')
fi

DB_NETWORK_SERVICE=$(echo "$LAGOONENV" | jq -er '.MARIADB_HOST')
if echo "$LAGOONENV" | grep -q MARIADB_READREPLICA_HOSTS ; then
  DB_READREPLICA_HOSTS=$(echo "$LAGOONENV" | jq -er '.MARIADB_READREPLICA_HOSTS')
else
  DB_READREPLICA_HOSTS=""
fi
DB_USER=$(echo "$LAGOONENV" | jq -er '.MARIADB_USERNAME')
DB_PASSWORD=$(echo "$LAGOONENV" | jq -er '.MARIADB_PASSWORD')
DB_NAME=$(echo "$LAGOONENV" | jq -er '.MARIADB_DATABASE')
DB_NAME_LOWER=$(echo "$DB_NAME" | tr '[:upper:]' '[:lower:]')
DB_PORT=$(echo "$LAGOONENV" | jq -er '.MARIADB_PORT')
LAGOON_PROJECT=$(echo "$LAGOONENV" | jq -er '.LAGOON_PROJECT')
LAGOON_ENVIRONMENT_TYPE=$(echo "$LAGOONENV" | jq -er '.LAGOON_ENVIRONMENT_TYPE')
LAGOON_GIT_BRANCH=$(echo "$LAGOONENV" | jq -er '.LAGOON_GIT_BRANCH')
LAGOON_GIT_SAFE_BRANCH=$(echo "$LAGOONENV" | jq -er '.LAGOON_GIT_SAFE_BRANCH')

shw_info "Project $NAMESPACE details:"
shw_grey "================================================"
shw_grey " DB_NETWORK_SERVICE=$DB_NETWORK_SERVICE"
shw_grey " DB_READREPLICA_HOSTS=$DB_READREPLICA_HOSTS"
shw_grey " DB_USER=$DB_USER"
shw_grey " DB_PASSWORD=$DB_PASSWORD"
shw_grey " DB_NAME=$DB_NAME"
shw_grey " DB_PORT=$DB_PORT"
shw_grey " LAGOON_PROJECT=$LAGOON_PROJECT"
shw_grey " LAGOON_ENVIRONMENT_TYPE=$LAGOON_ENVIRONMENT_TYPE"
shw_grey " LAGOON_GIT_BRANCH=$LAGOON_GIT_BRANCH"
shw_grey " LAGOON_GIT_SAFE_BRANCH=$LAGOON_GIT_SAFE_BRANCH"
shw_grey "================================================"

# Load the destination credentials from the dbaas-operator.
PROVIDER=$(kubectl -n dbaas-operator get MariaDBProvider "$DESTINATION_PROVIDER" --output=json | jq '.spec')
PROVIDER_USER=$(echo "$PROVIDER" | jq -er '.user')
PROVIDER_PASSWORD=$(echo "$PROVIDER" | jq -er '.password')
PROVIDER_HOST=$(echo "$PROVIDER" | jq -er '.hostname')
PROVIDER_REPLICA=$(echo "$PROVIDER" | jq -er '.readReplicaHostnames[0]')
PROVIDER_PORT=$(echo "$PROVIDER" | jq -er '.port')

shw_info "Provider $DESTINATION_PROVIDER details:"
shw_grey "================================================"
shw_grey " PROVIDER_USER=$PROVIDER_USER"
shw_grey " PROVIDER_PASSWORD=$PROVIDER_PASSWORD"
shw_grey " PROVIDER_HOST=$PROVIDER_HOST"
shw_grey " PROVIDER_REPLICA=$PROVIDER_REPLICA"
shw_grey " PROVIDER_PORT=$PROVIDER_PORT"
shw_grey "================================================"

# Find the CLI pod
POD=$(kubectl -n "$NAMESPACE" get pods -o json --field-selector=status.phase=Running -l lagoon.sh/service=cli | jq -r '.items[0].metadata.name // empty')
if [ -z "$POD" ]; then
	shw_warn "No running cli pod in namespace $NAMESPACE"
	shw_warn "Scaling up 1 CLI pod"
	kubectl -n "$NAMESPACE" scale deployment cli --current-replicas=0 --replicas=1 --timeout=2m
	sleep 32 # hope for timely scheduling
	POD=$(kubectl -n "$NAMESPACE" get pods -o json --field-selector=status.phase=Running -l lagoon.sh/service=cli | jq -er '.items[0].metadata.name')
fi

shw_info "CLI pod details:"
shw_grey "================================================"
shw_grey " POD=$POD"
shw_grey "================================================"

# Dump the database inside the CLI pod.
shw_info "> Dumping database $DB_NAME on pod $POD on host $DB_NETWORK_SERVICE"
shw_info "================================================"
kubectl -n "$NAMESPACE" exec "$POD" -- bash -c "mkdir -p /app/\$WEBROOT/sites/default/files/private/"
kubectl -n "$NAMESPACE" exec "$POD" -- bash -c "time mysqldump --max-allowed-packet=500M --events --routines --quick --add-locks --no-autocommit --single-transaction --no-create-db --no-tablespaces -h '$DB_NETWORK_SERVICE' -u '$DB_USER' -p'$DB_PASSWORD' '$DB_NAME' > /app/\$WEBROOT/sites/default/files/private/migration.sql"
kubectl -n "$NAMESPACE" exec "$POD" -- bash -c "ls -lh /app/\$WEBROOT/sites/default/files/private/migration.sql"
kubectl -n "$NAMESPACE" exec "$POD" -- bash -c "head -n 5 /app/\$WEBROOT/sites/default/files/private/migration.sql"
kubectl -n "$NAMESPACE" exec "$POD" -- bash -c "tail -n 5 /app/\$WEBROOT/sites/default/files/private/migration.sql"
shw_norm "> Dump is done"
shw_norm "================================================"

# Scale dbaas down.
shw_info "> Scaling dbaas down, and delete MariaDBConsumer (without deleting the database)"
shw_info "================================================"
shw_warn "scaling dbaas down"
kubectl -n dbaas-operator scale deployment dbaas-operator --replicas=0 --timeout=2m
shw_warn "patching MariaDBConsumer"
kubectl -n "$NAMESPACE" patch MariaDBConsumer mariadb -p '{"metadata":{"finalizers":null}}' --type=merge
shw_warn "deleting MariaDBConsumer"
kubectl -n "$NAMESPACE" delete MariaDBConsumer mariadb
shw_warn "scaling dbaas up"
kubectl -n dbaas-operator scale deployment dbaas-operator --replicas=1 --timeout=2m

# Create new consumer object.
shw_info "> Create new MariaDBConsumer object"
shw_info "================================================"
CONSUMER="/tmp/consumer.yaml"
cat << EOF > $CONSUMER
apiVersion: mariadb.amazee.io/v1
kind: MariaDBConsumer
metadata:
  namespace: $NAMESPACE
  name: mariadb
  annotations:
    lagoon.sh/branch: "$LAGOON_GIT_BRANCH"
    lagoon.sh/version: "21.8.0"
  labels:
    app.kubernetes.io/instance: mariadb
    app.kubernetes.io/managed-by: Helm
    app.kubernetes.io/name: mariadb-dbaas
    helm.sh/chart: mariadb-dbaas-0.1.0
    lagoon.sh/buildType: branch
    lagoon.sh/environment: $LAGOON_GIT_BRANCH
    lagoon.sh/environmentType: $LAGOON_ENVIRONMENT_TYPE
    lagoon.sh/project: $LAGOON_PROJECT
    lagoon.sh/service: mariadb
    lagoon.sh/service-type: mariadb-dbaas
spec:
  environment: $DESTINATION_PROVIDER
EOF
kubectl -n "$NAMESPACE" apply -f $CONSUMER

# Query the consumer, get the new credentials
sleep 10
shw_info "> See if the new database has been created."
shw_info "================================================"
NEW_DB_NAME=$(kubectl -n "$NAMESPACE" get MariaDBConsumer mariadb -o json | jq -r '.spec.consumer.database // empty')
while [ -z "$NEW_DB_NAME" ]; do
  shw_warn "No new database found in $NAMESPACE"
  sleep 10
  NEW_DB_NAME=$(kubectl -n "$NAMESPACE" get MariaDBConsumer mariadb -o json | jq -r '.spec.consumer.database // empty')
done
shw_info "> New database name ${NEW_DB_NAME}"

# Allow the CLI pod to query the new database.
shw_info "> Allow the CLI pod to query the new database"
shw_info "================================================"
CONF_FILE="/tmp/.my.cnf-$DESTINATION_PROVIDER"
kubectl -n "$NAMESPACE" exec "$POD" -- bash -c "printf \"[client]\nhost=%s\nport=%s\nuser=%s\npassword='%s'\n\" '$PROVIDER_HOST' '$PROVIDER_PORT' '$PROVIDER_USER' '$PROVIDER_PASSWORD' > $CONF_FILE"

# Import the database dump into the new database.
shw_info "> Importing the database dump into ${PROVIDER_HOST}."
shw_info "================================================"
kubectl -n "$NAMESPACE" exec "$POD" -- bash -c "time mysql --defaults-file='$CONF_FILE' '$NEW_DB_NAME' < /app/\$WEBROOT/sites/default/files/private/migration.sql"

# Create the ENV VAR to tell dbaas about the correct provider.
shw_info "> Create the ENV VAR to tell dbaas about the correct provider"
shw_info "================================================"
lagoon -l amazeeio add variable -p $LAGOON_PROJECT -e "$LAGOON_GIT_BRANCH" --name LAGOON_DBAAS_ENVIRONMENT_TYPES --scope global --value "mariadb:${DESTINATION_PROVIDER}"

# Deploy the project.
shw_info "> Deploy the project"
shw_info "================================================"
lagoon -l amazeeio deploy latest -p $LAGOON_PROJECT -e "$LAGOON_GIT_BRANCH" --force


# lagoon list deployments -p $LAGOON_PROJECT -e "$LAGOON_GIT_BRANCH" --no-header | head

# Unsure what if any delay there is in this to take effect, but 1 second sounds
# completely reasonable.
shw_info "> Waiting for 5 minutes."
sleep 300

# Find the CLI pod
POD=$(kubectl -n "$NAMESPACE" get pods -o json --field-selector=status.phase=Running -l lagoon.sh/service=cli | jq -r '.items[0].metadata.name // empty')
if [ -z "$POD" ]; then
  shw_warn "No running cli pod in namespace $NAMESPACE"
  shw_warn "Scaling up 1 CLI pod"
  kubectl -n "$NAMESPACE" scale deployment cli --current-replicas=0 --replicas=1 --timeout=2m
  sleep 32 # hope for timely scheduling
  POD=$(kubectl -n "$NAMESPACE" get pods -o json --field-selector=status.phase=Running -l lagoon.sh/service=cli | jq -er '.items[0].metadata.name')
fi

shw_info "CLI pod details:"
shw_grey "================================================"
shw_grey " POD=$POD"
shw_grey "================================================"

# Verify the correct RDS cluster.
shw_info "> Output the Database cluster that Drush is connecting to"
shw_info "================================================"
kubectl -n "$NAMESPACE" exec "$POD" -- bash -c "drush sqlq 'SELECT @@aurora_server_id;'"

# Drush status.
shw_info "> Drush status"
shw_info "================================================"
kubectl -n "$NAMESPACE" exec "$POD" -- bash -c "drush status"

# Get routes, and ensure a cache bust works.
ROUTE=$(kubectl -n "$NAMESPACE" get ingress -o json | jq -er '.items[0].spec.rules[0].host')
shw_info "> Testing the route https://${ROUTE}/?${TIMESTAMP}"
shw_info "================================================"
curl -skLIXGET "https://${ROUTE}/?${TIMESTAMP}" \
  -A "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_14_6) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/79.0.3945.130 Safari/537.36" \
  --cookie "NO_CACHE=1" | grep -iE "HTTP|Cache|Location|LAGOON" || true

echo ""
shw_grey "================================================"
shw_grey " END_TIMESTAMP='$(date +%Y-%m-%dT%H:%M:%S%z)'"
shw_grey "================================================"
shw_norm "Done in $SECONDS seconds"
exit 0

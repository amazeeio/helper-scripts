#!/bin/bash

set -eu -o pipefail

#
# Migrate Namespace between two Kubernetes Clusters, this is tested for ASK where it's easily possible to mount persistent storage from two clusters in the same region
# this might not work for EKS or GKE.
#
# Prework needed for this to work
# - add vnet of destination cluster to databases access (or the destination namespace will not be able to talk to the DataBases)
#

usage() {
  echo "Usage: ./migrate-between-clusters.sh -n drupal-example2-test9-master -s amazeeio-test9 -d amazeeio-test10"
  echo "Options:"
  echo "  -n <NAMESPACE>              #required, which namespace should be migrated"
  echo "  -s <SOURCE_CONTEXT>         #required, source context - needs to be a context in your kubeconfig"
  echo "  -d <DESTINATION_CONTEXT>    #required, destination context - needs to be a context in your kubeconfig"
  echo "  -z skip                     #optional, should the scaledown of source deployments be skipped, by default enabled"
  exit 1
}

if [[ ! $@ =~ ^\-.+ ]]
then
  usage
fi

SKIP_SOURCE_SCALEDOWN=false

while getopts ":n:s:d:z:i::" opt; do
  case ${opt} in
    n ) # process option n
      NAMESPACE=$OPTARG;;
    s ) # process option s
      SOURCE=$OPTARG;;
    d ) # process option d
      DESTINATION=$OPTARG;;
    z ) # process option z
      SKIP_SOURCE_SCALEDOWN=$OPTARG;;
    h )
      usage;;
    *)
      usage;;
  esac
done

if [[ -z "$NAMESPACE" || -z "$SOURCE" || -z "$DESTINATION" ]]; then
  usage
fi

set -v


# Export Ingress, we need them separately later
kubectl --context="$SOURCE" get -n "$NAMESPACE" ingresses -o json > "$NAMESPACE-original-ingress.json"

# delete autogenerated Ingress, lagoon will create the non-suffixed again during a deployment
cat "$NAMESPACE-original-ingress.json" | jq '.items[]|select(.metadata.labels."lagoon.sh/autogenerated"=="true")' --raw-output | kubectl --context="$DESTINATION" -n "$NAMESPACE" delete -f -

# Remove the metadata/annotations/kubectl.kubernetes.io/last-applied-configuration annotation of lagoon managed objects, as they could cuase an error the next time we lagoon deploy
LAGOON_MANAGED_RESOURCES=$(kubectl --context="$DESTINATION" -n "$NAMESPACE" -l lagoon.sh/project get service,deployment,secret,ingress,configmap,cronjobs,mariadbconsumers,mongodbconsumers,postgresqlconsumers,horizontalpodautoscalers,poddisruptionbudgets -o name)
if [[ ! -z "$LAGOON_MANAGED_RESOURCES" ]]; then
  kubectl --context="$DESTINATION" -n "$NAMESPACE" patch $LAGOON_MANAGED_RESOURCES --type json -p '[{"op": "remove", "path": "/metadata/annotations/kubectl.kubernetes.io~1last-applied-configuration"}]'
fi

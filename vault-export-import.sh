#!/usr/bin/env bash
set -e -u -o pipefail

usage() {
  echo "Usage: ./export-import.sh -s c-still-bush-3704 -d c-amazeeio-test1 -t XXXXXX -a XXXXXX"
  echo "Options:"
  echo "  -s <SOURCE CLUSTER ID>       #required, cluster id of the source VAULT"
  echo "  -d <DESTINATION CLUSTER ID>  #required, cluster id of the destination VAULT"
  echo "  -t <SOURCE VAULT TOKEN>      #required, token of the source SYN"
  echo "  -a <DESTINATION VAULT TOKEN> #required, token of the destination SYN"
  exit 1
}

if [[ ! $@ =~ ^\-.+ ]]
then
  usage
fi

while getopts ":s:d:t:a:" opt; do
  case ${opt} in
    s ) # process option s
      SOURCE_CLUSTER_ID=$OPTARG;;
    d ) # process option d
      DESTINATION_CLUSTER_ID=$OPTARG;;
    t ) # process option t
      SOURCE_VAULT_TOKEN=$OPTARG;;
    a ) # process option a
      DESTINATION_VAULT_TOKEN=$OPTARG;;
    h )
      usage;;
    *)
      usage;;
  esac
done

mkdir -p $SOURCE_CLUSTER_ID

SOURCE_TENANT_ID=t-ja3px4

SOURCE_VAULT_ADDR=https://vault-prod.syn.vshn.net
VAULT_FORMAT=json

vault login -address=$SOURCE_VAULT_ADDR $SOURCE_VAULT_TOKEN > /dev/null

vault_base="clusters/kv/${SOURCE_TENANT_ID}/${SOURCE_CLUSTER_ID}"

vault kv list -address=$SOURCE_VAULT_ADDR  "$vault_base"  | \
jq -r '.[]' | \
grep -v -e '^steward$' | \
while read -r key; do
  echo "exporting $SOURCE_CLUSTER_ID/$key"
  vault  kv get -address=$SOURCE_VAULT_ADDR "${vault_base}/${key}" | \
    jq -r '.data.data' > "$SOURCE_CLUSTER_ID/${key}.json"
done

DESTINATION_TENANT_ID=t-amazeeio

DESTINATION_VAULT_ADDR=https://vault.syn.amazeeio.cloud > /dev/null

vault login -address=$DESTINATION_VAULT_ADDR $DESTINATION_VAULT_TOKEN

vault_base="clusters/kv/${DESTINATION_TENANT_ID}/${DESTINATION_CLUSTER_ID}"

find $SOURCE_CLUSTER_ID -maxdepth 1 -type f -name "*.json" -exec basename -s .json "{}" \; | \
while read -r key; do
  echo "importing ${DESTINATION_CLUSTER_ID}/$key"
  vault kv put -address=$DESTINATION_VAULT_ADDR "${vault_base}/${key}" "@$SOURCE_CLUSTER_ID/${key}.json"
done
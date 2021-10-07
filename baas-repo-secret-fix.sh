#!/bin/bash

##############
#
# Usage:
#   first log in to the cluster you need to check, then run the following in dry-run mode (default)
#   PROJECT_SECRET="abcdefg123456" ./baas-repo-secret-fix.sh
#   
#   if everything looks good, you can run it with dry-run mode disabled
#   PROJECT_SECRET="abcdefg123456" DRY_RUN=false ./baas-repo-secret-fix.sh
#

DRY_RUN="${DRY_RUN:-"true"}"

# Some variables
PROJECT_SECRET="${PROJECT_SECRET:-""}"

if [ -z $PROJECT_SECRET ]; then
    echo PROJECT_SECRET not defined
    exit 1
fi

LAGOON_PROJECTS=()
for lp in $(kubectl get namespaces -l lagoon.sh/project -o json | jq -r '.items | .[].metadata.labels."lagoon.sh/project"' | sort -u)
do
    PROJECT_NAME=$lp
    echo "> checking environments for project $PROJECT_NAME"
    BAAS_REPO_PW=$(echo -n "$(echo -n "${PROJECT_NAME}-${PROJECT_SECRET}" | sha256sum | awk '{print $1}')-BAAS-REPO-PW" | sha256sum | awk '{print $1}')
    BAAS_REPO_PW_B64=$(echo -n "${BAAS_REPO_PW}" | base64)
    PROJECT_NAMESPACES=($(kubectl get namespaces -l lagoon.sh/project=$PROJECT_NAME --no-headers | awk '{print $1}'))
    NUM_NAMESPACES=${#PROJECT_NAMESPACES[@]}
    COUNT=0
    NAMESPACES_TO_FIX=()
    for ns in ${PROJECT_NAMESPACES[@]}
    do
        echo "=> checking $ns"
        if kubectl -n ${ns} get secret baas-repo-pw &> /dev/null
        then
            NS_BAAS_REPO_PW_B64=$(kubectl -n $ns get secret baas-repo-pw -o json | jq -r '.data."repo-pw"')
            if [ "${BAAS_REPO_PW_B64}" != "${NS_BAAS_REPO_PW_B64}" ]
            then
                echo "   baas-repo-pw in $ns differs"
                echo "   should be:    ${BAAS_REPO_PW_B64}"
                echo "   currently is: ${NS_BAAS_REPO_PW_B64}"
                NAMESPACES_TO_FIX+=($ns)
            else
                echo "   $ns is ok"
                ((COUNT=COUNT+1))
            fi
        fi
    done
    if [ "$COUNT" == "0" ]
    then
        LAGOON_PROJECTS+=($PROJECT_NAME)
    elif [ "$COUNT" != "$NUM_NAMESPACES" ]
    then
        for ns in ${NAMESPACES_TO_FIX[@]}
        do
            if [ "${DRY_RUN}" == "false" ]
            then
                echo "==> fixing $ns baas-repo-pw"
                kubectl -n $ns patch secret baas-repo-pw --type='json' -p='[{"op":"replace" ,"path":"/data/repo-pw" ,"value":"'${BAAS_REPO_PW_B64}'"}]'
            else
                echo "==> secret would be fixed if DRY_RUN=false"
            fi
        done
    fi
done
for lp in ${LAGOON_PROJECTS[@]}
do
    echo "> $lp had all incorrect baas-repo-pws, will need to be fixed manually by changing the restic repo password"
done
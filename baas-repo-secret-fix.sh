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
ONLY_SHOW_BROKEN="${ONLY_SHOW_BROKEN:-"false"}"

# Some variables
PROJECT_SECRET="${PROJECT_SECRET:-""}"

if [ -z $PROJECT_SECRET ]
then
    echo PROJECT_SECRET not defined
    exit 1
fi

echo "Getting inofrmation from the k8s cluster..."

# Get all baas-repo-pw values from the cluster for all namespaces
ALL_BAAS_REPO_PWS=$(kubectl get secret --all-namespaces --field-selector type=Opaque --field-selector metadata.name=baas-repo-pw --output json | jq '.items | [ map(.) | .[] | {(.metadata.namespace): {"repo-pw": .data."repo-pw"}}] | add')
# Output should be "{<namespace_name>: {repo_pw: <repo_password>}, ...}"

#ALL_BAAS_REPO_PWS=$(kubectl get secret --all-namespaces --field-selector type=Opaque --field-selector metadata.name=baas-repo-pw --output json | jq '.items | [ map(.) | .[] | {"repo-pw": .data."repo-pw", "namespace": .metadata.namespace}]')
# Output should be "[{repo_pw: <repo_password>, namespace: <namespace_name>}, ...]"

# Get all project names from the cluster for all namespaces
ALL_NS_PROJECTS=$(kubectl get namespaces -l lagoon.sh/project -o json | jq '.items | [ map(.) | .[] | {(.metadata.name): {project: .metadata.labels."lagoon.sh/project", namespace: .metadata.name}}] | add')
# Output should be "{<namespace_name>: {project: <lagoon_project>,  namespace: <namespace_name>}, ...}"

# Get all project names from the cluster for all namespaces
#ALL_NS_PROJECTS=$(kubectl get namespaces -l lagoon.sh/project -o json | jq '.items | [ map(.) | .[] | { project: .metadata.labels."lagoon.sh/project", namespace: .metadata.name}]')
# Output should be "[{project: <project>, namespace: <namespace_name>}, ...]"

ALL_PWS_WITH_PROJECTS=$(echo ${ALL_BAAS_REPO_PWS} ${ALL_NS_PROJECTS} | jq -s '.[0] * .[1]')

LAGOON_PROJECTS=()
BAD_PROJECTS=()
BAD_NAMESPACES=()
# Iterate over each ns and determine which ones are bad
for ns in $(echo ${ALL_PWS_WITH_PROJECTS} | jq -r 'keys[]')
do
    PROJECT_NAME=$(echo ${ALL_PWS_WITH_PROJECTS} | jq -r ".\"${ns}\".project")
    NS_BAAS_REPO_PW_B64=$(echo ${ALL_PWS_WITH_PROJECTS} | jq -r ".\"${ns}\".\"repo-pw\"")
    NS_BAAS_REPO_PW=$(echo -n ${NS_BAAS_REPO_PW_B64} | base64 -d)
    BAAS_REPO_PW=$(echo -n "$(echo -n "${PROJECT_NAME}-${PROJECT_SECRET}" | sha256sum | awk '{print $1}')-BAAS-REPO-PW" | sha256sum | awk '{print $1}')
    BAAS_REPO_PW_B64=$(echo -n ${BAAS_REPO_PW} | base64)

    if [ ${NS_BAAS_REPO_PW_B64} == "null" ]
    then
        # If we get here, the namespace is missing a `baas-repo-pw`, and can be ignored altogether
        if [ "${ONLY_SHOW_BROKEN}" == "false" ]
        then
            echo "=> ${ns} is missing a value and can be ignored!"
        fi
    elif [ "${NS_BAAS_REPO_PW_B64}" != "${BAAS_REPO_PW_B64}" ]
    then   
        # If we get this far, we know this namespace has a `baas-repo-pw` secret set, and it's different than we expected

        # Add this namespace name to array of Lagoon project names with incorrect secret values
        BAD_PROJECTS+=($PROJECT_NAME)

        # Add this namespace name to array of namespaces with incorrect secret values
        BAD_NAMESPACES+=($ns)
    else
        # If we get here, we know this namespace has a `baas-repo-pw` set, and it's correct
        if [ "${ONLY_SHOW_BROKEN}" == "false" ]
        then
            echo "=> ${ns} is setup correctly!"
        fi
    fi
done

# Filter the BAD_PROJECTS array to ensure all values are unique
NOT_TOTALLY_WRONG_NAMESPACES=()
echo "Checking for totally wrong projects..."
BAD_PROJECTS_UNIQUE=$(echo "${BAD_PROJECTS[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' ')
for lp in ${BAD_PROJECTS_UNIQUE[@]}
do
    # Get a list of all cluster namespaces applicable to this project
    PROJECT_NAMESPACES=$(echo ${ALL_PWS_WITH_PROJECTS} | jq -r ".[] | .. | select(.project? | test(\"^${lp}$\")) | .namespace")

    # Check all namespaces for this project to see if any have the correct secret value set
    CORRECT="false"
    for proj_ns in ${PROJECT_NAMESPACES[@]}
    do
        if [[ ! " ${BAD_NAMESPACES[*]} " =~ " ${proj_ns} " ]]
        then
            # At least one namespace has the correct secret value set
            CORRECT="true"
        fi
    done

    # If no namespaces have the correct secret value set, we need to mark this project as a project which has all incorrect values set (meaning the restic repo keys will need to be updated)
    if [ ${CORRECT} == "false" ]
    then
        echo "> ${lp} has all incorrect baas-repo-pws, will need to be fixed manually by changing the restic repo password"
    else
        # Identify any namespaces which have a wrong password secret, but do not belong to a Lagoon project with envs which all have incorrect passwords secret values
        for proj_ns in ${PROJECT_NAMESPACES[@]}
        do
            if [[ " ${BAD_NAMESPACES[*]} " =~ " ${proj_ns} " ]]
            then
                NOT_TOTALLY_WRONG_NAMESPACES+=($proj_ns)
            fi
        done
    fi
done

# Iterate over the bad namspaces and print out those which have at least one environment set correctly
for ns in ${NOT_TOTALLY_WRONG_NAMESPACES[@]}
do
    PROJECT_NAME=$(echo ${ALL_PWS_WITH_PROJECTS} | jq -r ".\"${ns}\".project")
    NS_BAAS_REPO_PW_B64=$(echo ${ALL_PWS_WITH_PROJECTS} | jq -r ".\"${ns}\".\"repo-pw\"")
    NS_BAAS_REPO_PW=$(echo -n ${NS_BAAS_REPO_PW_B64} | base64 -d)
    BAAS_REPO_PW=$(echo -n "$(echo -n "${PROJECT_NAME}-${PROJECT_SECRET}" | sha256sum | awk '{print $1}')-BAAS-REPO-PW" | sha256sum | awk '{print $1}')
    BAAS_REPO_PW_B64=$(echo -n ${BAAS_REPO_PW} | base64)

    # No testing needed, as we've already done that elsewhere
    echo "=> ${ns} has an issue!"
    echo "   baas-repo-pw in ${ns} differs"
    echo -n "   should be:    ${BAAS_REPO_PW_B64} / "
    echo -n "${BAAS_REPO_PW_B64}" | base64 -d 
    echo ""
    echo "   currently is: ${NS_BAAS_REPO_PW_B64} / "
    echo -n "${NS_BAAS_REPO_PW_B64}" | base64 -d
    echo ""

    # Actually fix the issue (if flag is set)
    if [ "${DRY_RUN}" == "false" ]
    then
        echo "==> Fixing baas-repo-pw secret value for ${ns}"
        kubectl -n $ns patch secret baas-repo-pw --type='json' -p='[{"op":"replace" ,"path":"/data/repo-pw" ,"value":"'${BAAS_REPO_PW_B64}'"}]'
    else
        echo "==> Secret would be fixed if DRY_RUN=false"
    fi
done
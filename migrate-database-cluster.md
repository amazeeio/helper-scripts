# Migrate Database Cluster

This explains on how to explain a complete database cluster with all data, users and permissions to another cluster

1. Start Mydumper in namespace of your choice and connect inside of it

        kubectl create deployment --image=schnitzel/docker-mydumper mydumper -- sh -c 'while sleep 3600; do :; done' --help 
        kubectl exec -it deploy/mydumper -- bash
        
2. Export all existing databases from source:

        mydumper -h '[source hostname]' -u '[source mysql admin user]' -p '[source mysql admin password]'  --regex '^(?!(mysql\.|test\.))' --triggers --events --routines -v 4 -o /dump
        
3. Import all existing databases into destination:

        myloader -h '[destination hostname]' -u '[destination mysql admin user]' -p '[destination mysql admin password]' -d . -v 4
        
4. Install percona toolkit (allows to easily export and import users & permissions)

        apt-get update
        apt-get install percona-toolkit 
 
5. Export all users with permissions:

        pt-show-grants --host '[source hostname]' --user '[source mysql admin user]' --password '[source mysql admin password]' > /dump/users.sql
        
    (this also exports the source admin user, if you want to skip that one use:
    
        pt-show-grants --host '[source hostname]' --user '[source mysql admin user]' --password '[source mysql admin password]' --ignore '[source mysql admin user]' > /dump/users.sql
        
6. Import users into destination:

        mysql -h '[destination hostname]' -u '[destination mysql admin user]' -p'[destination mysql admin password]' < /dump/users.sql
        mysql -h '[destination hostname]' -u '[destination mysql admin user]' -p'[destination mysql admin password]' -e 'FLUSH PRIVILEGES'
        
7. Change all service objects hostnames:

   Run in your shell (not inside mydumper)

        SOURCE_WRITER_HOSTNAME='[source hostname]'
        SOURCE_READER_HOSTNAME='[source reader hostname]'
        DESTINATION_WRITER_HOSTNAME='[destination hostname]'
        DESTINATION_READER_HOSTNAME='[source writer hostname]'
        DESTINATION_ROOT_USERNAME='[destination mysql admin user]'
        DESTINATION_ROOT_PASSWORD='[destination mysql admin password]'

        # Change Writer services
        kubectl get services -A -o=json | jq -r ".items[]|select(.spec.externalName==\"$SOURCE_WRITER_HOSTNAME\")|[.metadata.namespace, .metadata.name] | @tsv" | while IFS=$'\t' read -r namespace name; do; 
          echo "$namespace: Patching $name"
          kubectl -n "$namespace" patch "svc/$name" -p "{\"spec\":{\"externalName\": \"$DESTINATION_WRITER_HOSTNAME\"}}"
        done

        # Change Reader services
        kubectl get services -A -o=json | jq -r ".items[]|select(.spec.externalName==\"$SOURCE_READER_HOSTNAME\")|[.metadata.namespace, .metadata.name] | @tsv" | while IFS=$'\t' read -r namespace name; do; 
          echo "$namespace: Patching $name"
          kubectl -n "$namespace" patch "svc/$name" -p "{\"spec\":{\"externalName\": \"$DESTINATION_READER_HOSTNAME\"}}"
        done

        # Change MariaDBConsumer Object
        kubectl get MariaDBConsumer -A -o=json | jq -r ".items[]|select(.spec.provider.hostname==\"$SOURCE_WRITER_HOSTNAME\")|[.metadata.namespace, .metadata.name] | @tsv" | while IFS=$'\t' read -r namespace name; do; 
          echo "$namespace: Patching $name"
          kubectl -n "$namespace" patch "MariaDBConsumer/$name" --type merge  -p "{\"spec\":{\"provider\":{\"hostname\": \"$DESTINATION_WRITER_HOSTNAME\"}}}"
          kubectl -n "$namespace" patch "MariaDBConsumer/$name" --type merge  -p "{\"spec\":{\"provider\":{\"readReplicas\": [\"$DESTINATION_READER_HOSTNAME\"]}}}"
        done

        # Change MariaDBProvider Object
        kubectl get MariaDBProvider -A -o=json | jq -r ".items[]|select(.spec.hostname==\"$SOURCE_WRITER_HOSTNAME\")|[.metadata.namespace, .metadata.name] | @tsv" | while IFS=$'\t' read -r namespace name; do; 
          echo "$namespace: Patching $name"
          kubectl -n "$namespace" patch "MariaDBProvider/$name" --type merge  -p "{\"spec\":{\"hostname\": \"$DESTINATION_WRITER_HOSTNAME\"}}"
          kubectl -n "$namespace" patch "MariaDBProvider/$name" --type merge  -p "{\"spec\":{\"readReplicaHostnames\": [\"$DESTINATION_READER_HOSTNAME\"]}}"
          kubectl -n "$namespace" patch "MariaDBProvider/$name" --type merge  -p "{\"spec\":{\"user\": \"$DESTINATION_ROOT_USERNAME\"}}"
          kubectl -n "$namespace" patch "MariaDBProvider/$name" --type merge  -p "{\"spec\":{\"password\": \"$DESTINATION_ROOT_PASSWORD\"}}"
        done

           
   This script will cause the applications to use the new database in realtime, no need to redeploy or restart the pods.



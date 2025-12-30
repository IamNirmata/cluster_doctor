kubectl -n $1 exec $2 -- ls $3
kubectl -n gcr-admin exec gcr-admin-pvc-access -- ls /data/continuous_validation
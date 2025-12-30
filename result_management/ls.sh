kubectl -n $1 exec $2 -- ls /data/continuous_validation
kubectl -n gcr-admin exec gcr-admin-pvc-access -- ls /data/continuous_validation
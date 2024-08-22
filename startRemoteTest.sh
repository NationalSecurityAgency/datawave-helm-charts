#Values overrides file. See umbrella/values-testing.yaml
VALUES_FILE=${1:-values-testing.yaml}


#Apply GHCR credendials
if test -f ./ghcr-image-pull-secret.yaml; then
   kubectl apply -f ./ghcr-image-pull-secret.yaml
fi


#Package charts
mkdir -p ./umbrella/charts/
find ./ -name "*.tgz"  -delete   
cd ./; for chart in hadoop accumulo zookeeper ingest web; do cd $chart; helm lint . && helm package .; cp *.tgz ../umbrella/charts/; cd ..; done
find ./ -name "*.tgz"  -exec cp {} umbrella/charts/ \;
# Deploy umbrella chart
cd umbrella;
helm package .
helm install dwv *.tgz -f ${VALUES_FILE} && \
cd ../


#Currently Disabled. See DataWave repo on how to get this json file.
#kubectl cp tv-show-raw-data-stock.json dwv-dwv-hadoop-hdfs-nn-0:/tmp && \
#kubectl exec -it dwv-dwv-hadoop-hdfs-nn-0 -- hdfs dfs -put /tmp/tv-show-raw-data-stock.json /data/myjson

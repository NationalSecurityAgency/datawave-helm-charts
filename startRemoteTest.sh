#Values overrides file. See umbrella/values-testing.yaml
VALUES_FILE=${1:-values-testing.yaml}


#Apply GHCR credendials
if test -f ./ghcr-image-pull-secret.yaml; then
   kubectl apply -n bli -f ./ghcr-image-pull-secret.yaml
fi


#Package charts
find . -name "*.tgz" -delete
cd common-service-library
helm package .
cd ..
for chart in audit authorization cache configuration dictionary datawave-monolith hadoop ingest mysql rabbitmq zookeeper; do
  cd $chart;
  helm dependency update
  helm package .
  cd ..
done
cd datawave-monolith-umbrella
helm dependency update
helm package .
cd ../datawave-stack;
helm dependency update
helm package .
cd ..


#Apply GHCR credendials
if test -f ./ghcr-image-pull-secret.yaml; then
kubectl apply -f ./ghcr-image-pull-secret.yaml
fi

cd datawave-stack
kubectl create secret generic certificates-secret --from-file=keystore.p12=certificates/keystore.p12 --from-file=truststore.jks=certificates/truststore.jks
helm install  dwv *.tgz -f ${VALUES_FILE} && \
cd ../


#Currently Disabled. See DataWave repo on how to get this json file.
#kubectl cp tv-show-raw-data-stock.json dwv-dwv-hadoop-hdfs-nn-0:/tmp && \
#kubectl exec -it dwv-dwv-hadoop-hdfs-nn-0 -- hdfs dfs -put /tmp/tv-show-raw-data-stock.json /data/myjson


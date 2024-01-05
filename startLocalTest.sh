#Values overrides file. See umbrella/values-testing.yaml
VALUES_FILE=${1:-values-testing.yaml}

# Cache images and reset minikube. Then Setup minikube ingress.
docker pull rabbitmq:3.11.4-alpine && \
docker pull busybox:1.28 && \
minikube delete --all --purge && \
minikube start --cpus 8 --memory 30960 --disk-size 20480 && \
minikube image load rabbitmq:3.11.4-alpine  && \
minikube image load busybox:1.28 && \
minikube addons enable ingress && \
minikube kubectl -- delete -A ValidatingWebhookConfiguration ingress-nginx-admission && \
minikube kubectl -- patch deployment -n ingress-nginx ingress-nginx-controller --type='json' -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value":"--enable-ssl-passthrough"}]' && \
echo "$(minikube ip) example-ui.datawave.org" | sudo tee -a /etc/hosts  && \
echo "$(minikube ip) web.datawave.org" | sudo tee -a /etc/hosts && \
echo "$(minikube ip) dictionary.datawave.org" | sudo tee -a /etc/hosts && \


#Apply GHCR credendials
if test -f ./ghcr-image-pull-secret.yaml; then
  minikube kubectl -- apply -f ./ghcr-image-pull-secret.yaml
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

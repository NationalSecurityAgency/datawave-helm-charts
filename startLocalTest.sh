#Values overrides file. See umbrella/values-testing.yaml
VALUES_FILE=${1:-values-testing.yaml}

# Cache images and reset minikube. Then Setup minikube ingress.
docker pull rabbitmq:3.11.4-alpine && \
docker pull busybox:1.28 && \
minikube delete --all --purge && \
minikube start --cpus 8 --memory 30960 --disk-size 20480 && \
minikube image load rabbitmq:3.11.4-alpine  && \
minikube image load busybox:1.28 && \
minikube image load mysql:8.0.32 && \
minikube addons enable ingress && \
minikube kubectl -- delete -A ValidatingWebhookConfiguration ingress-nginx-admission && \
minikube kubectl -- patch deployment -n ingress-nginx ingress-nginx-controller --type='json' -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value":"--enable-ssl-passthrough"}]' && \
sudo sed -i "s/.*datawave\.org.*//g" /etc/hosts
echo "$(minikube ip) namenode.datawave.org" | sudo tee -a /etc/hosts  && \
echo "$(minikube ip) resourcemanager.datawave.org" | sudo tee -a /etc/hosts  && \
echo "$(minikube ip) historyserver.datawave.org" | sudo tee -a /etc/hosts  && \
echo "$(minikube ip) accumulo.datawave.org" | sudo tee -a /etc/hosts  && \
echo "$(minikube ip) web.datawave.org" | sudo tee -a /etc/hosts && \
echo "$(minikube ip) dictionary.datawave.org" | sudo tee -a /etc/hosts && \


#Apply GHCR credendials
if test -f ./ghcr-image-pull-secret.yaml; then
  minikube kubectl -- apply -f ./ghcr-image-pull-secret.yaml
fi

#Package charts
find . -name "*.tgz" -delete
cd datawave-monolith-umbrella
helm dependency update
helm package .
cd ../datawave-stack;
helm dependency update
helm package .
minikube kubectl -- create secret generic certificates-secret --from-file=keystore.p12=certificates/keystore.p12 --from-file=truststore.jks=certificates/truststore.jks
helm install dwv *.tgz -f ${VALUES_FILE} && \
cd ../


#Currently Disabled. See DataWave repo on how to get this json file.
#kubectl cp tv-show-raw-data-stock.json dwv-dwv-hadoop-hdfs-nn-0:/tmp && \
#kubectl exec -it dwv-dwv-hadoop-hdfs-nn-0 -- hdfs dfs -put /tmp/tv-show-raw-data-stock.json /data/myjson

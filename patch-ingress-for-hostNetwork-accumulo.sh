#!/bin/bash

# forward port 9000 to the nn and port 2181 to zookeeper
kubectl patch configmap tcp-services -n ingress-nginx --patch '{"data":{"9000":"default/hdfs-nn:9000", "2181":"default/zookeeper:2181"}}'

# patch ingress to apply the new ports
kubectl patch deployment ingress-nginx-controller --patch "$(cat ingress-nginx-controller-patch.yaml)" -n ingress-nginx

#mkdir -p ~/.minikube/files/etc/
#echo "192.168.49.2 hdfs-nn" >  ~/.minikube/files/etc/hosts

# necessary for local script resolve to hdfs-nn from embedded configmap, 192.168.49.2 is the default minikube internal ip
kubectl patch deployment accumulo-manager -p '{"spec":{"template":{"spec":{"hostAliases":[{"ip": "192.168.49.2", "hostnames": ["hdfs-nn"]}]}}}}'

kubectl scale deployment/accumulo-manager --replicas=0
kubectl scale deployment/accumulo-manager --replicas=1

#!/usr/bin/env bash

COREFILE=$1
sed -e "s/MINIKUBE_IP/$(minikube ip | awk '{print $2}')/" -e "s/HOST_IP/$(minikube ip | cut -f1,2,3 -d .).1/" "${COREFILE}" | minikube kubectl -- apply -f -

#!/usr/bin/env bash

helm uninstall --wait dwv
./stopHadoop.sh
./stopZookeeper.sh
if minikube status > /dev/null 2>&1; then
  ./updateCorefile.sh coredns.corefile-default.template
fi
sudo rm -rf /tmp/hadoop-* /tmp/zookeeper

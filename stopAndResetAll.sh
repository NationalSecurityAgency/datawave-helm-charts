#!/usr/bin/env bash

./stopHadoop.sh
./stopZookeeper.sh
./updateCorefile.sh coredns.corefile-default.template
sudo rm -rf /tmp/hadoop-* /tmp/zookeeper

#!/usr/bin/env bash

if ${INIT_LOCAL_HADOOP}; then
  "${HADOOP_HOME}"/bin/hdfs namenode -format
fi
"${HADOOP_HOME}"/sbin/start-dfs.sh
"${HADOOP_HOME}"/sbin/start-yarn.sh

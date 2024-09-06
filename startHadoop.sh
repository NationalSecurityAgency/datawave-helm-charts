#!/usr/bin/env bash

/opt/hadoop-3.4.0/bin/hdfs namenode -format
/opt/hadoop-3.4.0/sbin/start-dfs.sh
/opt/hadoop-3.4.0/sbin/start-yarn.sh

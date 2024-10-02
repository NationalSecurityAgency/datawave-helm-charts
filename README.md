## Generate Image Pull Secrets ##
Running this stack uses images in the ghcr repository which are not public. The following generates a template to use for imagePullSecrets in helm charts.


Through the GitHub UI, generate a PAT with at least read packages

```bash
./create-image-pull-secrets.sh <github username> <gihub PAT>
```


### DataWave Stack Helm Deployment ###

This repository holds Helm charts and Docker files used to deploy Datawave locally for testing. 

Prerequisites:

* docker
* helm
* kubectl
* minikube (for local testing)


If you already have the prerequisites installed you can simply run `./startLocalTest.sh`





## Testing of images and helm charts ##

Images are now created in [Datawave Stack Docker Images](https://github.com/nationalSecurityAgency/datawave-stack-docker-images)

If you want to use an external Hadoop and/or Zookeeper instance then set the appropriate env var(s) to true.
```bash
export USE_LOCAL_ZOOKEEPER=true
export USE_LOCAL_HADOOP=true
```

And set the path to the installation(s) appropriately for your system.
```bash
export ZOOKEEPER_HOME=/opt/zookeeper
export HADOOP_HOME=/opt/hadoop
```

In order to test changes to helm charts, you can run the following script:
```bash
./startLocalTest.sh
```
This will package all the helm charts from the local directories, and launch the cluster.

## Updating Helm schemas
```bash
helm plugin install https://github.com/losisin/helm-values-schema-json.git
find * -maxdepth 0 -type d -exec sh -c "cd {}; helm schema" \;
```

## Troubleshooting Datawave

### Authorization
The first thing you should check is that you are using both the cert and key files we provided. The deployment is configured to trust our self signed certs so you should be using those. The certs can be found in nexus in the Frostbite-Raw repo at `datawave-certs/test-users`. You will need both the cert and key to use python or just the p12 to use browser endpoints. If a user has them listed under madcert, use those as the other versions are not correctly configured. If a user does not have madcert they are the correctly configured ones.

Python's request library (at least the version we have) does not work with non-pem certificate formats. If you're using the certs we provided you should be fine. However, if you are modifying it to use your own certs, you have been warned, convert them to pem or don't use python. Hitting a datawave endpoint from a browser will allow selection of trusted certificates loaded into the cert store.

If you can authorize but not getting what you'd expect you can try hitting the `whoami` endpoint either in the browser or by using `datawave authorization` from the Datawave CLI python library we have written. This will tell you what auths the user is getting as well as the roles they have for datawave. Datawave users need to have AuthorizedUser at the minimum to be able to make queries.

Datawave may cache users and this has caused problems for us before. So if you have updated a user and are not seeing the updates you may need to clear the cache. This can be done from an admin user with the evict endpoints of the authorization end point. `dwv-authorization.***/authorization/v2/admin/evictAll` or `/evictUser`.

#### Logs
**Pod:** dwv-web-authorization-*

**Log:** ~/logs/authorization-service.log

### Ingest
In our experience the biggest issue we encountered with ingesting new data types was in formatting the values.yaml of the new datatype or in the json being uploaded. Datawave's documentation that we linked above is really good at outlining what everything needs to be. Just double check everything is set up correctly and that the json file you're ingesting is formatted correctly with all required fields (ie the indexed ones).

Another thing to note is that we were not able to get dashes to work in the datatype name. As far as we can tell there is no reason that shouldn't work but it did not.

You can watch your ingest job by checking the yarn status of the ingest job on the hadoop pod. There are three ways you can view this.
1) You can use `datawave ingest`. If you do not pass a file to ingest, it will instead display the yarn job statuses.
1) It can be done manually by executing `yarn node -list` in the pod `*-hadoop-yarn-rm-0`.
1) Or a web GUI can be accessed by port forwarding the `*-hadoop-yarn-rm-0` pod's 8088 port.

#### Logs
**pod:** [helm release name]-dwv-ingest-ingest-*

**Log:**
There are several log files in here. We only use the live ingest service, so only those logs are of interest.
* `flag_maker_flag-maker-live.log` can be useful to see why an ingest isn't firing off if it is not being flagged
* `live-ingest.log` this log updates on a timer and will tell you when something new is detected but it is constantly being updated so might not be very useful in most cases
* There are also file specific logs based on the file ingested. This is where you will find what errors were raised and the result of the ingest job. If you need to dive into the log level this is probably where you should start looking.

### Query
The following is a list of common errors and their usual cause
* ERROR: The query contained fields which do not exist in the data dictionary for any specified datatype
  * If you are getting this immediately after redeploying and uploading some data you may need to refresh the cache. This can be accomplished with the `datawave accumulo` command.
    * You may have to invoke this twice to get it to refresh in a timely manner. We are not sure why.
    * It should further be noted that once this cache refresh has been completed it should not need to be done again until a new datatype is uploaded or the existing datatype structure is changed.
  * Otherwise the following two issues are usually the cause.
    1) You're trying to search on a column that does not exist. Check that you're spelling it correctly. It should be noted that capitaliation does not matter as datawave normalizes it anyway.
    1) You forgot to wrap the value you're searching on in quotes. For example `GENRES == IntegrationTest` would return this error since IntegrationTest is not quoted.
* ERROR: User requested authorizations that they don't have
  * This error does a pretty good job of explaining what is missing.
  * You can use `datawave authorization` to check which auths that the user you're running the query with has. From there you should be able to resolve this.
* ERROR: Full table scan required but not enabled
  * You are trying to query on a field that is not indexed. When creating a new datatype you have to specify which fields are to be queriable. If you try to search one of the fields that has not been set up as queriable then datawave will return this error.
  * This error also occurs if you have messed up the JEXL format. Here are two examples that we have observed this error occuring
    1) `GENRES == 'IntegrationTest' & LANGUAGE == 'English'`, the problem being that there is a single & rather than &&.
    1) `GENRES = 'IntegrationTest'`, in this case we have a single = instead of ==.
* If you are not getting results when you know there should be some.
  1) Check the ingest job completed. These can be checked by calling `datawave ingest` without passing it a file.
  1) You may need to refresh the cache. Use `datawave accumulo` to request a refresh and wait a moment.
  1) Double check the authorizations requested match the visibility uploaded.
  1) If none of those work, check the Query.log at the location listed below. Be warned, the logs are very dense. It might help to use grep with -B and -A to show lines before and after the match.

#### Logs
**pod:** dwv-web-datawave

**Log:** *$WILDFLY_HOME/standalone/log/*
  * Query.log - logs the query and the steps preformed for it
  * Security.log - logs any security requests made through the Datawave app
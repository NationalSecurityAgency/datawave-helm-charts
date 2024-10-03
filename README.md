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
The first thing to check is that certificates trusted by the Datawave stack are being used. This may require adding public certificates to the truststore Datawave utilizes or configuring Datawave with a new truststore that contains the correct certificates.

A Python library is available to provide easy CLI interactions with Datawave and can be found at the [Datawave CLI](https://github.com/AFMC-MAJCOM/datawave-cli). It utilizes Python's request library on the backend.

Python's request library (at least the version used in the Datawave CLI) does not work with non-pem certificate formats. If modifications are being made to use custom certificates, ensure they are converted to pem format, or avoid using Python. Accessing a Datawave endpoint from a browser allows selection of trusted certificates loaded into the cert store.

If authorization is successful but the expected results are not being returned, try hitting the `whoami` endpoint either in a browser or by using `datawave authorization` from the Datawave CLI Python library. This will indicate what authorizations and roles the user has in Datawave. Datawave users must have AuthorizedUser at a minimum to make queries.

Datawave may cache users, so if updates to a user are not reflected, the cache may need to be cleared. This can be done by an admin user with the evict endpoints of the authorization endpoint: `dwv-authorization.***/authorization/v2/admin/evictAll` or `/evictUser`.

#### Logs
**Pod:** dwv-web-authorization-*

**Log:** ~/logs/authorization-service.log

### Ingest
The biggest issues with ingesting new data types are often related to formatting the `values.yaml` of the new datatype or the JSON being uploaded. Datawave's documentation provides a detailed outline of what everything needs to be. Ensure everything is set up correctly and that the JSON file being ingested is formatted properly with all required fields (i.e., the indexed ones).

It should also be noted that dashes in the datatype name were not functional. There does not appear to be a clear reason for this, but it did not work.

The ingest job status can be monitored by checking the YARN status on the Hadoop pod. There are three ways to do this:
1) Use `datawave ingest`. If no file is passed for ingest, it will display the YARN job statuses.
1) Execute `yarn node -list` manually in the pod `*-hadoop-yarn-rm-0`.
1) Access the web GUI by port-forwarding the `*-hadoop-yarn-rm-0` pod's 8088 port.

#### Logs
**Pod:** [helm release name]-dwv-ingest-ingest-*

**Log:**
Several log files are present. Only the live ingest service logs are relevant.
* `flag_maker_flag-maker-live.log` can help identify why an ingest isn't starting if it's not being flagged.
* `live-ingest.log` updates on a timer and indicates when new data is detected but may not be useful in most cases due to constant updates.
* File-specific logs for ingested files contain errors and the results of the ingest job. For log-level details, start here.

### Query
The following is a list of common errors and their usual causes:
* **ERROR: The query contained fields which do not exist in the data dictionary for any specified datatype**
  * After redeploying and uploading data, a cache refresh might be needed. Use the `datawave accumulo` command to do this.
    * It may need to be invoked twice for a timely refresh. The reason for this is unclear.
    * Once completed, the cache should not need refreshing again unless a new datatype is uploaded or an existing datatype structure is changed.
  * Other common causes include:
    1) Searching for a column that does not exist. Verify the spelling. Datawave normalizes it, so capitalization is not important.
    1) Forgetting to wrap the value in quotes. For example, `GENRES == IntegrationTest` would return this error since IntegrationTest is not quoted.

* **ERROR: User requested authorizations that they don't have**
  * This error indicates what authorizations are missing.
  * Use `datawave authorization` to check the authorizations the user has, then resolve the issue from there.

* **ERROR: Full table scan required but not enabled**
  * This occurs when querying a field that is not indexed. When creating a new datatype, specify which fields should be queriable. Attempting to search a field that is not set up as queriable triggers this error.
  * It can also result from incorrect JEXL formatting. Here are two examples:
    1) `GENRES == 'IntegrationTest' & LANGUAGE == 'English'` — the issue is using a single `&` instead of `&&`.
    1) `GENRES = 'IntegrationTest'` — in this case, a single `=` is used instead of `==`.

* **If no results are returned when some are expected:**
  1) Confirm the ingest job completed. Check by calling `datawave ingest` without passing a file.
  1) The cache may need refreshing. Use `datawave accumulo` to request a refresh and wait a moment.
  1) Double-check that the requested authorizations match the visibility uploaded.
  1) If none of these resolve the issue, check the `Query.log` at the location listed below. The logs are dense, so using `grep` with `-B` and `-A` to show lines before and after the match might help.

#### Logs
**Pod:** dwv-web-datawave

**Log:** *$WILDFLY_HOME/standalone/log/*
  * `Query.log` - logs the query and the steps performed for it.
  * `Security.log` - logs any security requests made through the Datawave app.

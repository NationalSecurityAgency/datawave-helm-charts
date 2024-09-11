## Generate Image Pull Secrets ##
Running this stack uses images in the ghcr repository which are not public. The following generates a template to use for imagePullSecrets in helm charts.


Through the GitHub UI, generate a PAT with at least read packages

```
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

In order to test changes to helm charts, you can run the following script:
```
./startLocalTest.sh
```
This will package all the helm charts from the local directories, and launch the cluster.

## DataWave Configuration and Deployment

### Required Information for onboarding a new datatype
- name of the datatype
- What fields will be queryable
  - types for the fields
  - what fields are unique identifiers

### Steps for Adding a new Datatype
1) Open the umbrella/values.yaml or your own values.yaml.
1) Add the datatype name to the  `dwv-ingest->ingest->config->liveDataTypes` value.
1) Add a new section under the `dwv-ingest->ingest->config->types`.
1) Fill in all the sections within the YAML. See [New Datatype Configuration](#new-datatype-configuration-help) for additional details.
1) Deploy using the [DataWave Deployment](#datawave-deployment) section

### DataWave Deployment
To build the helm package: `build_pkg.sh`<br>
To install via helm: `helm install -n <namespace> datawave-system-X.X.X.tgz`<br>
To upgrade via helm: `helm upgrade -n <namespace> datawave-system-X.X.X.tgz`

When performing an upgrade that contains any datatype changes, you may need to roll the ingest pod to pick up the changes to the configuration. You also may not see the changes in the dictionary until you ingest more data.

#### Verifying the Deployment
##### Checking the datatype folders were created
1) remote into the hadoop-nn pod (any of them if there is more than 1)
1) run the following cmd: `hdfs dfs -ls hdfs://hdfs-nn:9000/data`
3) verify all the datatype folders exists

### New Datatype Configuration Help
<details>
<summary>Example of what to add</summary>
The new sction will need to follow the following format:

```yaml
- name: <name of the datatype>
        flagMakerConfig:
          liveFolder: <name of datatype>
          bulkFolder: <name of datatype>-bulk
          config:
            distrubutionArgs: none
            extraIngestArgs: "-data.name.override=<name of datatype>"
            inputFormat: datawave.ingest.json.mr.input.JsonInputFormat
            lifo: false
        properties:
          "file.input.format": datawave.ingest.json.mr.input.JsonInputFormat
          "data.name": <name of datatype>
          "<name of datatype>.output.name": <name of datatype>
          "<name of datatype>.ingest.helper.class": datawave.ingest.json.config.helper.JsonIngestHelper
          "<name of datatype>.reader.class": datawave.ingest.json.mr.input.JsonRecordReader
          "<name of datatype>.handler.classes": "datawave.ingest.json.mr.handler.ContentJsonColumnBasedHandler,datawave.ingest.mapreduce.handler.facet.FacetHandler"
          "<name of datatype>.data.category.uuid.fields": <insert fields here>
          "<name of datatype>.data.separator": ","
          "<name of datatype>.data.header": <insert header here>
          "<name of datatype>.data.process.extra.fields": true
          "<name of datatype>.data.json.flattener.mode": GROUPED_AND_NORMAL
          "<name of datatype>.SUMMARY.data.field.marking": PUBLIC
          "<name of datatype>.data.category.marking.visibility.field": VISIBILITY
          "<name of datatype>.data.category.date.formats": yyyy-MM-dd,yyyy-MM-dd'T'HH:mm:ss'Z',yyyy-MM-dd HH:mm:ss
          "<name of datatype>.data.category.index": <insert queryable fields here>
          "<name of datatype>.data.category.index.reverse": <insert queryable fields here>
          "<name of datatype>.data.category.token.fieldname.designator": _TOKEN
          "<name of datatype>.data.category.index.tokenize.allowlist": <>
          "<name of datatype>.data.category.index.only": <>
          "<name of datatype>.data.default.normalization.failure.policy": FAIL
          "<name of datatype>.data.default.type.class": datawave.data.type.LcNoDiacriticsType
```
</details>

### Datatype Configuration
 see for more detail: https://code.nsa.gov/datawave/docs/6.x/ingest/configuration (can only access outside AVD)

| Field Name | Description |
| ---------- | ----------- |
| file.input.format | |
| data.name | This is the name of the datatype, which distinguishes it from other types for the purposes of ingest processing and perhaps even for dataflow/transport concerns. As such, this can be used to denote a subtype of some common data format, like CSV files for example, which could originate from any number of sources        |
| (data.name).output.name | This is the name to use on the data in Accumulo |
| (data.name).ingest.helper.class | |
| (data.name).reader.class | |
| (data.name).handler.classes | List of classes that should process each event |
| (data.name).data.category.uuid.fields | List of known fields that contain UUIDs |
| (data.name).data.separator | This is the separator to use for delimited text, and between configuration file parameters with multiple values. |
| (data.name).data.header | Known metadata fields that may be expected to appear in every json document. Often, these may be "required" fields, and/or fields that you want to use for policy enforcement, quality assurance, etc |
| (data.name).data.process.extra.fields | If true, "extra" fields within the json tree (ie, those outside the defined "header") should be processed. Otherwise, everything outside the header will be ignored unless explicitly whitelisted |
| (data.name).data.json.flattener.mode | The classes datawave.ingest.json.mr.input.JsonRecordReader and datawave.ingest.json.config.helper.JsonIngestHelper support 4 different json-flattening modes: SIMPLE, NORMAL, GROUPED, and GROUPED_AND_NORMAL |
| (data.name).data.category.marking.visibility.field | Known field in every record that will contain the event's ColumnVisibility for Accumulo. If the raw data doesn't convey security markings, then utilize the '.data.category.marking.default' property instead, to declare the default marking to be applied to every field |
| (data.name).data.category.date | Known date field to be used, if found, for the shard row id. Otherwise, current date will be used |
| (data.name).data.category.date.formats | Known/valid date formats for *.data.category.date field |

### Indexing and Tokenization
| Field Name | Description |
| ---------- | ----------- |
| (data.name).data.category.index | List of known fields to index |
| (data.name).data.category.index.reverse | List of known fields to reverse index |
| (data.name).data.category.token.fieldname.designator | Field name suffix to be applied to field names that are tokenized. See *.data.category.index.tokenize.allowlist |
| (data.name).data.category.index.tokenize.allowlist | These are the fields to tokenize and index. Tokenization allows fields to be parsed for searching the content of those fields (rather than the whole value) |
| (data.name).data.category.index.only | Fields that will exist only in the global index. Will not be stored as part of the event/document |

### Field Normalization
| Field Name | Description |
| ---------- | ----------- |
| (data.name).data.default.normalization.failure.policy | For field normalization failures: DROP, LEAVE, FAIL. FAIL: the entire event/document will be dropped, and possibly written to the error schema in Accumulo. LEAVE: the non-normalized value will be kept as-is. DROP: the failed field will be dropped, and everything else retained |
| (data.name).data.default.type.class | Default type |
| (data.name).(FieldName).data.field.type.class | Fully-qualified class name of the DataWave type to be used to interpret and normalize "FieldName" values Example types are datawave.data.type.DateType, datawave.data.type.NumberType, datawave.data.type.GeoType, etc |


## Known Roles
| Role | Description |
| ---- | ----------- |
| Administrator | Provides all access to admin functions within Datawave |
| AuthorizedQueryServer | Allowed to perform queries |
| AuthorizedServer | Used to provide proxy entities from a server |
| AuthorizedUser | A normal user |
| InternalUser | Used for monitoring users within the system |
| JBossAdministrator | Same as Administrator, provides all access to admin functions within Datawave |
| MetricsAdministrator | TBD |
| SecurityUser | Security admin functions? | 

## Troubleshooting Datawave

### Authorization
The first thing you should check is that you are using both the cert and key files we provided. The deployment is configured to trust our self signed certs so you should be using those. The certs can be found in nexus in the Frostbite-Raw repo at `datawave-certs/test-users`. You will need both the cert and key to use python or just the p12 to use browser endpoints. If a user has them listed under madcert, use those as the other versions are not correctly configured. If a user does not have madcert they are the correctly configured ones.

Python's request library (at least the version we have) does not work with non-pem certificate formats. If you're using the certs we provided you should be fine. However, if you are modifying it to use your own certs, you have been warned, convert them to pem or don't use python. Hitting a datawave endpoint from a browser will allow selection of trusted certificates loaded into the cert store.

If you can authorize but not getting what you'd expect you can try hitting the `whoami` endpoint either in the browser or by using `datawave authorization` from the Datawave CLI python library we have written. This will tell you what auths the user is getting as well as the roles they have for datawave. Datawave users need to have AuthorizedUser at the minimum to be able to make queries.

Datawave caches users and this has caused problems for us before. So if you have updated a user and are not seeing the updates you may need to clear the cache. This can be done from an admin user with the evict endpoints of the authorization end point. `dwv-authorization.***/authorization/v2/admin/evictAll` or `/evictUser`.

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

## Creating and updating Certificates within Datawave
Using Datawave with self-signed certificates takes a bit of setup to accomplish. You have to create the Certificate Authority to sign the certificates with. For our demo we utilized self-signed certificates create by the NSA tool MADCert. The documentation for creating the new certificates are straight forward within the [MADCert documentation](https://github.com/NationalSecurityAgency/MADCert) , so it is not covered here. 

### Updating Datawave to use new certificates
After the server certificates are created for datawave, the following steps will ensure you get them within Datawave to be utilized.

1) Switch the `web.certificates.externalsecret.enabled` from false to true within `web->values.yaml`.
1) add the `web.certificates.externalsecret.name` value within `web->values.yaml`.
1) create a new file under `web->templates` and fill it with the following information:
    <details>
    <summary>New File Content</summary>

    ```yaml
    {{ if .Values.web.certificates.externalSecret.enabled }}
    apiVersion: v1
    kind: Secret

    metadata:
        name: {{ .Values.web.certificates.externalSecret.name }}
    type: Opaque

    data:
        keystore.p12: |-
            <fill me in>
        truststore.jks: |-
            <fill me in>
    {{ end }}
    ```

    </details>

1) use the following command to create/update the truststore.jks
    ```
    keytool -import -alias abacus-intermediate -file <certificate to add> -keystore <name of the truststore>
    ```
1) Use `base64` to encode both the server pkcs12 file and the truststore created. Fill in the output within the yaml file created above.
1) Deploy the changes.
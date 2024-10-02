## DataWave Configuration and Deployment

### Required Information for onboarding a new datatype
- name of the datatype
- What fields will be queryable
  - types for the fields
  - what fields are unique identifiers

### Steps for Adding a new Datatype
1) Open your own values.yaml.
1) Add the datatype name to the  `dwv-ingest->config->liveDataTypes` value. This will contain a comma-delimited list of 
all your available datatypes
1) Add a new section under the `dwv-ingest->config->types`.
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
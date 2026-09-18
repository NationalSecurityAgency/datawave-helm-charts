# DataWave ingest chart

## Optional Wikipedia bootstrap

The chart can submit the Wikipedia example files through DataWave's live ingest
pipeline after installation. The bootstrap is disabled by default and reads its
inputs from an existing ConfigMap.

Create the input ConfigMap from the small example files:

```bash
kubectl -n datawave create configmap datawave-wikipedia-examples \
  --from-file=../datawave/warehouse/ingest-wikipedia/src/test/resources/input/enwiki-20130305-pages-articles-brief.xml \
  --from-file=../datawave/warehouse/ingest-wikipedia/src/test/resources/input/dewiki-20250520-pages-articles-brief.xml \
  --from-file=../datawave/warehouse/ingest-wikipedia/src/test/resources/input/eswiki-20250520-pages-articles-brief.xml \
  --from-file=../datawave/warehouse/ingest-wikipedia/src/test/resources/input/frwiki-20250520-pages-articles-brief.xml
```

Enable the post-install Job:

```yaml
bootstrap:
  wikipedia:
    enabled: true
    inputConfigMap: datawave-wikipedia-examples
```

ConfigMaps have a Kubernetes object-size limit, so use only the brief examples
in a single ConfigMap. The bootstrap Job accepts both `.xml` and `.xml.gz`
keys.

The Job waits up to five minutes for the ingest job cache by default. Configure
`bootstrap.wikipedia.jobCacheWaitSeconds` and
`bootstrap.wikipedia.jobCachePollSeconds` for slower or faster environments.

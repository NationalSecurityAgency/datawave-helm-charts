#!/usr/bin/env bash

set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
render_dir="$(mktemp -d)"
trap 'rm -rf "${render_dir}"' EXIT

helm template dwv "${chart_dir}" > "${render_dir}/all.yaml"
awk '$1 == "run.sh:" {print $2}' "${render_dir}/all.yaml" | base64 --decode > "${render_dir}/install.sh"

expected_types='<value>shardStats,wikipedia,mycsv,myjson,openlib,annotation</value>'
if ! grep -Fq "${expected_types}" "${render_dir}/all.yaml"; then
  echo "Rendered ingest.data.types does not include annotation"
  exit 1
fi

helm template dwv "${chart_dir}" \
  --show-only templates/annotation-bootstrap-job.yaml \
  --set bootstrap.annotation.enabled=true \
  --set bootstrap.annotation.inputConfigMap=datawave-annotation-baseline \
  --set image.repository=nationalsecurityagency/datawave/ingest-kubernetes \
  --set image.tag=8.1.0-SNAPSHOT \
  --set image.pullPolicy=Never \
  > "${render_dir}/annotation-job.yaml"

if grep -Fq "ANNOTATION_DOCUMENT_DATA_TYPES" "${render_dir}/annotation-job.yaml"; then
  echo "Annotation Job still injects bootstrap-specific document datatypes"
  exit 1
fi

if grep -Fq "ingest.data.types" "${render_dir}/annotation-job.yaml"; then
  echo "Annotation Job still rewrites ingest.data.types"
  exit 1
fi

expected_image='image: nationalsecurityagency/datawave/ingest-kubernetes:8.1.0-SNAPSHOT'
if [[ "$(grep -Fc "${expected_image}" "${render_dir}/annotation-job.yaml")" -ne 2 ]]; then
  echo "Annotation Job containers do not consistently use the configured ingest image"
  exit 1
fi

for workaround in prepared-tools live-ingest-bootstrap.sh GenerateEdgeKeyVersionCache; do
  if grep -Fq "${workaround}" "${render_dir}/annotation-job.yaml"; then
    echo "Annotation Job still contains temporary workaround: ${workaround}"
    exit 1
  fi
done

if ! grep -Fq "/opt/datawave-ingest/current/bin/ingest/live-ingest.sh" "${render_dir}/annotation-job.yaml"; then
  echo "Annotation Job does not use the packaged live-ingest.sh"
  exit 1
fi

if ! grep -Fq 'hdfs dfs -test -s "${candidate}/edge-key-version.txt"' "${render_dir}/annotation-job.yaml"; then
  echo "Annotation Job does not reject incomplete job caches"
  exit 1
fi

helm template dwv "${chart_dir}" \
  --show-only templates/wikipedia-bootstrap-job.yaml \
  --set bootstrap.wikipedia.enabled=true \
  --set bootstrap.wikipedia.inputConfigMap=datawave-wikipedia-baseline \
  > "${render_dir}/wikipedia-job.yaml"

for workaround in prepared-tools live-ingest-bootstrap.sh; do
  if grep -Fq "${workaround}" "${render_dir}/wikipedia-job.yaml"; then
    echo "Wikipedia Job still contains temporary workaround: ${workaround}"
    exit 1
  fi
done

if ! grep -Fq "/opt/datawave-ingest/current/bin/ingest/live-ingest.sh" "${render_dir}/wikipedia-job.yaml"; then
  echo "Wikipedia Job does not use the packaged live-ingest.sh"
  exit 1
fi

if ! grep -Fq 'hdfs dfs -test -s "${candidate}/edge-key-version.txt"' "${render_dir}/wikipedia-job.yaml"; then
  echo "Wikipedia Job does not reject incomplete job caches"
  exit 1
fi

if ! grep -Fq "/opt/datawave-ingest/current/bin/ingest/generate-accumulo-config-cache.sh" "${render_dir}/install.sh"; then
  echo "Ingest initialization does not generate the Accumulo table configuration cache"
  exit 1
fi

create_tables_line="$(grep -nF "/opt/datawave-ingest/current/bin/ingest/create-all-tables.sh" "${render_dir}/install.sh" | cut -d: -f1)"
generate_cache_line="$(grep -nF "/opt/datawave-ingest/current/bin/ingest/generate-accumulo-config-cache.sh" "${render_dir}/install.sh" | cut -d: -f1)"
load_cache_line="$(grep -nF "/opt/datawave-ingest/current/bin/ingest/load-job-cache.sh" "${render_dir}/install.sh" | cut -d: -f1)"
if [[ -z "${create_tables_line}" || -z "${generate_cache_line}" || -z "${load_cache_line}" ||
      "${create_tables_line}" -ge "${generate_cache_line}" || "${generate_cache_line}" -ge "${load_cache_line}" ]]; then
  echo "Accumulo table configuration cache generation is not ordered after table creation and before job-cache loading"
  exit 1
fi

echo "Ingest chart render assertions passed"

#!/usr/bin/env bash

set -euo pipefail

chart_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
render_dir="$(mktemp -d)"
trap 'rm -rf "${render_dir}"' EXIT

helm template dwv "${chart_dir}" > "${render_dir}/all.yaml"

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

echo "Ingest chart render assertions passed"

#!/usr/bin/env bash

set -euo pipefail

repository_dir="$(cd -- "$(dirname -- "$0")/.." >/dev/null 2>&1 && pwd -P)"
test_dir="$(mktemp -d)"
trap 'rm -rf -- "${test_dir}"' EXIT

"${repository_dir}/package-local-chart.sh" \
  "${repository_dir}/datawave-stack" \
  "${test_dir}" >/dev/null

rendered_manifest="${test_dir}/rendered.yaml"
helm template dwv "${test_dir}"/datawave-system-*.tgz \
  -f "${repository_dir}/datawave-stack/values.yaml" >"${rendered_manifest}"

if grep -Fq "sortedPassword" "${rendered_manifest}"; then
  echo "Packaged chart contains the stale sortedPassword secret reference" >&2
  exit 1
fi

for expected in \
  "key: rootUser" \
  "key: rootPassword" \
  "truthmarkTableName: 'datawave.truthmark'" \
  "truthmarkSourceTableName: 'datawave.truthmarkSource'" \
  "/usr/local/hadoop/../hadoop-mapreduce/hadoop-mapreduce-client-core.jar"
do
  if ! grep -Fq "${expected}" "${rendered_manifest}"; then
    echo "Packaged chart is missing expected current-source content: ${expected}" >&2
    exit 1
  fi
done

echo "Local chart package assertions passed"

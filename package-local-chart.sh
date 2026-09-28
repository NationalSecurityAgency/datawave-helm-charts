#!/usr/bin/env bash

set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 CHART_DIRECTORY [OUTPUT_DIRECTORY]" >&2
  exit 1
fi

script_dir="$(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd -P)"
source_chart="$(realpath -- "$1")"
output_dir="$(realpath -m -- "${2:-.}")"

if [[ ! -f "${source_chart}/Chart.yaml" ]]; then
  echo "Chart.yaml not found in ${source_chart}" >&2
  exit 1
fi

case "${source_chart}" in
  "${script_dir}"|"${script_dir}"/*) ;;
  *)
    echo "Chart directory must be within ${script_dir}" >&2
    exit 1
    ;;
esac

command -v helm >/dev/null
command -v yq >/dev/null

mkdir -p "${output_dir}"
stage_dir="$(mktemp -d)"
trap 'rm -rf -- "${stage_dir}"' EXIT

cp -a -- "${script_dir}/." "${stage_dir}/repository"
rm -rf -- "${stage_dir}/repository/.git"

relative_chart="${source_chart#"${script_dir}"/}"
staged_chart="${stage_dir}/repository/${relative_chart}"

package_chart() {
  local chart_dir="$1"
  local destination="$2"
  local dependency_name
  local dependency_path
  local dependency_dir

  mkdir -p -- "${chart_dir}/charts" "${destination}"

  while IFS=$'\t' read -r dependency_name dependency_path; do
    [[ -n "${dependency_name}" && -n "${dependency_path}" ]] || continue

    dependency_dir="$(realpath -m -- "${chart_dir}/${dependency_path}")"
    if [[ ! -f "${dependency_dir}/Chart.yaml" ]]; then
      echo "Local dependency ${dependency_name} does not contain Chart.yaml: ${dependency_dir}" >&2
      exit 1
    fi

    find "${chart_dir}/charts" -maxdepth 1 -type f -name "${dependency_name}-*.tgz" -delete
    package_chart "${dependency_dir}" "${chart_dir}/charts"
  done < <(yq -r '.dependencies[]? | select(.path != null and .path != "") | [.name, .path] | @tsv' "${chart_dir}/Chart.yaml")

  helm package "${chart_dir}" --destination "${destination}"
}

package_chart "${staged_chart}" "${output_dir}"

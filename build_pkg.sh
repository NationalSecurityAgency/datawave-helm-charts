#!/usr/bin/env bash

set -euo pipefail

basedir="$(cd -- "$(dirname -- "$0")" >/dev/null 2>&1 && pwd -P)"
"${basedir}/package-local-chart.sh" "${basedir}/datawave-stack" "${basedir}"

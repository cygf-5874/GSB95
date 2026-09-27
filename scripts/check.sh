#!/usr/bin/env bash
# 固定入口：等价于 bash check/check.sh，参数原样透传（-list / --only <组>）。
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
exec bash check/check.sh "$@"

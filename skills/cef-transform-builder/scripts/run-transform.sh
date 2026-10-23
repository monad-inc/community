#!/usr/bin/env bash
# Run the jq query embedded in a community-transformations YAML against a sample
# input file and print the resulting JSON.
#
# Usage:
#   run-transform.sh <transform.yaml> <input.json> [--slurp]
#
# - <transform.yaml> may have multiple operations; this script runs each
#   operation of type "jq" in order, piping output to the next.
# - <input.json> may be a single JSON object/array or NDJSON (one object/line).
#   With --slurp the entire file is read as a single JSON value (use for arrays
#   that the transform expects to receive whole).
#
# Requires: yq (mikefarah, v4), jq.

set -euo pipefail

if [[ $# -lt 2 ]]; then
  sed -n '2,18p' "$0" >&2
  exit 64
fi

transform="$1"
input="$2"
shift 2
declare -a slurp_flag
slurp_flag=()
for arg in "${@:-}"; do
  [[ -z "$arg" ]] && continue
  case "$arg" in
    --slurp) slurp_flag=(--slurp) ;;
    *) echo "unknown flag: $arg" >&2; exit 64 ;;
  esac
done

[[ -f "$transform" ]] || { echo "no transform file: $transform" >&2; exit 66; }
[[ -f "$input"     ]] || { echo "no input file: $input" >&2; exit 66; }

command -v yq >/dev/null || { echo "yq (mikefarah) required" >&2; exit 69; }
command -v jq >/dev/null || { echo "jq required" >&2; exit 69; }

op_count=$(yq '.config.operations | length' "$transform")
if [[ "$op_count" == "0" || -z "$op_count" ]]; then
  echo "no operations found in $transform" >&2
  exit 65
fi

data=$(cat "$input")
for ((i=0; i<op_count; i++)); do
  op_type=$(yq ".config.operations[$i].operation" "$transform")
  if [[ "$op_type" != "jq" ]]; then
    echo "operation $i is type '$op_type'; only 'jq' is supported by this script" >&2
    exit 65
  fi
  query=$(yq -r ".config.operations[$i].arguments.query" "$transform")
  data=$(printf '%s' "$data" | jq ${slurp_flag[@]+"${slurp_flag[@]}"} "$query")
done

printf '%s\n' "$data"

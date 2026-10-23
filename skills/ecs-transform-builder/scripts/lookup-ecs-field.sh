#!/usr/bin/env bash
# Look up ECS field(s) from the vendored generated/ecs/ecs_flat.json for a
# version. Prints type, level, normalize, allowed_values, and description.
#
# Usage:
#   lookup-ecs-field.sh <version> <field>        # exact dotted field, e.g. source.ip
#   lookup-ecs-field.sh <version> <fieldset>     # all fields under a set, e.g. event
#   lookup-ecs-field.sh <version> --list         # list field sets + field counts
#
# Examples:
#   lookup-ecs-field.sh 9.5.0 event.category     # shows allowed_values + expected_event_types
#   lookup-ecs-field.sh 9.5.0 source
#   lookup-ecs-field.sh 9.5.0 --list

set -euo pipefail

if [[ $# -lt 2 ]]; then
  sed -n '2,15p' "$0" >&2
  exit 64
fi

version="$1"
ref="$2"

here="$(cd "$(dirname "$0")" && pwd)"
schema="$here/../references/ecs/v${version}/ecs_flat.json"
[[ -f "$schema" ]] || { echo "no ECS schema for v$version at $schema (install it: $here/fetch-ecs-schema.sh $version)" >&2; exit 66; }

if [[ "$ref" == "--list" ]]; then
  jq -r '
    [ keys[] | if contains(".") then split(".")[0] else . end ]
    | group_by(.) | map({set: .[0], fields: length})
    | sort_by(.set)[] | "\(.fields)\t\(.set)"
  ' "$schema"
  exit 0
fi

# Exact field match
if jq -e --arg k "$ref" 'has($k)' "$schema" >/dev/null; then
  jq -r --arg k "$ref" '.[$k] | {
    field: $k, type, level, normalize,
    allowed_values: (if .allowed_values then
      [ .allowed_values[] | {name, expected_event_types} | with_entries(select(.value != null)) ]
      else null end),
    description: (.short // .description)
  }' "$schema"
  exit 0
fi

# Fieldset match (prefix)
count="$(jq -r --arg p "$ref" '[ keys[] | select(startswith($p + ".")) ] | length' "$schema")"
if [[ "$count" -gt 0 ]]; then
  echo "field set \"$ref\" — $count fields:"
  jq -r --arg p "$ref" '
    to_entries | map(select(.key | startswith($p + "."))) | sort_by(.key)[]
    | "  \(.key)\t[\(.value.type)]\(if (.value.normalize // []) | index("array") then " (array)" else "" end)"
  ' "$schema"
  exit 0
fi

echo "no ECS field or field set matching \"$ref\" in v$version" >&2
exit 65

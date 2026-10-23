#!/usr/bin/env bash
# Print an OCSF object definition (e.g., "device", "user", "metadata") for a
# given version. Objects are the reusable nested types referenced by class
# attributes — they have their own required/recommended/optional fields.
#
# Usage:
#   lookup-ocsf-object.sh <version> <object_name> [--full]
#   lookup-ocsf-object.sh <version> --list

set -euo pipefail

if [[ $# -lt 2 ]]; then
  sed -n '2,9p' "$0" >&2
  exit 64
fi

version="$1"
ref="$2"
mode="${3:-summary}"

here="$(cd "$(dirname "$0")" && pwd)"
schema_file="$here/../references/ocsf/v${version}/schema.json"
[[ -f "$schema_file" ]] || { echo "no schema for v$version at $schema_file (install it: $here/fetch-ocsf-schema.sh $version)" >&2; exit 66; }

if [[ "$ref" == "--list" ]]; then
  jq -r '.objects | to_entries | sort_by(.key) | .[] | "\(.key)\t\(.value.caption)"' "$schema_file"
  exit 0
fi

obj=$(jq --arg ref "$ref" '.objects[$ref] // empty' "$schema_file")
if [[ -z "$obj" ]]; then
  echo "object '$ref' not found in OCSF v$version" >&2
  exit 65
fi

if [[ "$mode" == "--full" ]]; then
  jq '.' <<<"$obj"
  exit 0
fi

jq '{
  caption,
  description,
  required: [.attributes | to_entries[] | select(.value.requirement == "required") | {name: .key, type: (.value.object_type // .value.type)}],
  recommended: [.attributes | to_entries[] | select(.value.requirement == "recommended") | {name: .key, type: (.value.object_type // .value.type)}],
  optional: [.attributes | to_entries[] | select(.value.requirement == "optional") | .key]
}' <<<"$obj"

#!/usr/bin/env bash
# Print the OCSF class definition (caption, uid, category, attributes split by
# requirement level and grouped by profile) for a given version and class
# name/uid.
#
# Usage:
#   lookup-ocsf-class.sh <version> <class_name_or_uid> [--full]
#   lookup-ocsf-class.sh <version> --list
#
# Default mode emits a compact summary:
#   - base_required / base_recommended: attributes with profile == null
#   - profile_required / profile_recommended: attributes grouped by profile name
#
# OCSF profiles (cloud, host, container, datetime, etc.) add their own
# required/recommended fields ON TOP OF the base. A transform only needs to
# satisfy profile fields if it's claiming to follow that profile.
#
# --full dumps the entire class JSON, including optional attributes and
# descriptions.

set -euo pipefail

if [[ $# -lt 2 ]]; then
  sed -n '2,19p' "$0" >&2
  exit 64
fi

version="$1"
ref="$2"
mode="${3:-summary}"

here="$(cd "$(dirname "$0")" && pwd)"
schema_file="$here/../references/ocsf/v${version}/schema.json"
[[ -f "$schema_file" ]] || { echo "no schema for v$version at $schema_file (install it: $here/fetch-ocsf-schema.sh $version)" >&2; exit 66; }

if [[ "$ref" == "--list" ]]; then
  jq -r '
    .classes
    | to_entries
    | map({name: .key, uid: .value.uid, caption: .value.caption, category: .value.category_name})
    | sort_by(.uid)
    | .[]
    | "\(.uid)\t\(.name)\t\(.caption)\t[\(.category)]"
  ' "$schema_file"
  exit 0
fi

class_json=$(jq --arg ref "$ref" '
  .classes
  | to_entries
  | map(.value + {key: .key})
  | (map(select(.key == $ref or .name == $ref or (.uid | tostring) == $ref))[0])
' "$schema_file")

if [[ "$class_json" == "null" || -z "$class_json" ]]; then
  echo "class '$ref' not found in OCSF v$version" >&2
  exit 65
fi

if [[ "$mode" == "--full" ]]; then
  jq '.' <<<"$class_json"
  exit 0
fi

jq '{
  caption,
  name,
  uid,
  category,
  category_name,
  description,
  profiles,
  base_required: [
    .attributes | to_entries[]
    | select(.value.requirement == "required" and (.value.profile == null))
    | {name: .key, type: (.value.object_type // .value.type), caption: .value.caption}
  ],
  base_recommended: [
    .attributes | to_entries[]
    | select(.value.requirement == "recommended" and (.value.profile == null))
    | {name: .key, type: (.value.object_type // .value.type), caption: .value.caption}
  ],
  profile_required: (
    [.attributes | to_entries[] | select(.value.requirement == "required" and (.value.profile != null))]
    | group_by(.value.profile)
    | map({(.[0].value.profile): [.[] | {name: .key, type: (.value.object_type // .value.type)}]})
    | add // {}
  ),
  profile_recommended: (
    [.attributes | to_entries[] | select(.value.requirement == "recommended" and (.value.profile != null))]
    | group_by(.value.profile)
    | map({(.[0].value.profile): [.[] | {name: .key, type: (.value.object_type // .value.type)}]})
    | add // {}
  )
}' <<<"$class_json"

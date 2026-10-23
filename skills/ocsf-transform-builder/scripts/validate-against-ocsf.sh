#!/usr/bin/env bash
# Validate a transform's output against the OCSF schema for a given version and
# event class. Reports missing required fields (base + active profiles), missing
# recommended fields, and unknown top-level keys.
#
# Usage:
#   validate-against-ocsf.sh <transform.yaml> <input.json> <ocsf_version> <class_name_or_uid> [profile,profile,...]
#
# Examples:
#   validate-against-ocsf.sh okta-systemlog.yaml sample.json 1.1.0 authentication
#   validate-against-ocsf.sh okta-systemlog.yaml sample.json 1.1.0 authentication cloud,host
#   validate-against-ocsf.sh wiz-vulnerabilities.yaml sample.json 1.5.0 2002
#
# Profiles default to the ones the event declares in metadata.profiles (what the
# hosted validator uses). Pass a comma-separated list to override, or the
# literal string "all" to enforce every profile the class declares.
#
# Profile attributes (device, policy, action_id, cloud, ...) emitted without
# their profile in metadata.profiles are reported as UNDECLARED PROFILE
# ATTRIBUTES and fail the check: the hosted validator rejects them as
# attribute_unknown.
#
# Requires: yq (mikefarah), jq, plus run-transform.sh in the same directory.

set -euo pipefail

if [[ $# -lt 4 ]]; then
  sed -n '2,20p' "$0" >&2
  exit 64
fi

transform="$1"
input="$2"
version="$3"
class_ref="$4"
profiles_arg="${5:-}"

here="$(cd "$(dirname "$0")" && pwd)"
schema_file="$here/../references/ocsf/v${version}/schema.json"
[[ -f "$schema_file" ]] || { echo "no schema for v$version at $schema_file (install it: $here/fetch-ocsf-schema.sh $version)" >&2; exit 66; }

class_json=$(jq --arg ref "$class_ref" '
  .classes
  | to_entries
  | map(.value + {key: .key})
  | (map(select(.key == $ref or .name == $ref or (.uid | tostring) == $ref))[0])
' "$schema_file")

if [[ "$class_json" == "null" || -z "$class_json" ]]; then
  echo "class '$class_ref' not found in OCSF v$version" >&2
  exit 65
fi

output=$("$here/run-transform.sh" "$transform" "$input")
# The transform may emit an array or a stream of events, possibly of several
# classes; check the first event of the requested class.
class_uid=$(jq -r '.uid' <<<"$class_json")
event=$(jq -cs --argjson uid "$class_uid" '
  [.[] | if type == "array" then .[] else . end]
  | (map(select(.class_uid == $uid))[0] // .[0])
' <<<"$output")
declared_profiles_jq=$(jq -c '.metadata.profiles // []' <<<"$event")

# Build the active-profile filter as a jq array literal.
if [[ "$profiles_arg" == "all" ]]; then
  active_profiles_jq=$(jq -c '.profiles // []' <<<"$class_json")
elif [[ -z "$profiles_arg" ]]; then
  active_profiles_jq="$declared_profiles_jq"
else
  active_profiles_jq=$(printf '%s' "$profiles_arg" | jq -Rc 'split(",") | map(. | gsub("^\\s+|\\s+$"; ""))')
fi

required=$(jq -r --argjson active "$active_profiles_jq" '
  [.attributes | to_entries[]
   | select(.value.requirement == "required")
   | select(.value.profile == null or (.value.profile as $p | $active | index($p)))
   | .key]
  | sort | .[]
' <<<"$class_json")

recommended=$(jq -r --argjson active "$active_profiles_jq" '
  [.attributes | to_entries[]
   | select(.value.requirement == "recommended")
   | select(.value.profile == null or (.value.profile as $p | $active | index($p)))
   | .key]
  | sort | .[]
' <<<"$class_json")

known=$(jq -r '[.attributes | keys[]] | sort | .[]' <<<"$class_json")
class_caption=$(jq -r '.caption' <<<"$class_json")

# Some transforms emit fields outside the OCSF spec (e.g., "raw_data",
# "unmapped"). These are conventional in the community-transformations repo
# and not flagged as unknown.
allowlist=$'raw_data\nunmapped\nref_time'

output_keys=$(jq -r 'keys[]' <<<"$event" | sort -u)

# Top-level keys that belong to a profile the event does not declare.
undeclared=$(jq -r --argjson declared "$declared_profiles_jq" --argjson event "$event" '
  [.attributes | to_entries[]
   | select(.value.profile != null)
   | select(.key as $k | $event | has($k))
   | select(.value.profile as $p | $declared | index($p) | not)
   | "\(.key) (profile: \(.value.profile))"]
  | sort | .[]
' <<<"$class_json")

printf 'Class: %s (uid=%s)  OCSF v%s\n' "$class_caption" "$class_uid" "$version"
printf 'Active profiles: %s  (declared in metadata.profiles: %s)\n' "$active_profiles_jq" "$declared_profiles_jq"
printf 'Transform: %s\n\n' "$transform"

missing_required=$(comm -23 <(printf '%s\n' "$required") <(printf '%s\n' "$output_keys"))
missing_recommended=$(comm -23 <(printf '%s\n' "$recommended") <(printf '%s\n' "$output_keys"))
unknown_keys=$(comm -23 <(printf '%s\n' "$output_keys") <(printf '%s\n%s\n' "$known" "$allowlist" | sort -u))

if [[ -n "$missing_required" ]]; then
  printf 'MISSING REQUIRED:\n'
  printf '  - %s\n' $missing_required
else
  printf 'MISSING REQUIRED: none\n'
fi
echo
if [[ -n "$missing_recommended" ]]; then
  printf 'MISSING RECOMMENDED:\n'
  printf '  - %s\n' $missing_recommended
else
  printf 'MISSING RECOMMENDED: none\n'
fi
echo
if [[ -n "$unknown_keys" ]]; then
  printf 'UNKNOWN TOP-LEVEL KEYS (not in OCSF class; check spelling, may belong nested or in unmapped):\n'
  printf '  - %s\n' $unknown_keys
else
  printf 'UNKNOWN TOP-LEVEL KEYS: none\n'
fi

echo
if [[ -n "$undeclared" ]]; then
  printf 'UNDECLARED PROFILE ATTRIBUTES (add the profile to metadata.profiles or drop the attribute; validate2 rejects them):\n'
  printf '%s\n' "$undeclared" | sed 's/^/  - /'
else
  printf 'UNDECLARED PROFILE ATTRIBUTES: none\n'
fi

# Standard jq helper drift (warning only; see SKILL.md "Standard jq helpers").
echo
helper_findings=$("$here/jq-helpers.sh" check "$transform" 2>&1 | grep -E 'DRIFT|MISSING-DEP|UNMANAGED|ERROR' || true)
if [[ -n "$helper_findings" ]]; then
  printf 'JQ HELPERS (warning):\n%s\n' "$helper_findings"
else
  printf 'JQ HELPERS: no drift\n'
fi

# Exit non-zero if required fields are missing or profile attributes are
# undeclared (CI-friendly).
[[ -z "$missing_required" && -z "$undeclared" ]]

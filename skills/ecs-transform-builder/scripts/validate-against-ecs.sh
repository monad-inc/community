#!/usr/bin/env bash
# Validate a transform's output against the ECS schema for a given version.
# ECS has no hosted validator (unlike OCSF's validate2), so this is a static
# check against the vendored generated/ecs/ecs_flat.json:
#   - requires @timestamp and ecs.version
#   - every emitted dotted field path must be a known ECS field, OR sit under a
#     vendor/custom namespace (a top-level segment ECS does not define, e.g.
#     aws.*, labels.*) which is allowed by ECS for custom data
#   - event.kind / event.category / event.type / event.outcome values must be in
#     the ECS allowed_values, and every event.type must be legal for the chosen
#     event.category (the allowed category->type pairings)
#   - event.category / event.type must be arrays (ECS normalize: array)
#
# Usage:
#   validate-against-ecs.sh <transform.yaml> <input.json> <ecs_version>
# Example:
#   validate-against-ecs.sh aws-cloudtrail-core.yaml sample.json 9.5.0
#
# Requires: jq, yq (mikefarah), plus run-transform.sh in the same directory.

set -euo pipefail

# Standard jq helper findings for one transform (see SKILL.md "Standard jq
# helpers"), from the community-transformations repo's own helper check. Prints
# nothing when clean, or SKIPPED when Go or the repo tool is unavailable.
helper_findings() {
  local t="$1" root abs
  root="$(cd "$(dirname "$t")" && git rev-parse --show-toplevel 2>/dev/null || true)"
  if [[ -z "$root" || ! -d "$root/tools/cmd/helpers" ]] || ! command -v go >/dev/null; then
    echo "SKIPPED (needs Go and a community-transformations checkout with tools/cmd/helpers)"
    return
  fi
  abs="$(cd "$(dirname "$t")" && pwd -P)/$(basename "$t")"
  go -C "$root/tools" run ./cmd/helpers check 2>&1 | grep -F "${abs#"$root"/}:" || true
}

if [[ $# -lt 3 ]]; then
  sed -n '2,20p' "$0" >&2
  exit 64
fi

transform="$1"
input="$2"
version="$3"

here="$(cd "$(dirname "$0")" && pwd)"
schema="$here/../references/ecs/v${version}/ecs_flat.json"
[[ -f "$schema" ]] || { echo "no ECS schema for v$version at $schema (install it: $here/fetch-ecs-schema.sh $version)" >&2; exit 66; }

output="$("$here/run-transform.sh" "$transform" "$input")"
doc="$(jq 'if type == "array" then .[0] else . end' <<<"$output")"

report="$(jq -n --argjson doc "$doc" --slurpfile S "$schema" '
  $S[0] as $schema
  | ($schema | keys) as $known
  | ([ $schema | keys[] | select(contains(".")) | split(".")[0] ] | unique) as $fieldsets
  | ([ $doc | paths(scalars) | map(select(type == "string")) | join(".") ] | unique) as $paths
  | ($doc["@timestamp"]) as $ts
  | ($doc.ecs.version) as $ecsver
  | ($doc.event.kind) as $kind
  | ($doc.event.category) as $cats
  | ($doc.event.type) as $types
  | ($doc.event.outcome) as $outcome
  | ($schema."event.kind".allowed_values | map(.name)) as $kinds_ok
  | ($schema."event.outcome".allowed_values | map(.name)) as $outcomes_ok
  | ($schema."event.category".allowed_values) as $cat_av
  | ($schema."event.type".allowed_values | map(.name)) as $types_ok
  | ([ $cat_av[] | .name ]) as $cats_ok
  | ([ $cat_av[] | select(.name | IN(($cats // [])[])) | .expected_event_types[] ] | unique) as $ok_types_for_cats
  | {
      errors: [
        (if $ts == null     then "missing required field: @timestamp" else empty end),
        (if $ecsver == null then "missing required field: ecs.version" else empty end),
        ( $paths[]
          | select((IN($known[])) | not)
          | . as $p
          | select(($p | split(".")[0]) | IN($fieldsets[]))
          | "unknown ECS field: \($p)" ),
        (if $kind != null and (($kind | IN($kinds_ok[])) | not)
          then "invalid event.kind: \($kind)" else empty end),
        (if $outcome != null and (($outcome | IN($outcomes_ok[])) | not)
          then "invalid event.outcome: \($outcome)" else empty end),
        ( ($cats // [])[] | select((. | IN($cats_ok[])) | not) | "invalid event.category: \(.)" ),
        ( ($types // [])[] | select((. | IN($types_ok[])) | not) | "invalid event.type (not an ECS type): \(.)" ),
        ( ($types // [])[]
          | select((. | IN($types_ok[])) and ((. | IN($ok_types_for_cats[])) | not))
          | "event.type \"\(.)\" not allowed for event.category \($cats)" )
      ],
      warnings: [
        (if $cats != null and ($cats | type) != "array"   then "event.category should be an array" else empty end),
        (if $types != null and ($types | type) != "array" then "event.type should be an array" else empty end),
        (if $ecsver != null and ($ecsver | type) != "string" then "ecs.version should be a string" else empty end),
        (if ($kind == null and $cats == null and $types == null)
          then "no event categorization (event.kind/category/type) — expected on event docs" else empty end)
      ],
      custom_ns: ([ $paths[]
        | select((IN($known[])) | not)
        | split(".")[0]
        | select((IN($fieldsets[])) | not) ] | unique),
      field_count: ($paths | length)
    }
')"

echo "ECS v$version  —  transform: $transform"
echo "fields emitted: $(jq -r '.field_count' <<<"$report")"
cns="$(jq -r '.custom_ns | join(", ")' <<<"$report")"
[[ -n "$cns" ]] && echo "custom/vendor namespaces (allowed): $cns"
echo

nerr="$(jq -r '.errors | length' <<<"$report")"
nwarn="$(jq -r '.warnings | length' <<<"$report")"

if [[ "$nerr" -gt 0 ]]; then
  echo "ERRORS:"; jq -r '.errors[] | "  - " + .' <<<"$report"
else
  echo "ERRORS: none"
fi
echo
if [[ "$nwarn" -gt 0 ]]; then
  echo "WARNINGS:"; jq -r '.warnings[] | "  - " + .' <<<"$report"
else
  echo "WARNINGS: none"
fi

# Standard jq helper findings (warning only).
echo
helper_out="$(helper_findings "$transform")"
if [[ "$helper_out" == SKIPPED* ]]; then
  printf 'JQ HELPERS: %s\n' "$helper_out"
elif [[ -n "$helper_out" ]]; then
  printf 'JQ HELPERS (warning):\n%s\n' "$(printf '%s\n' "$helper_out" | sed 's/^/  - /')"
else
  printf 'JQ HELPERS: no findings\n'
fi

[[ "$nerr" -eq 0 ]]

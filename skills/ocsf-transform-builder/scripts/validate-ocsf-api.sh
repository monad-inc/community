#!/usr/bin/env bash
# Validate a transform's output against the OFFICIAL OCSF schema validator API
# (the `validate2` endpoint documented at
# https://schema.ocsf.io/doc/index.html#/Tools/SchemaWeb.SchemaController.validate2).
#
# This is the authoritative conformance check. Unlike validate-against-ocsf.sh
# (a local structural required/recommended/unknown-key diff), the official API
# also catches:
#   - constraint failures (e.g. "at_least_one" of service/dst_endpoint)
#   - enum value validation (e.g. activity_id not in the class's allowed set)
#   - type validation (string where an integer is required, etc.)
#   - deprecation warnings
#   - recommended-attribute warnings
#
# Usage:
#   validate-ocsf-api.sh <transform.yaml> <input.json> [--slurp]
#
# Examples:
#   validate-ocsf-api.sh okta-systemlog.yaml sample.json
#   validate-ocsf-api.sh wiz-vulnerabilities.yaml sample-array.json --slurp
#
# Endpoint selection:
#   The transform output is normalized to an array of events. A single event is
#   POSTed to /api/v2/validate; multiple events to /api/v2/validate_bundle.
#
# Schema version caveat:
#   The hosted validator at schema.ocsf.io always validates against the LATEST
#   published OCSF schema (it reads metadata.version from each event only to
#   emit a "version_earlier" warning). For transforms targeting an older
#   version, expect version/deprecation warnings that do not apply to the
#   targeted version. To validate against a specific version, run the OCSF
#   server locally pinned to that schema and point this script at it:
#     OCSF_VALIDATOR_URL=http://localhost:8080 validate-ocsf-api.sh ...
#   See https://github.com/ocsf/ocsf-server. The local structural check in
#   validate-against-ocsf.sh remains the version-pinned complement.
#
# Requires: jq, curl, plus run-transform.sh in the same directory (which needs
# yq + jq). Network access to the validator unless OCSF_VALIDATOR_URL is local.

set -euo pipefail

if [[ $# -lt 2 ]]; then
  sed -n '2,40p' "$0" >&2
  exit 64
fi

transform="$1"
input="$2"
shift 2

here="$(cd "$(dirname "$0")" && pwd)"
base_url="${OCSF_VALIDATOR_URL:-https://schema.ocsf.io}"
base_url="${base_url%/}"

command -v jq   >/dev/null || { echo "jq required"   >&2; exit 69; }
command -v curl >/dev/null || { echo "curl required" >&2; exit 69; }

# Run the transform and collapse its (possibly multi-object / NDJSON) output
# into a single JSON array of events.
raw_output=$("$here/run-transform.sh" "$transform" "$input" "$@")
events=$(printf '%s' "$raw_output" | jq -sc 'map(if type == "array" then .[] else . end)')
event_count=$(jq 'length' <<<"$events")

if [[ "$event_count" == "0" ]]; then
  echo "transform produced no events" >&2
  exit 65
fi

printf 'Validator: %s  (official OCSF validate2 API)\n' "$base_url"
printf 'Transform: %s\n' "$transform"
printf 'Events:    %s\n\n' "$event_count"

if [[ "$event_count" == "1" ]]; then
  body=$(jq -c '.[0]' <<<"$events")
  resp=$(curl -sS -m 60 -X POST -H 'Content-Type: application/json' \
    --data "$body" "$base_url/api/v2/validate")
  # Wrap the single-event response so the report renderer below is uniform.
  resp=$(jq -c '{error_count, warning_count, event_validations: [{errors, warnings}]}' <<<"$resp")
else
  body=$(jq -c '{events: .}' <<<"$events")
  resp=$(curl -sS -m 120 -X POST -H 'Content-Type: application/json' \
    --data "$body" "$base_url/api/v2/validate_bundle")
fi

# Surface raw transport/parse errors (e.g. "Unexpected body") verbatim.
if ! jq -e 'has("error_count")' <<<"$resp" >/dev/null 2>&1; then
  echo "validator did not return a result:" >&2
  printf '%s\n' "$resp" >&2
  exit 70
fi

error_count=$(jq -r '.error_count // 0' <<<"$resp")
warning_count=$(jq -r '.warning_count // 0' <<<"$resp")

# Per-event breakdown.
jq -r '
  (.event_validations // []) | to_entries[] |
  "── event \(.key) ──",
  ( (.value.errors // []) as $e |
    if ($e | length) == 0 then "  ERRORS: none"
    else "  ERRORS:", ($e[] | "    - [\(.error)] \(.message)")
    end ),
  ( (.value.warnings // []) as $w |
    if ($w | length) == 0 then "  WARNINGS: none"
    else "  WARNINGS:", ($w[] | "    - [\(.warning)] \(.message)")
    end ),
  ""
' <<<"$resp"

printf 'TOTAL: %s error(s), %s warning(s)\n' "$error_count" "$warning_count"

# Exit non-zero if the validator reported any errors (CI-friendly). Warnings
# do not fail the check.
[[ "$error_count" == "0" ]]

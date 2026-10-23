#!/usr/bin/env bash
# Validate a CEF transform chain. CEF has no schema server; this checks the
# {_cef:{...}} intermediate contract (the T1 authoring surface, exact) and then
# renders it through the shared serializer and structurally validates the CEF:0
# string (header shape, severity range, no raw newlines; soft checks on keys).
#
# Usage:
#   validate-cef.sh <mapping.yaml> <input.json>   # run T1 -> serializer -> validate
#   validate-cef.sh --string 'CEF:0|...'          # validate a raw CEF string only
#
# Mapping mode also warns about standard jq helper drift (jq-helpers.sh check)
# and about time parsing done without the standard to_epoch_ms helper.
#
# Requires: jq, yq (mikefarah), run-transform.sh + templates/cef-serializer.yaml
# in this skill.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
serializer="$here/../templates/cef-serializer.yaml"
dict="$here/../references/cef-extension-dictionary.json"

# --- CEF string validator (jq program, shared by both modes) ---
string_report() {  # $1 = CEF message string
  local msg="$1"
  local re='^CEF:0\|(?<vendor>(?:\\.|[^|\\])*)\|(?<product>(?:\\.|[^|\\])*)\|(?<version>(?:\\.|[^|\\])*)\|(?<sig>(?:\\.|[^|\\])*)\|(?<name>(?:\\.|[^|\\])*)\|(?<sev>(?:\\.|[^|\\])*)\|(?<ext>.*)$'
  jq -n --arg msg "$msg" --arg re "$re" --slurpfile D "$dict" '
    ($D[0].keys | keys) as $known_keys
    | ($msg | if test($re) then capture($re) else null end) as $cap
    | {
        errors: [
          (if ($msg | test("^CEF:0\\|") | not) then "does not start with CEF:0|" else empty end),
          (if $cap == null then "malformed CEF header (need 7 pipe-delimited fields after CEF:0)" else empty end),
          (if $msg | test("[\n\r]") then "message contains a raw newline/CR (must be encoded \\n / \\r)" else empty end),
          (if $cap != null and ($cap.sev | test("^(Unknown|Low|Medium|High|Very-High|10|[0-9])$") | not)
            then "severity \"\($cap.sev)\" is not 0-10 or a named level" else empty end)
        ],
        warnings: (
          (if $cap == null then [] else
            ([ $cap.ext | scan("(?:^| )([A-Za-z][A-Za-z0-9]*)=") | .[0] ] | unique) as $keys
            | [
                ( $keys[]
                  | select(test("^(cs|cn|cfp|flexString)[0-9]+$") or test("^deviceCustomDate[0-9]+$"))
                  | . as $k | select(($keys | index($k + "Label")) | not)
                  | "custom slot \($k) has no \($k)Label in the extension" ),
                ( $keys[]
                  | select((test("Label$") | not))
                  | select(test("^(cs|cn|cfp|flexString|deviceCustomDate|c6a|flexDate)[0-9]+$") | not)
                  | select((IN($known_keys[])) | not)
                  | "non-standard extension key \"\(.)\" (allowed, but prefer a dictionary key or custom slot)" ),
                ( $cap.ext | scan("(?:^| )(?:rt|start|end|art)=([^ ]+)") | .[0]
                  | select(test("^[0-9]{13}$") | not)
                  | "time value \"\(.)\" is not 13-digit epoch-ms" )
              ]
          end)
        )
      }
  '
}

if [[ "${1:-}" == "--string" ]]; then
  [[ $# -ge 2 ]] || { sed -n '2,14p' "$0" >&2; exit 64; }
  report="$(string_report "$2")"
  contract='{"errors":[],"warnings":[]}'
  msg="$2"
else
  [[ $# -ge 2 ]] || { sed -n '2,14p' "$0" >&2; exit 64; }
  transform="$1"; input="$2"
  [[ -f "$serializer" ]] || { echo "missing serializer template at $serializer" >&2; exit 66; }

  inter="$("$here/run-transform.sh" "$transform" "$input" | jq 'if type == "array" then .[0] else . end')"

  # Standard jq helpers: drift, missing dependencies, and unmarked definitions
  # (see SKILL.md "Standard jq helpers"), plus hand-rolled time parsing.
  helper_warns="$("$here/jq-helpers.sh" check "$transform" 2>&1 \
    | grep -E 'DRIFT|MISSING-DEP|UNMANAGED|ERROR' | sed 's/^[[:blank:]]*//' | jq -R . | jq -sc . || true)"
  [[ -n "$helper_warns" ]] || helper_warns='[]'
  query="$(yq -r '.config.operations[].arguments.query' "$transform")"
  if ! printf '%s\n' "$query" | grep -q '# >>> helper: to_epoch_ms' \
     && printf '%s\n' "$query" | grep -qE 'fromdateiso8601|fromdate|strptime|mktime|dateadd|datesub'; then
    helper_warns="$(jq -c '. + ["mapping parses time itself; use the standard to_epoch_ms helper (jq-helpers.sh show to_epoch_ms)"]' <<<"$helper_warns")"
  fi

  # T1 {_cef} contract check
  contract="$(jq -n --argjson c "$inter" --argjson helper_warns "$helper_warns" '
    ($c._cef) as $x
    | ($x.extension // {}) as $ext
    | {
        errors: [
          (if $x == null then "output has no _cef object" else empty end),
          (if $x != null and (($x.vendor | type) != "string" or $x.vendor == "") then "_cef.vendor missing/empty" else empty end),
          (if $x != null and (($x.product | type) != "string" or $x.product == "") then "_cef.product missing/empty" else empty end),
          (if $x != null and ($x.signature_id == null) then "_cef.signature_id missing" else empty end),
          (if $x != null and ($x.name == null) then "_cef.name missing" else empty end),
          (if $x != null and (($ext | type) != "object") then "_cef.extension must be an object" else empty end),
          ( $ext | keys[]
            | select(test("^(cs|cn|cfp|flexString)[0-9]+$") or test("^deviceCustomDate[0-9]+$"))
            | . as $k | select(($ext | has($k + "Label")) | not)
            | "custom slot \($k) missing its \($k)Label" )
        ],
        warnings: [
          (if $x != null and ($x.severity != null) and (($x.severity | type) != "number")
            then "_cef.severity should be an integer 0-10 (serializer coerces non-numbers to 0)"
            elif $x != null and ($x.severity | type) == "number" and ($x.severity < 0 or $x.severity > 10)
            then "_cef.severity \($x.severity) out of 0-10 (serializer clamps)" else empty end),
          ( ["rt","start","end","art"][] | . as $tk
            | select(($ext[$tk] != null) and (($ext[$tk] | type) != "number"))
            | "_cef.extension.\($tk) should be epoch-ms number, got \($ext[$tk] | type)" ),
          $helper_warns[]
        ]
      }')"

  tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
  printf '%s' "$inter" > "$tmp"
  msg="$("$here/run-transform.sh" "$serializer" "$tmp" | jq -r '.message')"
  report="$(string_report "$msg")"
fi

echo "CEF message:"
echo "  $msg"
echo

nerr="$(jq -s '[.[].errors[]] | length' <<<"$contract"$'\n'"$report")"
nwarn="$(jq -s '[.[].warnings[]] | length' <<<"$contract"$'\n'"$report")"

if [[ "$nerr" -gt 0 ]]; then
  echo "ERRORS:"; jq -s -r '[.[].errors[]] | .[] | "  - " + .' <<<"$contract"$'\n'"$report"
else
  echo "ERRORS: none"
fi
echo
if [[ "$nwarn" -gt 0 ]]; then
  echo "WARNINGS:"; jq -s -r '[.[].warnings[]] | .[] | "  - " + .' <<<"$contract"$'\n'"$report"
else
  echo "WARNINGS: none"
fi

[[ "$nerr" -eq 0 ]]

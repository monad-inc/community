#!/usr/bin/env bash
# Copyright 2026 Monad, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# tls-cert-to-syslog-input.sh
#
# Registers device TLS-certificate SHA-256 fingerprints on a Monad pipeline's
# Syslog input, so that sources which CANNOT use SNI can still be routed to the
# correct pipeline. Monad's syslog receiver matches the client-certificate
# SHA-256 fingerprint of an incoming connection against the list configured on
# each Syslog input (settings.cert_fingerprints) and routes accordingly.
#
# For each entry in the input file the script:
#   1. Connects to the device over TLS with `openssl s_client`.
#   2. Retrieves its leaf certificate and computes the SHA-256 fingerprint
#      (64-character lowercase hex over the DER encoding).
#   3. Adds that fingerprint to the `cert_fingerprints` list on the Syslog
#      input of the specified pipeline, via the Monad REST API.
#
# Existing fingerprints are preserved (merge + de-dupe) unless --replace is given.
#
# Prerequisites:
#   - The destination pipeline already contains a "Syslog" input node
#     (connector id `monad-syslog`).
#   - The Monad API key is an organization-level key permitted to read pipelines
#     and update inputs.
#   - The fingerprint computed here must be the certificate the device presents
#     as its CLIENT certificate when it connects outbound to Monad's syslog
#     endpoint. (For appliances that use one identity cert for both server and
#     client TLS, that is the cert this script retrieves.)
#
# ---------------------------------------------------------------------------
# Usage:
#   tls-cert-to-syslog-input.sh -f <ip_file> -p <pipeline_id> [-k <api_key>] [options]
#
# Input (at least one of):
#   -f, --file            Input file (one IP, host, or host:port per line); each
#                         device is probed over TLS to compute its cert SHA-256.
#       --hashes-file     File of precomputed SHA-256 fingerprints (64-char hex,
#                         one per line); added as-is with no TLS probe. Use for
#                         pre-collected fingerprints or bulk loads.
#
# Required:
#   -p, --pipeline-id     Destination Monad pipeline id (its Syslog input is updated).
#
# API key (one of):
#   -k, --api-key         Monad API key, OR
#   env MONAD_API_KEY     Monad API key, OR
#   (interactive prompt if neither is set and a terminal is attached).
#
# Optional:
#   -o, --organization-id Monad organization id. Auto-resolved from the API key
#                         when the key has access to exactly one organization.
#       --input-id        Update this Syslog input/component id directly and skip
#                         pipeline lookup (use if a pipeline has multiple inputs).
#   -P, --port            Default TCP port for the DEVICE probe (default: 443).
#   -t, --timeout         Per-device TLS connect timeout in seconds (default: 10).
#   -u, --base-url        Monad API base URL (default: https://app.monad.com/api).
#       --replace         Replace cert_fingerprints instead of merging with existing.
#   -n, --dry-run         Do all reads and print the fingerprints that WOULD be
#                         written, but do not PATCH.
#   -h, --help            Show this help.
#
# Input file format:
#   - One entry per line: "1.2.3.4", "host.example.com", or "1.2.3.4:8443".
#   - Blank lines and lines beginning with '#' are ignored.
#
# Example:
#   export MONAD_API_KEY='...'
#   ./tls-cert-to-syslog-input.sh -f devices.txt -p <pipeline_id>
# ---------------------------------------------------------------------------

set -uo pipefail

# ---- defaults --------------------------------------------------------------
IP_FILE=""
HASHES_FILE=""
PIPELINE_ID=""
API_KEY="${MONAD_API_KEY:-}"
ORG_ID=""
INPUT_ID=""
DEFAULT_PORT=443
CONNECT_TIMEOUT=10
BASE_URL="https://app.monad.com/api"
REPLACE=0
DRY_RUN=0

SYSLOG_SUBTYPE="monad-syslog"
PROG="$(basename "$0")"

# --help prints the doc block above: from the first blank line (end of the
# license header) up to the first line of code, with comment markers stripped.
usage() { awk '!/^(#|$)/{exit} /^$/{f=1} f' "$0" | sed 's/^# \{0,1\}//; s/^#//'; }
die()   { echo "$PROG: error: $*" >&2; exit 1; }

# Printed whenever the --file IP list can't be read, so the user knows the
# expected layout.
ip_file_format_help() {
  cat >&2 <<'EOF'

The IP list (--file) must be a plain text file the script can read, with one
entry per line. Each line may be:
  - an IP address            e.g.  203.0.113.10
  - a hostname               e.g.  switch01.corp.example.com
  - host:port (non-443)      e.g.  203.0.113.10:8443

Blank lines and lines beginning with '#' are ignored.

Example (devices.txt):
  # data center A
  203.0.113.10
  203.0.113.11:8443
  switch01.corp.example.com

Then re-run, e.g.:
  ./tls-cert-to-syslog-input.sh -f devices.txt -p <pipeline_id>

If the file exists but this message mentions permissions, make it readable:
  chmod +r devices.txt
EOF
}

# Printed whenever the --hashes-file list can't be read, so the user knows the
# expected layout.
hashes_file_format_help() {
  cat >&2 <<'EOF'

The fingerprints file (--hashes-file) must be a plain text file the script can
read, with one SHA-256 certificate fingerprint per line. Each fingerprint must
be 64 hexadecimal characters (no colons, no "sha256:" prefix); case-insensitive.

Blank lines and lines beginning with '#' are ignored.

Example (fingerprints.txt):
  # pre-collected device cert fingerprints
  e3b02826789d653d224d3edacbe4e877cb7286fc4c922672f6226741ca57ad65
  d07b43fd8d3d7aacb95750667417cc81264b60089c72df1a7b0a1862dc791d96

Then re-run, e.g.:
  ./tls-cert-to-syslog-input.sh --hashes-file fingerprints.txt -p <pipeline_id>

If the file exists but this message mentions permissions, make it readable:
  chmod +r fingerprints.txt
EOF
}

# ---- arg parsing -----------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -f|--file)            IP_FILE="${2:-}"; shift 2 ;;
    --hashes-file)        HASHES_FILE="${2:-}"; shift 2 ;;
    -p|--pipeline-id)     PIPELINE_ID="${2:-}"; shift 2 ;;
    -k|--api-key)         API_KEY="${2:-}"; shift 2 ;;
    -o|--organization-id) ORG_ID="${2:-}"; shift 2 ;;
    --input-id)           INPUT_ID="${2:-}"; shift 2 ;;
    -P|--port)            DEFAULT_PORT="${2:-}"; shift 2 ;;
    -t|--timeout)         CONNECT_TIMEOUT="${2:-}"; shift 2 ;;
    -u|--base-url)        BASE_URL="${2:-}"; shift 2 ;;
    --replace)            REPLACE=1; shift ;;
    -n|--dry-run)         DRY_RUN=1; shift ;;
    -h|--help)            usage; exit 0 ;;
    *) die "unknown argument: $1 (use --help)" ;;
  esac
done

# ---- prerequisite checks ---------------------------------------------------
for bin in openssl curl jq; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin is required but not found in PATH"
done

TIMEOUT_BIN=""
if   command -v timeout  >/dev/null 2>&1; then TIMEOUT_BIN="timeout"
elif command -v gtimeout >/dev/null 2>&1; then TIMEOUT_BIN="gtimeout"; fi

[ -n "$IP_FILE" ] || [ -n "$HASHES_FILE" ] || die "provide --file and/or --hashes-file (use --help)"

# Validate the IP list is readable, with formatting guidance on any failure.
if [ -n "$IP_FILE" ]; then
  if [ ! -e "$IP_FILE" ]; then
    echo "$PROG: error: IP list file not found: $IP_FILE" >&2
    ip_file_format_help
    exit 1
  elif [ ! -f "$IP_FILE" ]; then
    echo "$PROG: error: IP list path is not a regular file: $IP_FILE" >&2
    ip_file_format_help
    exit 1
  elif [ ! -r "$IP_FILE" ]; then
    echo "$PROG: error: IP list file is not readable (check permissions): $IP_FILE" >&2
    ip_file_format_help
    exit 1
  fi
fi

# Validate the fingerprints list is readable, with formatting guidance on any failure.
if [ -n "$HASHES_FILE" ]; then
  if [ ! -e "$HASHES_FILE" ]; then
    echo "$PROG: error: fingerprints file not found: $HASHES_FILE" >&2
    hashes_file_format_help
    exit 1
  elif [ ! -f "$HASHES_FILE" ]; then
    echo "$PROG: error: fingerprints path is not a regular file: $HASHES_FILE" >&2
    hashes_file_format_help
    exit 1
  elif [ ! -r "$HASHES_FILE" ]; then
    echo "$PROG: error: fingerprints file is not readable (check permissions): $HASHES_FILE" >&2
    hashes_file_format_help
    exit 1
  fi
fi
[ -n "$PIPELINE_ID" ] || [ -n "$INPUT_ID" ] || die "missing required --pipeline-id (use --help)"

if [ -z "$API_KEY" ] && [ -t 0 ]; then
  printf 'Monad API key: ' >&2; read -rs API_KEY; printf '\n' >&2
fi
[ -n "$API_KEY" ] || die "no API key provided (use --api-key, MONAD_API_KEY, or run interactively)"

BASE_URL="${BASE_URL%/}"

# Keep the API key out of the process list by passing headers via a curl config.
CURL_CFG="$(mktemp "${TMPDIR:-/tmp}/monad-curl.XXXXXX")" || die "could not create temp file"
cleanup() { rm -f "$CURL_CFG"; }
trap cleanup EXIT INT TERM
chmod 600 "$CURL_CFG"
{
  printf 'header = "Authorization: ApiKey %s"\n' "$API_KEY"
  printf 'header = "Content-Type: application/json"\n'
} > "$CURL_CFG"

# ---- API helper ------------------------------------------------------------
# api <METHOD> <PATH> [json-body]   ->  sets API_BODY and API_CODE
api() {
  local method="$1" path="$2" body="${3:-}"
  local out
  if [ -n "$body" ]; then
    out="$(curl -sS --config "$CURL_CFG" -X "$method" "${BASE_URL}${path}" \
             --data "$body" -w $'\n%{http_code}' 2>&1)"
  else
    out="$(curl -sS --config "$CURL_CFG" -X "$method" "${BASE_URL}${path}" \
             -w $'\n%{http_code}' 2>&1)"
  fi
  API_CODE="$(printf '%s' "$out" | tail -n1)"
  API_BODY="$(printf '%s' "$out" | sed '$d')"
}

api_ok() { case "$API_CODE" in 2??) return 0 ;; *) return 1 ;; esac; }

# ---- resolve organization --------------------------------------------------
if [ -z "$ORG_ID" ]; then
  api GET "/v1/organizations"
  api_ok || die "could not list organizations (HTTP $API_CODE): $API_BODY"
  # Accept array, or {data:[...]}, or {organizations:[...]}.
  org_ids="$(printf '%s' "$API_BODY" | jq -r '
    (if type=="array" then . elif .data then .data elif .organizations then .organizations else [] end)
    | .[]?.id // empty')"
  count="$(printf '%s\n' "$org_ids" | grep -c . || true)"
  if [ "$count" -eq 1 ]; then
    ORG_ID="$(printf '%s\n' "$org_ids" | head -n1)"
  elif [ "$count" -eq 0 ]; then
    die "no organizations accessible to this API key"
  else
    die "API key has access to multiple organizations; specify --organization-id. Found:
$org_ids"
  fi
fi
echo "Organization : $ORG_ID"

# ---- resolve the Syslog input/component id ---------------------------------
if [ -z "$INPUT_ID" ]; then
  api GET "/v2/${ORG_ID}/pipelines/${PIPELINE_ID}"
  api_ok || die "could not fetch pipeline $PIPELINE_ID (HTTP $API_CODE): $API_BODY"
  # bash 3.2 (macOS default) has no `mapfile`; read into an array portably.
  SYS_IDS=()
  while IFS= read -r _sid; do
    [ -n "$_sid" ] && SYS_IDS+=("$_sid")
  done < <(printf '%s' "$API_BODY" | jq -r --arg sub "$SYSLOG_SUBTYPE" \
    '.nodes[]? | select(.component_type=="input" and .component_sub_type==$sub) | .component_id')
  if [ "${#SYS_IDS[@]}" -eq 0 ]; then
    # The pipeline has no Syslog input. Report what input connector(s) it does
    # have so the user understands why this script can't act on it.
    present="$(printf '%s' "$API_BODY" | jq -r \
      '[.nodes[]? | select(.component_type=="input") | .component_sub_type] | unique | join(", ")')"
    {
      echo "$PROG: error: pipeline $PIPELINE_ID does not use a Syslog Input Connector."
      if [ -n "$present" ]; then
        echo "  Its input connector(s): ${present}"
      else
        echo "  It has no input nodes."
      fi
      echo
      echo "This script only configures Syslog inputs (connector id '$SYSLOG_SUBTYPE'),"
      echo "because the cert_fingerprints routing list is a Syslog-input feature."
      echo "To fix, do one of:"
      echo "  - point -p at a pipeline whose input is a Syslog Input Connector;"
      echo "  - add a Syslog input to this pipeline in the Monad UI, then re-run;"
      echo "  - pass --input-id <id> to target an existing Syslog input/component directly."
    } >&2
    exit 1
  elif [ "${#SYS_IDS[@]}" -gt 1 ]; then
    die "pipeline $PIPELINE_ID has multiple Syslog inputs (${SYS_IDS[*]}); pass --input-id to choose one"
  fi
  INPUT_ID="${SYS_IDS[0]}"
fi
echo "Syslog input : $INPUT_ID"

# ---- read existing input config --------------------------------------------
api GET "/v1/${ORG_ID}/inputs/${INPUT_ID}"
api_ok || die "could not fetch input $INPUT_ID (HTTP $API_CODE): $API_BODY"
EXISTING_SETTINGS="$(printf '%s' "$API_BODY" | jq -c '.config.settings // {}')"
EXISTING_FPS="$(printf '%s' "$EXISTING_SETTINGS" | jq -c '.cert_fingerprints // []')"
echo "Existing fingerprints: $(printf '%s' "$EXISTING_FPS" | jq 'length')"
echo "-----------------------------------------------------------"

# ---- gather fingerprints from devices --------------------------------------
device_connect() {
  local host="$1" port="$2"
  if [ -n "$TIMEOUT_BIN" ]; then
    "$TIMEOUT_BIN" "$CONNECT_TIMEOUT" \
      openssl s_client -connect "${host}:${port}" -servername "$host" 2>/dev/null </dev/null
  else
    openssl s_client -connect "${host}:${port}" -servername "$host" 2>/dev/null </dev/null
  fi
}

NEW_FPS_FILE="$(mktemp "${TMPDIR:-/tmp}/monad-fps.XXXXXX")"
trap 'rm -f "$CURL_CFG" "$NEW_FPS_FILE"' EXIT INT TERM

total=0; ok=0; failed=0; loaded=0

# Preload any precomputed fingerprints (no TLS probe).
if [ -n "$HASHES_FILE" ]; then
  while IFS= read -r hraw || [ -n "$hraw" ]; do
    h="$(printf '%s' "$hraw" | sed 's/[[:space:]]//g' | tr 'A-F' 'a-f')"
    [ -z "$h" ] && continue
    case "$h" in \#*) continue ;; esac
    if printf '%s' "$h" | grep -qiE '^[0-9a-f]{64}$'; then
      loaded=$((loaded + 1)); ok=$((ok + 1))
      printf '%s\n' "$h" >> "$NEW_FPS_FILE"
    else
      failed=$((failed + 1))
      echo "[FAIL] precomputed entry is not 64-char hex: $h"
    fi
  done < "$HASHES_FILE"
  echo "Loaded $loaded precomputed fingerprint(s) from $HASHES_FILE"
fi

# Probe devices over TLS to compute fingerprints.
if [ -n "$IP_FILE" ]; then
  while IFS= read -r raw || [ -n "$raw" ]; do
    line="$(printf '%s' "$raw" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -z "$line" ] && continue
    case "$line" in \#*) continue ;; esac
    total=$((total + 1))

    host="${line%%:*}"
    if [ "$line" != "$host" ]; then port="${line##*:}"; else port="$DEFAULT_PORT"; fi

    sha_hex="$(device_connect "$host" "$port" \
      | openssl x509 -outform DER 2>/dev/null \
      | openssl dgst -sha256 2>/dev/null \
      | sed 's/^.*= *//' | tr 'A-F' 'a-f')"

    if printf '%s' "$sha_hex" | grep -qiE '^[0-9a-f]{64}$'; then
      ok=$((ok + 1))
      echo "[ OK ] $host:$port  $sha_hex"
      printf '%s\n' "$sha_hex" >> "$NEW_FPS_FILE"
    else
      failed=$((failed + 1))
      echo "[FAIL] $host:$port  could not retrieve/parse certificate"
    fi
  done < "$IP_FILE"
fi

echo "-----------------------------------------------------------"

if [ "$ok" -eq 0 ]; then
  echo "No fingerprints collected; nothing to update."
  echo "Devices processed : $total"
  echo "Cert/hash failures: $failed"
  [ "$failed" -gt 0 ] && exit 1 || exit 0
fi

NEW_FPS_JSON="$(jq -R 'select(length>0)' < "$NEW_FPS_FILE" | jq -s 'unique')"

if [ "$REPLACE" -eq 1 ]; then
  FINAL_FPS="$(printf '%s' "$NEW_FPS_JSON" | jq -c 'map(ascii_downcase) | unique')"
else
  FINAL_FPS="$(jq -cn --argjson a "$EXISTING_FPS" --argjson b "$NEW_FPS_JSON" \
    '($a + $b) | map(ascii_downcase) | unique')"
fi

# Merge into the existing settings object so no other settings are dropped.
NEW_SETTINGS="$(jq -cn --argjson s "$EXISTING_SETTINGS" --argjson fps "$FINAL_FPS" \
  '$s + {cert_fingerprints: $fps}')"
PATCH_BODY="$(jq -cn --arg type "$SYSLOG_SUBTYPE" --argjson settings "$NEW_SETTINGS" \
  '{type: $type, config: {settings: $settings}}')"

echo "Collected $ok new fingerprint(s); resulting cert_fingerprints count: $(printf '%s' "$FINAL_FPS" | jq 'length')"

if [ "$DRY_RUN" -eq 1 ]; then
  echo "DRY RUN — would PATCH /v2/${ORG_ID}/inputs/${INPUT_ID} with:"
  printf '%s\n' "$PATCH_BODY" | jq .
  echo "Devices processed : $total"
  echo "Cert/hash failures: $failed"
  [ "$failed" -gt 0 ] && exit 1 || exit 0
fi

# ---- write back ------------------------------------------------------------
api PATCH "/v2/${ORG_ID}/inputs/${INPUT_ID}" "$PATCH_BODY"
if api_ok; then
  echo "Updated Syslog input $INPUT_ID (HTTP $API_CODE). cert_fingerprints now: $(printf '%s' "$FINAL_FPS" | jq 'length')"
else
  echo "ERROR: failed to update input (HTTP $API_CODE): $API_BODY" >&2
  echo "Devices processed : $total / hashes: $ok / failures: $failed" >&2
  exit 1
fi

echo "Devices processed : $total"
echo "Fingerprints added: $ok"
echo "Cert/hash failures: $failed"
[ "$failed" -gt 0 ] && exit 1 || exit 0

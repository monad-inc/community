#!/usr/bin/env bash
#
# <script-name>.sh
#
# <One-line summary of what this script does.>
#
# ---------------------------------------------------------------------------
# Usage:
#   <script-name>.sh -x <value> [options]
#
# Required:
#   -x, --example       <description>
#
# API key (one of):
#   -k, --api-key       Monad API key, OR
#   env MONAD_API_KEY   Monad API key, OR
#   (interactive prompt if neither is set and a terminal is attached).
#
# Optional:
#   -n, --dry-run       Preview without changing Monad state.
#   -h, --help          Show this help.
# ---------------------------------------------------------------------------

set -uo pipefail

API_KEY="${MONAD_API_KEY:-}"
BASE_URL="https://app.monad.com/api"
PROG="$(basename "$0")"

usage() { sed -n '2,/^# ----/p' "$0" | sed 's/^# \{0,1\}//; s/^#//'; }
die()   { echo "$PROG: error: $*" >&2; exit 1; }

# ---- arg parsing -----------------------------------------------------------
while [ $# -gt 0 ]; do
  case "$1" in
    -k|--api-key) API_KEY="${2:-}"; shift 2 ;;
    -n|--dry-run) DRY_RUN=1; shift ;;
    -h|--help)    usage; exit 0 ;;
    *) die "unknown argument: $1 (use --help)" ;;
  esac
done

# ---- prerequisites ---------------------------------------------------------
for bin in curl jq; do
  command -v "$bin" >/dev/null 2>&1 || die "$bin is required but not found in PATH"
done

# Resolve the API key without putting it on the command line / process list.
if [ -z "$API_KEY" ] && [ -t 0 ]; then
  printf 'Monad API key: ' >&2; read -rs API_KEY; printf '\n' >&2
fi
[ -n "$API_KEY" ] || die "no API key provided (use --api-key, MONAD_API_KEY, or run interactively)"

# Pass the auth header to curl via a mode-600 config so the key stays out of `ps`.
CURL_CFG="$(mktemp "${TMPDIR:-/tmp}/monad-curl.XXXXXX")" || die "could not create temp file"
trap 'rm -f "$CURL_CFG"' EXIT INT TERM
chmod 600 "$CURL_CFG"
printf 'header = "Authorization: ApiKey %s"\n' "$API_KEY" > "$CURL_CFG"

# ---- your logic here -------------------------------------------------------
# Example call:
#   curl -sS --config "$CURL_CFG" "${BASE_URL%/}/v1/organizations"

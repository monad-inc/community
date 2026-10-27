#!/usr/bin/env bash
# Look up a CEF extension key (or list them) from the extension dictionary.
#
# Usage:
#   lookup-cef-key.sh <short_key>   # e.g. suser, rt, src
#   lookup-cef-key.sh --list        # all standard keys + custom slots
#   lookup-cef-key.sh --custom      # just the custom-slot families

set -euo pipefail

if [[ $# -lt 1 ]]; then
  sed -n '2,8p' "$0" >&2
  exit 64
fi

here="$(cd "$(dirname "$0")" && pwd)"
dict="$here/../references/cef-extension-dictionary.json"
[[ -f "$dict" ]] || { echo "no dictionary at $dict" >&2; exit 66; }

case "$1" in
  --list)
    echo "# standard keys"
    jq -r '.keys | to_entries[] | "\(.key)\t\(.value.full_name)\t[\(.value.type)]"' "$dict" | sort
    echo "# custom slots"
    jq -r '.custom_slots | to_entries[] | "\(.key)\t-> label \(.value.label)\t[\(.value.type)]"' "$dict"
    ;;
  --custom)
    jq -r '.custom_slots | to_entries[] | "\(.key)\t-> label \(.value.label)\t[\(.value.type)]"' "$dict"
    ;;
  *)
    if jq -e --arg k "$1" '.keys | has($k)' "$dict" >/dev/null; then
      jq -r --arg k "$1" '.keys[$k] | {short: $k, full_name, type, max}' "$dict"
    else
      echo "\"$1\" is not a standard CEF dictionary key. It is still valid CEF (arbitrary keys are allowed)," >&2
      echo "but consider a standard key or a custom slot (cs*/cn*/cfp* with a *Label). See --list." >&2
      exit 65
    fi
    ;;
esac

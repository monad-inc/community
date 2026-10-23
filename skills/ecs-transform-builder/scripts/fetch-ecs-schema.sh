#!/usr/bin/env bash
# Download an ECS version's generated flat schema from the elastic/ecs GitHub
# repo and install it as references/ecs/v<version>/ecs_flat.json, the file the
# lookup-ecs-field.sh and validate-against-ecs.sh scripts read.
#
# Usage:
#   fetch-ecs-schema.sh <version> [--force]
#
# Examples:
#   fetch-ecs-schema.sh 8.11.0
#   fetch-ecs-schema.sh 9.5.0 --force     # re-download over an existing copy
#
# Source: https://raw.githubusercontent.com/elastic/ecs/v<version>/generated/ecs/ecs_flat.yml
# (a flat map keyed by dotted field name; each entry carries type, level,
# normalize, and, for the categorization fields, allowed_values).
#
# Requires: curl, yq (mikefarah, v4), jq.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  sed -n '2,17p' "$0" >&2
  exit 64
fi

version="${1#v}"
force="${2:-}"

command -v curl >/dev/null || { echo "curl required" >&2; exit 69; }
command -v yq   >/dev/null || { echo "yq (mikefarah) required" >&2; exit 69; }
command -v jq   >/dev/null || { echo "jq required" >&2; exit 69; }

here="$(cd "$(dirname "$0")" && pwd)"
dest="$here/../references/ecs/v${version}"

if [[ -f "$dest/ecs_flat.json" && "$force" != "--force" ]]; then
  echo "ECS v$version already installed at $dest (pass --force to re-download)" >&2
  exit 0
fi

url="https://raw.githubusercontent.com/elastic/ecs/v${version}/generated/ecs/ecs_flat.yml"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "Fetching $url ..." >&2
curl -sSf --retry 3 -m 120 -o "$tmp/ecs_flat.yml" "$url" \
  || { echo "failed to fetch ECS v$version (is it a released tag of elastic/ecs?)" >&2; exit 70; }

yq -o=json '.' "$tmp/ecs_flat.yml" | jq -c '.' > "$tmp/ecs_flat.json"

mkdir -p "$dest"
mv "$tmp/ecs_flat.json" "$dest/ecs_flat.json"
printf 'Installed ECS v%s: %s fields -> %s\n' "$version" \
  "$(jq 'length' "$dest/ecs_flat.json")" "$dest" >&2

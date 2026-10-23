#!/usr/bin/env bash
# Download an OCSF schema version from schema.ocsf.io and install it as
# references/ocsf/v<version>/{schema.json,classes-index.json}, the shape the
# lookup-* and validate-against-ocsf.sh scripts read.
#
# Usage:
#   fetch-ocsf-schema.sh <version> [--force]
#   fetch-ocsf-schema.sh --list            # versions the server offers
#
# Examples:
#   fetch-ocsf-schema.sh 1.1.0
#   fetch-ocsf-schema.sh 1.5.0 --force     # re-download over an existing copy
#
# Environment:
#   OCSF_SCHEMA_URL  Schema server (default https://schema.ocsf.io). Point it at
#                    a locally-run ocsf-server to work offline.
#
# The schema is assembled from the per-facet /api endpoints (the legacy
# /export/schema endpoint fails for 1.6.0+), then normalized:
#   - attribute arrays (some server versions) are folded into one object
#   - extension classes/objects (e.g. Windows) are keyed "<ext>/<name>"
#   - cloud/osint are restored as profile attributes; the class endpoint
#     reports them as base-required on 1.8.0+, which they are not
#
# Requires: curl, jq. Makes roughly 300 HTTP requests; takes a minute or two.

set -euo pipefail

base_url="${OCSF_SCHEMA_URL:-https://schema.ocsf.io}"
base_url="${base_url%/}"

command -v jq   >/dev/null || { echo "jq required"   >&2; exit 69; }
command -v curl >/dev/null || { echo "curl required" >&2; exit 69; }

if [[ "${1:-}" == "--list" ]]; then
  curl -sSf "$base_url/api/versions" | jq -r '.versions[] | .version'
  exit 0
fi

if [[ $# -lt 1 ]]; then
  sed -n '2,26p' "$0" >&2
  exit 64
fi

version="${1#v}"
force="${2:-}"

here="$(cd "$(dirname "$0")" && pwd)"
dest="$here/../references/ocsf/v${version}"

if [[ -f "$dest/schema.json" && "$force" != "--force" ]]; then
  echo "OCSF v$version already installed at $dest (pass --force to re-download)" >&2
  exit 0
fi

api="$base_url/$version/api"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

get() {  # $1 = url, $2 = output file
  curl -sSf --retry 3 -m 60 -o "$2" "$1" || { echo "failed to fetch $1" >&2; return 1; }
}

echo "Fetching OCSF v$version from $base_url ..." >&2
get "$api/classes"    "$tmp/classes.list.json"
get "$api/objects"    "$tmp/objects.list.json"
get "$api/dictionary" "$tmp/dictionary.json"
get "$api/base_event" "$tmp/base_event.json"

# One line per facet: "<kind> <map key> <url path>". Extension members are
# served under <ext>/<name> and keyed the same way.
{
  jq -r '.[] | (if .extension then "\(.extension)/\(.name)" else .name end) | "classes \(.) \(.)"' "$tmp/classes.list.json"
  jq -r '.[] | (if .extension then "\(.extension)/\(.name)" else .name end) | "objects \(.) \(.)"' "$tmp/objects.list.json"
} > "$tmp/facets.txt"

mkdir -p "$tmp/classes" "$tmp/objects"
total=$(wc -l < "$tmp/facets.txt" | tr -d ' ')
echo "Fetching $total class/object definitions ..." >&2

# Fetch in parallel; file names replace "/" so extension keys stay flat.
while read -r kind key path; do
  printf '%s\n%s\n' "$tmp/$kind/${key//\//__}.json" "$api/$kind/$path"
done < "$tmp/facets.txt" \
  | xargs -n 2 -P 8 curl -sSf --retry 3 -m 60 -o

missing=0
while read -r kind key path; do
  [[ -s "$tmp/$kind/${key//\//__}.json" ]] || { echo "missing $kind/$key" >&2; missing=1; }
done < "$tmp/facets.txt"
[[ "$missing" == 0 ]] || { echo "incomplete download; nothing installed" >&2; exit 70; }

# Assemble {base_event, classes, dictionary_attributes, objects, types, version}.
assemble() {  # $1 = kind dir
  for f in "$tmp/$1"/*.json; do
    k="$(basename "$f" .json)"
    jq -c --arg k "${k//__//}" '{($k): .}' "$f"
  done | jq -s 'add // {}'
}
assemble classes > "$tmp/classes.json"
assemble objects > "$tmp/objects.json"

jq -cn \
  --arg version "$version" \
  --slurpfile classes "$tmp/classes.json" \
  --slurpfile objects "$tmp/objects.json" \
  --slurpfile dict "$tmp/dictionary.json" \
  --slurpfile base "$tmp/base_event.json" '
  def norm: if (.attributes | type) == "array" then .attributes |= add else . end;
  def unflatten_profiles:
    if .attributes.cloud then .attributes.cloud.profile //= "cloud" else . end
    | if .attributes.osint then .attributes.osint.profile //= "osint" else . end;
  {
    version: $version,
    base_event: ($base[0] | norm | unflatten_profiles),
    classes: ($classes[0] | map_values(norm | unflatten_profiles)),
    objects: ($objects[0] | map_values(norm)),
    dictionary_attributes: $dict[0].attributes,
    types: $dict[0].types.attributes
  }' > "$tmp/schema.json"

jq '[ .classes | to_entries[] | {
       name: .key, caption: .value.caption, uid: .value.uid,
       category: .value.category, category_name: .value.category_name,
       description: .value.description,
       required_attrs:    [ .value.attributes | to_entries[] | select(.value.requirement == "required")    | .key ],
       recommended_attrs: [ .value.attributes | to_entries[] | select(.value.requirement == "recommended") | .key ]
     } ] | sort_by(.uid)' "$tmp/schema.json" > "$tmp/classes-index.json"

mkdir -p "$dest"
mv "$tmp/schema.json" "$dest/schema.json"
mv "$tmp/classes-index.json" "$dest/classes-index.json"
printf 'Installed OCSF v%s: %s classes, %s objects -> %s\n' "$version" \
  "$(jq '.classes | length' "$dest/schema.json")" \
  "$(jq '.objects | length' "$dest/schema.json")" "$dest" >&2

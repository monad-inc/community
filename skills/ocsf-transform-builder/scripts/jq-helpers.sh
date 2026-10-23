#!/usr/bin/env bash
# Manage the standard jq helpers defined in this skill's SKILL.md
# ("Standard jq helpers" section), for example to_epoch_ms, to_iso, is_ip,
# prune (jq-helpers.sh list shows all). SKILL.md is the source of truth; transforms embed
# copies between "# >>> helper: <name>" and "# <<< helper: <name>" marker lines.
#
# Usage:
#   jq-helpers.sh list                      # helper names
#   jq-helpers.sh show <name>...            # print helpers (with markers) for pasting
#                                           # into a query; adds dependencies first
#   jq-helpers.sh check <transform.yaml>... # report drift from SKILL.md (exit 1),
#                                           # missing dependencies (exit 1), and
#                                           # unmarked definitions of helper names (warning)
#   jq-helpers.sh sync <transform.yaml>...  # rewrite drifted marked copies in place
#                                           # from SKILL.md; unmarked definitions are
#                                           # reported, never touched
#   jq-helpers.sh test [transform.yaml]     # run references/jq-helper-fixtures.json
#                                           # against SKILL.md's helpers (or the copies
#                                           # embedded in a transform) under jq, and
#                                           # gojq when on PATH or GOJQ is set
#
# Requires: bash, awk, jq; yq (mikefarah, v4) for check/test on a transform.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
skill_md="$here/../SKILL.md"
fixtures="$here/../references/jq-helper-fixtures.json"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- canonical helpers from SKILL.md -> $tmp/canon/<name>.jq (+ order file) ---
mkdir -p "$tmp/canon"
awk -v dir="$tmp/canon" '
  /^# >>> helper: / { name = $4; file = dir "/" name ".jq"; print name >> (dir "/ORDER"); }
  file != ""        { print > file }
  /^# <<< helper: / { close(file); file = "" }
' "$skill_md"
[[ -s "$tmp/canon/ORDER" ]] || { echo "no helpers found in $skill_md" >&2; exit 65; }
names="$(cat "$tmp/canon/ORDER")"

is_helper() { grep -qx "$1" "$tmp/canon/ORDER"; }
deps_of()   { sed -n 's/^# requires: //p' "$tmp/canon/$1.jq" | tr ', ' '\n\n' | sed '/^$/d'; }

# Resolve names + dependencies, emitted in SKILL.md order.
resolve() {
  local want="" n d
  for n in "$@"; do
    is_helper "$n" || { echo "unknown helper: $n (see: jq-helpers.sh list)" >&2; exit 64; }
    want="$want $n"
    for d in $(deps_of "$n"); do want="$want $d"; done
  done
  for n in $names; do
    case " $want " in *" $n "*) echo "$n" ;; esac
  done
}

# Print a transform's queries (all operations), dedented by yq.
queries() { yq -r '.config.operations[].arguments.query // ""' "$1"; }

# Extract the embedded marked copy of helper $2 from query text file $1.
embedded() {
  awk -v n="$2" '
    $0 ~ "^[[:blank:]]*# >>> helper: " n "[[:blank:]]*$" { p = 1 }
    p { sub(/^[[:blank:]]+/, ""); print }
    $0 ~ "^[[:blank:]]*# <<< helper: " n "[[:blank:]]*$" { p = 0 }
  ' "$1"
}

# Same, from the canonical copy, with leading whitespace stripped for comparison.
canon_flat() { sed 's/^[[:blank:]]*//' "$tmp/canon/$1.jq"; }

check_one() {  # $1 = transform; prints findings; returns 1 on drift/missing dep
  local t="$1" q="$tmp/q.jq" rc=0 n d present="" stripped
  queries "$t" > "$q"
  for n in $names; do
    if grep -Eq "^[[:blank:]]*# >>> helper: $n[[:blank:]]*$" "$q"; then
      present="$present $n"
      if ! diff -q <(canon_flat "$n") <(embedded "$q" "$n") >/dev/null; then
        echo "  DRIFT       $n (run: jq-helpers.sh sync $t)"; rc=1
      fi
    fi
  done
  for n in $present; do
    for d in $(deps_of "$n"); do
      case " $present " in *" $d "*) ;; *) echo "  MISSING-DEP $n requires $d"; rc=1 ;; esac
    done
  done
  # Unmarked definitions: strip marked blocks, then look for "def <name>".
  stripped="$(awk '/^[[:blank:]]*# >>> helper: /{p=1} !p{print} /^[[:blank:]]*# <<< helper: /{p=0}' "$q")"
  for n in $names; do
    if printf '%s\n' "$stripped" | grep -Eq "(^|[^A-Za-z0-9_])def[[:blank:]]+$n[[:blank:]]*[(:]"; then
      echo "  UNMANAGED   $n is defined without markers (replace it with: jq-helpers.sh show $n)"
    fi
  done
  return "$rc"
}

# Replace marked block $2 in YAML file $1 (in place) with the canonical copy,
# keeping the block's indentation. Leaves the file untouched on error.
replace_block() {
  local f="$1" n="$2" out="$tmp/out.yaml"
  if ! awk -v n="$n" -v canon="$tmp/canon/$n.jq" '
      BEGIN { while ((getline l < canon) > 0) c[++k] = l }
      !skip && $0 ~ "^[[:blank:]]*# >>> helper: " n "[[:blank:]]*$" {
        ind = $0; sub(/#.*/, "", ind)
        for (i = 1; i <= k; i++) print (c[i] == "" ? "" : ind c[i])
        skip = 1; next
      }
      skip { if ($0 ~ "^[[:blank:]]*# <<< helper: " n "[[:blank:]]*$") skip = 0; next }
      { print }
      END { if (skip) exit 3 }
    ' "$f" > "$out"; then
    echo "  ERROR       $n: unterminated marker block in $f; not changed" >&2
    return 1
  fi
  cat "$out" > "$f"
}

cmd="${1:-}"; [[ $# -gt 0 ]] && shift
case "$cmd" in
  list)
    printf '%s\n' $names
    ;;

  show)
    [[ $# -ge 1 ]] || { echo "usage: jq-helpers.sh show <name>..." >&2; exit 64; }
    first=1
    for n in $(resolve "$@"); do
      [[ $first == 1 ]] || echo
      cat "$tmp/canon/$n.jq"; first=0
    done
    ;;

  check)
    [[ $# -ge 1 ]] || { echo "usage: jq-helpers.sh check <transform.yaml>..." >&2; exit 64; }
    command -v yq >/dev/null || { echo "yq (mikefarah) required" >&2; exit 69; }
    status=0
    for t in "$@"; do
      out="$(check_one "$t")" || status=1
      [[ -n "$out" ]] && { echo "$t"; echo "$out"; }
    done
    [[ $status == 0 ]] && echo "jq helpers: no drift in $# file(s)."
    exit "$status"
    ;;

  sync)
    [[ $# -ge 1 ]] || { echo "usage: jq-helpers.sh sync <transform.yaml>..." >&2; exit 64; }
    command -v yq >/dev/null || { echo "yq (mikefarah) required" >&2; exit 69; }
    changed=0; status=0
    for t in "$@"; do
      q="$tmp/q.jq"; queries "$t" > "$q"
      for n in $names; do
        grep -Eq "^[[:blank:]]*# >>> helper: $n[[:blank:]]*$" "$q" || continue
        diff -q <(canon_flat "$n") <(embedded "$q" "$n") >/dev/null && continue
        if replace_block "$t" "$n"; then echo "updated $n in $t"; changed=$((changed + 1)); else status=1; fi
      done
      out="$(check_one "$t" | grep -v DRIFT || true)"
      [[ -n "$out" ]] && { echo "$t"; echo "$out"; }
    done
    echo "jq helpers: $changed block(s) updated."
    exit "$status"
    ;;

  test)
    command -v jq >/dev/null || { echo "jq required" >&2; exit 69; }
    lib="$tmp/lib.jq"
    if [[ $# -ge 1 ]]; then
      command -v yq >/dev/null || { echo "yq (mikefarah) required" >&2; exit 69; }
      queries "$1" > "$tmp/q.jq"
      : > "$lib"
      for n in $names; do embedded "$tmp/q.jq" "$n" >> "$lib"; done
      [[ -s "$lib" ]] || { echo "no marked helpers in $1" >&2; exit 1; }
      check_one "$1" || true
    else
      for n in $names; do cat "$tmp/canon/$n.jq"; done > "$lib"
    fi
    tested="$(sed -n 's/^# >>> helper: //p' "$lib" | tr '\n' ' ')"
    # Every helper present must have fixtures.
    for n in $tested; do
      jq -e --arg n "$n" 'has($n)' "$fixtures" >/dev/null || { echo "no fixtures for $n in $fixtures" >&2; exit 65; }
    done
    # Dispatcher over the helpers present: "def f($a; $b)" is called as
    # f($x[0]; $x[1]) (fixture input is a two-item array), "def f($x)" as
    # f($x), and a filter "def f:" as ($x | f).
    {
      cat "$lib"
      echo 'def call($h; $x):'
      kw="if"
      for n in $tested; do
        if grep -Eq "^[[:blank:]]*def $n\([^;)]*;" "$lib"; then
          echo "  $kw \$h == \"$n\" then $n(\$x[0]; \$x[1])"
        elif grep -Eq "^[[:blank:]]*def $n\(" "$lib"; then
          echo "  $kw \$h == \"$n\" then $n(\$x)"
        else
          echo "  $kw \$h == \"$n\" then (\$x | $n)"
        fi
        kw="elif"
      done
      echo '  else error("no dispatcher for helper \($h)") end;'
      cat <<'EOF'
to_entries[] | select(.key | IN($tested[])) | .key as $h | .value[]
| . as $c
| (try call($h; $c.in) catch "ERROR: \(.)") as $got
| if $got == $c.want then "ok"
  else "FAIL\t\($h)\t\($c.name)\tinput=\($c.in | tojson)\twant=\($c.want | tojson)\tgot=\($got | tojson)" end
EOF
    } > "$tmp/test.jq"
    tested_json="$(printf '%s\n' $tested | jq -R . | jq -sc .)"
    run() {
      local engine="$1" out total fails
      out="$("$engine" -r --argjson tested "$tested_json" -f "$tmp/test.jq" "$fixtures" 2>&1)" \
        || { echo "$(basename "$engine"): failed to run"; printf '%s\n' "$out" | sed 's/^/  /'; return 1; }
      total="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
      fails="$(printf '%s\n' "$out" | grep -c '^FAIL' || true)"
      printf '%s: %s/%s fixtures pass (%s)\n' "$(basename "$engine")" "$((total - fails))" "$total" "${tested% }"
      printf '%s\n' "$out" | grep '^FAIL' | sed 's/^/  /' || true
      [[ "$fails" == "0" ]]
    }
    status=0
    run "$(command -v jq)" || status=1
    gojq_bin="${GOJQ:-$(command -v gojq || true)}"
    if [[ -n "$gojq_bin" ]]; then
      run "$gojq_bin" || status=1
    else
      echo "gojq: not found (set GOJQ or install github.com/itchyny/gojq to test Monad's jq engine)"
    fi
    exit "$status"
    ;;

  *)
    sed -n '2,24p' "$0" >&2
    exit 64
    ;;
esac

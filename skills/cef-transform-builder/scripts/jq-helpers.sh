#!/usr/bin/env bash
# Manage the standard jq helpers defined in this skill's SKILL.md
# ("Standard jq helpers" section), for example to_epoch_ms, to_iso, is_ip,
# prune (jq-helpers.sh list shows all). SKILL.md is the source of truth.
#
# Transforms match helpers by NAME: any top-level `def` of a helper name must
# have the canonical body (compared after gojq normalization, so layout and
# comments don't matter), and no transform may define a helper name with a
# different number of arguments. The community-transformations repo enforces
# this in CI with its own copy, helpers/helpers.jq, which `export` writes from
# this skill.
#
# Usage:
#   jq-helpers.sh list                 # helper names
#   jq-helpers.sh show <name>...       # print helpers for pasting into a query,
#                                      # dependencies first
#   jq-helpers.sh test                 # run references/jq-helper-fixtures.json under
#                                      # jq, and gojq when on PATH or GOJQ is set
#   jq-helpers.sh export [repo]        # write <repo>/helpers/helpers.jq and
#                                      # helpers/tests.json from this skill
#   jq-helpers.sh check [repo]         # fail if the repo's copies differ from this
#                                      # skill, then run the repo's helper check
#                                      # (every transform matches; tests pass)
#   jq-helpers.sh sync [repo]          # export, then rewrite every drifted helper
#                                      # copy in the repo's transforms
#
# [repo] is a community-transformations checkout; it defaults to $REPO, then to
# the clone managed by community-repo.sh. check and sync run the repo's
# `go -C tools run ./cmd/helpers` tool, so they need Go.
#
# Requires: bash, awk, jq; Go for check and sync.

set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
skill_md="$here/../SKILL.md"
fixtures="$here/../references/jq-helper-fixtures.json"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# --- canonical helpers from SKILL.md -> $tmp/canon/<name>.jq (+ ORDER) ---
# In SKILL.md each helper sits between "# >>> helper: <name>" and
# "# <<< helper: <name>" lines; the markers delimit blocks there only.
mkdir -p "$tmp/canon"
awk -v dir="$tmp/canon" '
  /^# >>> helper: / { name = $4; file = dir "/" name ".jq"; print name >> (dir "/ORDER"); next }
  /^# <<< helper: / { close(file); file = ""; next }
  file != ""        { print > file }
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

# How to call each top-level def of helper $1 with input value $x:
# prints one "<arity> <name>" line per def ("def f($a; $b)" -> 2, "def f($a)" -> 1, "def f:" -> 0).
arities() {
  awk -v n="$1" '
    $0 ~ "^def " n "\\(" { a = $0; sub(/\).*/, "", a); print gsub(/;/, ";", a) + 1; next }
    $0 ~ "^def " n ":"   { print 0 }
  ' "$tmp/canon/$1.jq"
}

repo_dir() {
  local r="${1:-${REPO:-}}"
  [[ -n "$r" ]] || r="$("$here/community-repo.sh" path)"
  [[ -f "$r/helpers/helpers.jq" && -d "$r/tools/cmd/helpers" ]] || {
    echo "not a community-transformations checkout with helper tooling: $r" >&2
    echo "(expected helpers/helpers.jq and tools/cmd/helpers; set REPO or pass the path)" >&2
    exit 66
  }
  (cd "$r" && pwd)
}

# Write helpers.jq and tests.json for the repo into directory $1.
render_repo_files() {
  local out="$1" n first=1
  {
    cat <<'EOF'
# Canonical jq helpers for community transformations.
#
# jq has no shared library mechanism in the Monad jq operation, so each
# transform carries its own copy of the helpers it uses. A transform that
# defines a top-level function with one of the names below must use the
# exact body from this file (compared after gojq normalization, so layout and
# comments don't matter). `go -C tools run ./cmd/helpers sync` rewrites
# drifted copies and `go -C tools run ./cmd/helpers check` fails when a copy
# differs or a transform defines one of these names with a different arity.
#
# Source of truth: the "Standard jq helpers" section of the transform builder
# skills in monad-inc/community (skills/*-transform-builder/SKILL.md). Do not
# edit this file by hand: change the skill, then run its
# `scripts/jq-helpers.sh export <this repo>` to regenerate this file and
# helpers/tests.json, run sync, and review the transform diffs in one PR.
#
# A "# requires: <name>" line in a helper's header names another helper it
# calls; sync inserts the dependency ahead of the helper when a transform
# lacks it.
EOF
    for n in $names; do
      echo
      cat "$tmp/canon/$n.jq"
    done
  } > "$out/helpers.jq"

  # tests.json: one suite per helper def, cases from the skill fixtures.
  {
    for n in $names; do
      for a in $(arities "$n"); do
        case "$a" in
          0) q="$n" ;;
          1) q="$n(.)" ;;
          2) q="$n(.[0]; .[1])" ;;
          *) echo "unsupported arity $a for $n" >&2; exit 65 ;;
        esac
        jq -c --arg n "$n" --arg q "$q" '{query: $q, cases: [.[$n][] | {in, out: .want}]}' "$fixtures"
      done
    done
  } | jq -s . > "$out/tests.json"
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

  export)
    r="$(repo_dir "${1:-}")"
    render_repo_files "$tmp"
    cp "$tmp/helpers.jq" "$r/helpers/helpers.jq"
    cp "$tmp/tests.json" "$r/helpers/tests.json"
    echo "wrote $r/helpers/helpers.jq and $r/helpers/tests.json"
    ;;

  check)
    r="$(repo_dir "${1:-}")"
    command -v go >/dev/null || { echo "go required (the repo's helper tool is Go)" >&2; exit 69; }
    render_repo_files "$tmp"
    status=0
    for f in helpers.jq tests.json; do
      if ! cmp -s "$tmp/$f" "$r/helpers/$f"; then
        echo "$r/helpers/$f differs from this skill (run: jq-helpers.sh export $r)"
        status=1
      fi
    done
    go -C "$r/tools" run ./cmd/helpers check || status=1
    exit "$status"
    ;;

  sync)
    r="$(repo_dir "${1:-}")"
    command -v go >/dev/null || { echo "go required (the repo's helper tool is Go)" >&2; exit 69; }
    "$0" export "$r"
    go -C "$r/tools" run ./cmd/helpers sync
    ;;

  test)
    command -v jq >/dev/null || { echo "jq required" >&2; exit 69; }
    for n in $names; do
      jq -e --arg n "$n" 'has($n)' "$fixtures" >/dev/null || { echo "no fixtures for $n in $fixtures" >&2; exit 65; }
    done
    # Dispatcher: every def of every helper is exercised with that helper's
    # fixtures. Two-argument defs take a two-item array as input.
    {
      for n in $names; do cat "$tmp/canon/$n.jq"; done
      echo 'def call($h; $a; $x):'
      kw="if"
      for n in $names; do
        for a in $(arities "$n"); do
          case "$a" in
            0) e="(\$x | $n)" ;;
            1) e="$n(\$x)" ;;
            2) e="$n(\$x[0]; \$x[1])" ;;
          esac
          echo "  $kw \$h == \"$n\" and \$a == $a then $e"
          kw="elif"
        done
      done
      echo '  else error("no dispatcher for helper \($h)/\($a)") end;'
      echo '$arities[] as [$h, $a] | .[$h][] | . as $c'
      cat <<'EOF'
| (try call($h; $a; $c.in) catch "ERROR: \(.)") as $got
| if $got == $c.want then "ok"
  else "FAIL\t\($h)/\($a)\t\($c.name)\tinput=\($c.in | tojson)\twant=\($c.want | tojson)\tgot=\($got | tojson)" end
EOF
    } > "$tmp/test.jq"
    arities_json="$(for n in $names; do for a in $(arities "$n"); do printf '["%s",%s]\n' "$n" "$a"; done; done | jq -sc .)"
    run() {
      local engine="$1" out total fails
      out="$("$engine" -r --argjson arities "$arities_json" -f "$tmp/test.jq" "$fixtures" 2>&1)" \
        || { echo "$(basename "$engine"): failed to run"; printf '%s\n' "$out" | sed 's/^/  /'; return 1; }
      total="$(printf '%s\n' "$out" | wc -l | tr -d ' ')"
      fails="$(printf '%s\n' "$out" | grep -c '^FAIL' || true)"
      printf '%s: %s/%s fixture runs pass\n' "$(basename "$engine")" "$((total - fails))" "$total"
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
    sed -n '2,31p' "$0" >&2
    exit 64
    ;;
esac

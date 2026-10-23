#!/usr/bin/env bash
# Manage a disposable working clone of the monad-inc/community-transformations
# repository, where the transform builder skills author, validate, and commit
# transforms before opening a pull request.
#
# Subcommands:
#   setup     Clone the repo if not already present (idempotent). Logs progress
#             to stderr; prints the clone path as the final stdout line so
#             callers can `REPO="$(community-repo.sh setup)"`.
#   path      Print the clone path (whether or not it currently exists).
#   status    Report whether the clone exists and whether it has uncommitted
#             changes or unpushed commits.
#   teardown  Remove the clone, but ONLY if it is clean and fully pushed. If it
#             has uncommitted changes or unpushed commits, the directory is
#             PRESERVED and a warning is printed, so no work is lost silently.
#
# Environment overrides:
#   COMMUNITY_TRANSFORMATIONS_DIR     Absolute path for the clone (default:
#                                     ./.community-transformations under the
#                                     current working directory).
#   COMMUNITY_TRANSFORMATIONS_REMOTE  Clone URL (default: the upstream GitHub
#                                     HTTPS URL). Point it at your fork if you
#                                     prefer origin to be the fork.
#   CT_CLONE_DEPTH                    Shallow-clone depth (default 1; set to 0
#                                     for a full-history clone).
#
# Contributors without push access to monad-inc/community-transformations push
# their branch to a fork instead; the teardown safety check counts a branch
# pushed to ANY remote as saved.

set -euo pipefail

REMOTE_URL="${COMMUNITY_TRANSFORMATIONS_REMOTE:-https://github.com/monad-inc/community-transformations.git}"

clone_dir() {
  if [ -n "${COMMUNITY_TRANSFORMATIONS_DIR:-}" ]; then
    printf '%s' "$COMMUNITY_TRANSFORMATIONS_DIR"
  else
    printf '%s/.community-transformations' "$(pwd)"
  fi
}

# True only if the path is a git repo whose origin points at
# community-transformations, so teardown can never touch an unrelated dir.
is_clone() {
  local d="$1"
  [ -d "$d/.git" ] || return 1
  git -C "$d" remote get-url origin 2>/dev/null | grep -q "community-transformations"
}

# Print a report of uncommitted + unpushed work to stderr.
# Returns 0 if the clone is DIRTY, 1 if it is clean and fully pushed.
dirty_report() {
  local d="$1" uncommitted unpushed
  uncommitted="$(git -C "$d" status --porcelain 2>/dev/null || true)"
  # Commits on any local branch not present on any remote-tracking ref.
  unpushed="$(git -C "$d" log --branches --not --remotes --oneline 2>/dev/null || true)"
  if [ -n "$uncommitted" ] || [ -n "$unpushed" ]; then
    {
      echo "  Uncommitted changes:"
      if [ -n "$uncommitted" ]; then echo "$uncommitted" | sed 's/^/    /'; else echo "    (none)"; fi
      echo "  Unpushed commits:"
      if [ -n "$unpushed" ]; then echo "$unpushed" | sed 's/^/    /'; else echo "    (none)"; fi
    } >&2
    return 0
  fi
  return 1
}

cmd_setup() {
  local d; d="$(clone_dir)"
  if is_clone "$d"; then
    echo "community-transformations already cloned at: $d" >&2
    echo "$d"
    return 0
  fi
  if [ -e "$d" ]; then
    echo "Error: $d exists but is not a community-transformations clone; refusing to overwrite it." >&2
    return 1
  fi
  local depth_args=() depth="${CT_CLONE_DEPTH:-1}"
  if [ "$depth" != "0" ]; then
    depth_args=(--depth "$depth")
  fi
  echo "Cloning $REMOTE_URL -> $d ..." >&2
  git clone ${depth_args[@]+"${depth_args[@]}"} "$REMOTE_URL" "$d" >&2
  echo "$d"
}

cmd_status() {
  local d; d="$(clone_dir)"
  if ! is_clone "$d"; then
    echo "No community-transformations clone present (would be at $d)."
    return 0
  fi
  echo "Clone present at: $d"
  if dirty_report "$d"; then
    echo "State: DIRTY (uncommitted changes or unpushed commits, see above)."
  else
    echo "State: clean and fully pushed."
  fi
}

cmd_teardown() {
  local d; d="$(clone_dir)"
  if ! is_clone "$d"; then
    [ -e "$d" ] && echo "teardown: $d is not a community-transformations clone; leaving it untouched." >&2
    exit 0
  fi
  if dirty_report "$d"; then
    echo "WARNING: community-transformations clone at $d has unsaved work (listed above)." >&2
    echo "    Preserving the directory to avoid data loss. Commit/push it, then remove manually:" >&2
    echo "      rm -rf \"$d\"" >&2
    exit 0
  fi
  rm -rf "$d"
  echo "Removed clean community-transformations clone at $d" >&2
  exit 0
}

case "${1:-}" in
  setup|ensure)   cmd_setup ;;
  path)           clone_dir; echo ;;
  status)         cmd_status ;;
  teardown|clean) cmd_teardown ;;
  *)
    echo "Usage: $(basename "$0") {setup|path|status|teardown}" >&2
    exit 2
    ;;
esac

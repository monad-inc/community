#!/usr/bin/env bash
# Print the Monad onboarding questionnaire as Markdown, generated from
# references/questions.yaml, so answers can be collected ahead of time and then
# written into an intake document (templates/intake.example.yaml).
#
# Usage: questionnaire.sh [questions.yaml]   (default: the skill's own file)
# Needs: bash, yq (mikefarah, v4).
set -euo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
questions="${1:-$here/../references/questions.yaml}"

command -v yq >/dev/null 2>&1 || { echo "questionnaire.sh: needs yq (mikefarah, v4) on PATH" >&2; exit 2; }
[ -f "$questions" ] || { echo "questionnaire.sh: no such file: $questions" >&2; exit 2; }

phase_title() {
  case "$1" in
    1) echo "Environment" ;;
    2) echo "Destinations" ;;
    3) echo "Data model" ;;
    4) echo "Data sources" ;;
    5) echo "Pipeline layout and add-ons" ;;
    *) echo "Other" ;;
  esac
}

echo "# Monad onboarding questionnaire"
echo
echo "Answer what you can; anything left blank will be asked during setup."
echo "Never include passwords, tokens, or keys: those are set later in the Monad UI."

last=""
count="$(yq '.questions | length' "$questions")"
i=0
while [ "$i" -lt "$count" ]; do
  q=".questions[$i]"
  phase="$(yq "$q.phase" "$questions")"
  if [ "$phase" != "$last" ]; then
    echo
    echo "## $(phase_title "$phase")"
    last="$phase"
  fi
  prompt="$(yq "$q.prompt" "$questions")"
  required="$(yq "$q.required // false" "$questions")"
  ask_when="$(yq "$q.ask_when // \"\"" "$questions")"
  options="$(yq "($q.options // []) | join(\" / \")" "$questions")"
  maps_to="$(yq "$q.maps_to" "$questions")"

  marker=""
  [ "$required" = "true" ] && marker=" *(required)*"
  echo
  echo "**$((i + 1)). $prompt**$marker"
  [ -n "$ask_when" ] && echo "<br>Only if: $ask_when."
  [ -n "$options" ] && echo "<br>Options: $options"
  echo "<br>Intake field: \`$maps_to\`"
  echo
  echo "> Answer:"
  i=$((i + 1))
done

#!/usr/bin/env bash
#
# monad-org-export.sh — export a Monad organization's resources as Terraform,
# then migrate them to another instance or commit them to Git for backup.
#
# This is a curl + jq port of monad-org-export.py, for environments that prefer
# a shell tool over Python. It produces the same Terraform module and supports
# the same workflows:
#
#   SaaS  -> SaaS     export from one app.monad.com org, apply to another
#   SaaS  -> on-prem  export from app.monad.com, apply to a self-hosted instance
#   on-prem -> SaaS   export from a self-hosted instance, apply to app.monad.com
#   either -> Git     export, then push the module to GitHub/GitLab for backup
#
# "SaaS vs on-prem" is only a different --base-url; the three connection settings
# (base URL, API token, org id) are all that change between any source/target.
#
# Requirements: bash 3.2+, curl, jq, and (for `apply`) terraform 1.5+, (for
# `push`) git. The Monad API token is read from the environment, never argv.

set -euo pipefail

PROVIDER_SOURCE="monad-inc/monad"
DEFAULT_BASE_URL="https://app.monad.com"

usage() {
  cat >&2 <<'EOF'
monad-org-export.sh — export a Monad org to Terraform; migrate it or back it up.

USAGE
  monad-org-export.sh <command> [options]

COMMANDS
  export   read a SOURCE org and write a Terraform module to a directory
  apply    run `terraform apply` against a TARGET org using that module
  push     commit the module to a Git remote (backup / version control)

export OPTIONS
  --org-id <id>        source organization id (or $MONAD_ORGANIZATION_ID)   [required]
  --out <dir>          output directory for the generated module            [required]
  --base-url <url>     source instance base URL (default https://app.monad.com)
  --token-file <path>  file holding the source API token (else $MONAD_API_TOKEN)
  --emit-imports       also write imports.tf (Terraform 1.5+ `import {}` blocks)
                       to ADOPT the source org's existing resources in place
  --customer-only      skip resources whose managed_by is not 'customer'
  --insecure           skip TLS verification (self-signed on-prem only)

apply OPTIONS
  --dir <dir>             exported module directory                         [required]
  --target-base-url <url> target instance base URL
  --target-org-id <id>    target organization id
  --token-file <path>     file holding the target API token
                          (else $MONAD_TARGET_API_TOKEN / $MONAD_API_TOKEN)
  --auto-approve          pass -auto-approve to terraform

push OPTIONS
  --dir <dir>          exported module directory                           [required]
  --remote <url>       git remote URL (GitHub/GitLab); omit for local-only commit
  --branch <name>      branch name (default main)
  -m, --message <msg>  commit message (default "Monad org export")
  --no-push            commit but do not push

AUTHENTICATION
  The API token is read from $MONAD_API_TOKEN (export) /
  $MONAD_TARGET_API_TOKEN (apply) or --token-file, never from the command line,
  to keep it out of the process list. It is sent as `Authorization: ApiKey ...`.

EXAMPLES
  export MONAD_API_TOKEN=...
  monad-org-export.sh export --org-id <SRC_ORG> --out ./org-tf
  monad-org-export.sh export --base-url https://monad.corp.internal \
      --org-id <SRC_ORG> --out ./org-tf --emit-imports
  MONAD_TARGET_API_TOKEN=... monad-org-export.sh apply --dir ./org-tf \
      --target-base-url https://app.monad.com --target-org-id <DST_ORG>
  monad-org-export.sh push --dir ./org-tf \
      --remote git@github.com:acme/monad-org-backup.git -m 'nightly backup'
EOF
}

die() { echo "error: $*" >&2; exit 1; }
need_value() { [ -n "${2:-}" ] || die "option $1 requires a value (see --help)"; }

# ---------------------------------------------------------------------------
# Shared jq definitions, prepended to every generation program.
# ---------------------------------------------------------------------------
read -r -d '' JQ_DEFS <<'JQ' || true
# HCL string literal: JSON-quote (close enough to HCL), then neutralize
# Terraform interpolation sequences so literal data is inert.
def hclstr: @json | gsub("\\$\\{"; "$${") | gsub("%\\{"; "%%{");

# Normalize a resource name into a valid, lowercase Terraform local name.
def sanitize:
  (. // "") | ascii_downcase | gsub("[^a-z0-9_]+"; "_")
  | sub("^_+"; "") | sub("_+$"; "")
  | (if . == "" then "resource" else . end)
  | (if test("^[0-9]") then "r_" + . else . end);

# Build {used,byid} from an ordered [{type,name,id}] list, assigning unique
# local names (base, base_2, base_3, ...) globally across all resource types.
def buildmap:
  reduce .[] as $r ({used: {}, byid: {}};
    ($r.name | sanitize) as $base
    | ((.used[$base] // 0) + 1) as $n
    | (if $n == 1 then $base else "\($base)_\($n)" end) as $local
    | .used[$base] = $n
    | .byid[$r.id] = {type: $r.type, local: $local, addr: "\($r.type).\($local)", name: $r.name}
  );
JQ

# ---------------------------------------------------------------------------
# API client
# ---------------------------------------------------------------------------

api_get() { # path -> JSON on stdout
  local path="$1"
  # Header is passed via --config (process substitution) so the token never
  # appears in argv / the process list. printf is a bash builtin, not a process.
  curl -fsS ${INSECURE:+-k} \
    --config <(printf 'header = "Authorization: ApiKey %s"\n' "$TOKEN") \
    "$BASE/api$path"
}

list_all() { # version segment envelope_key outfile
  local ver="$1" seg="$2" key="$3" out="$4"
  local offset=0 limit=100 total cnt resp
  : > "$out.jsonl"
  while :; do
    resp="$(api_get "/$ver/$ORG/$seg?limit=$limit&offset=$offset")"
    printf '%s' "$resp" | jq -c ".${key}[]?" >> "$out.jsonl"
    total="$(printf '%s' "$resp" | jq -r '.pagination.total // 0')"
    cnt="$(printf '%s' "$resp" | jq -r ".${key} | length // 0")"
    offset=$((offset + limit))
    { [ "$offset" -ge "$total" ] || [ "$cnt" -eq 0 ]; } && break
  done
  jq -s '.' "$out.jsonl" > "$out"
  rm -f "$out.jsonl"
}

# ---------------------------------------------------------------------------
# export
# ---------------------------------------------------------------------------

cmd_export() {
  local out="" emit_imports="" customer_only=""
  BASE="$DEFAULT_BASE_URL"; ORG="${MONAD_ORGANIZATION_ID:-}"; INSECURE=""
  local token_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --org-id) need_value "$1" "${2:-}"; ORG="$2"; shift 2;;
      --org-id=*) ORG="${1#*=}"; shift;;
      --out) need_value "$1" "${2:-}"; out="$2"; shift 2;;
      --out=*) out="${1#*=}"; shift;;
      --base-url) need_value "$1" "${2:-}"; BASE="$2"; shift 2;;
      --base-url=*) BASE="${1#*=}"; shift;;
      --token-file) need_value "$1" "${2:-}"; token_file="$2"; shift 2;;
      --token-file=*) token_file="${1#*=}"; shift;;
      --emit-imports) emit_imports=1; shift;;
      --customer-only) customer_only=1; shift;;
      --insecure) INSECURE=1; shift;;
      -h|--help) usage; exit 0;;
      *) die "unknown option for export: $1 (see --help)";;
    esac
  done
  [ -n "$ORG" ] || die "--org-id is required (or set MONAD_ORGANIZATION_ID)"
  [ -n "$out" ] || die "--out is required"
  resolve_token "$token_file" "MONAD_API_TOKEN"
  command -v jq >/dev/null || die "jq is required"
  command -v curl >/dev/null || die "curl is required"

  mkdir -p "$out"
  WORKDIR="$(mktemp -d)"; trap 'rm -rf "$WORKDIR"' EXIT

  echo "Fetching resources from $BASE (org $ORG) ..." >&2
  list_all v1 inputs      inputs      "$WORKDIR/inputs.json"
  list_all v1 outputs     outputs     "$WORKDIR/outputs.json"
  list_all v1 transforms  transforms  "$WORKDIR/transforms.json"
  list_all v3 enrichments enrichments "$WORKDIR/enrichments.json"
  list_all v2 secrets     secrets     "$WORKDIR/secrets.json"
  list_all v2 pipelines   pipelines   "$WORKDIR/pipelines_list.json"

  # Full pipeline objects (nodes/edges only come back on the per-id GET).
  : > "$WORKDIR/pipelines_full.jsonl"
  while IFS= read -r pid; do
    [ -n "$pid" ] || continue
    api_get "/v2/$ORG/pipelines/$pid" | jq -c '.data // .' >> "$WORKDIR/pipelines_full.jsonl"
  done < <(jq -r '.[].id' "$WORKDIR/pipelines_list.json")
  jq -s '.' "$WORKDIR/pipelines_full.jsonl" > "$WORKDIR/pipelines.json"

  # Optionally drop non-customer-managed resources.
  if [ -n "$customer_only" ]; then
    local f
    for f in inputs outputs transforms enrichments pipelines; do
      jq '[.[] | select((.managed_by // "customer") == "customer")]' \
        "$WORKDIR/$f.json" > "$WORKDIR/$f.filt" && mv "$WORKDIR/$f.filt" "$WORKDIR/$f.json"
    done
  fi

  # ---- id -> Terraform address map (drives references + names everywhere)
  jq -n --slurpfile s "$WORKDIR/secrets.json" --slurpfile i "$WORKDIR/inputs.json" \
        --slurpfile o "$WORKDIR/outputs.json" --slurpfile t "$WORKDIR/transforms.json" \
        --slurpfile e "$WORKDIR/enrichments.json" --slurpfile p "$WORKDIR/pipelines.json" \
    "$JQ_DEFS"'
      ( ($s[0] | map({type:"monad_secret",    name:.name, id:.id}))
      + ($i[0] | map({type:"monad_input",     name:.name, id:.id}))
      + ($o[0] | map({type:"monad_output",    name:.name, id:.id}))
      + ($t[0] | map({type:"monad_transform", name:.name, id:.id}))
      + ($e[0] | map({type:"monad_enrichment",name:.name, id:.id}))
      + ($p[0] | map({type:"monad_pipeline",  name:.name, id:.id}))
      ) | buildmap
    ' > "$WORKDIR/map.json"

  gen_component "$WORKDIR/inputs.json"      monad_input      "$WORKDIR/map.json" "$out/inputs.tf"
  gen_component "$WORKDIR/outputs.json"     monad_output     "$WORKDIR/map.json" "$out/outputs.tf"
  gen_component "$WORKDIR/enrichments.json" monad_enrichment "$WORKDIR/map.json" "$out/enrichments.tf"
  gen_transforms "$WORKDIR/transforms.json" "$WORKDIR/map.json" "$out/transforms.tf"
  gen_secrets   "$WORKDIR/map.json" "$out/secrets.tf"
  gen_pipelines "$WORKDIR/pipelines.json" "$WORKDIR/map.json" "$out/pipelines.tf"
  gen_scaffold  "$WORKDIR/map.json" "$out" "$emit_imports"

  # Warn about pipeline nodes referencing components we did not export.
  jq -r --slurpfile m "$WORKDIR/map.json" '
    ($m[0]) as $MAP
    | .[] | .name as $pn | (.nodes // [])[]
    | select(.component_id != null and ($MAP.byid[.component_id] | not))
    | "warning: pipeline \($pn): node \(.slug) references unexported component "
      + "\(.component_id); emitting literal id (will not resolve elsewhere)."
  ' "$WORKDIR/pipelines.json" >&2 || true

  echo "Exported to $out/" >&2
  local seg
  printf '  %-11s %s\n' "secrets:"  "$(jq 'length' "$WORKDIR/secrets.json")"  >&2
  for seg in inputs outputs transforms enrichments pipelines; do
    printf '  %-11s %s\n' "$seg:" "$(jq 'length' "$WORKDIR/$seg.json")" >&2
  done
}

gen_component() { # items tf_type map outfile
  jq -r --arg TYPE "$2" --slurpfile m "$3" "$JQ_DEFS"'
    ($m[0]) as $MAP
    | .[] | ($MAP.byid[.id]) as $meta
    | "resource \"\($TYPE)\" \"\($meta.local)\" {\n"
      + "  name        = \(.name | hclstr)\n"
      + (if (.description // "") != "" then "  description = \(.description | hclstr)\n" else "" end)
      + "  type        = \((.type // "") | hclstr)\n"
      + ( (.config.settings // {}) as $s | (.config.secrets // {}) as $sec
          | if (($s | length) > 0) or (($sec | length) > 0) then
              "  config {\n"
              + (if ($s   | length) > 0 then "    settings = jsondecode(\(($s   | tojson) | hclstr))\n" else "" end)
              + (if ($sec | length) > 0 then "    secrets  = jsondecode(\(($sec | tojson) | hclstr))\n" else "" end)
              + "  }\n"
            else "" end )
      + "}\n"
  ' "$1" > "$4"
  [ -s "$4" ] || rm -f "$4"
}

gen_transforms() { # items map outfile
  jq -r --slurpfile m "$2" "$JQ_DEFS"'
    ($m[0]) as $MAP
    | .[] | ($MAP.byid[.id]) as $meta
    | "resource \"monad_transform\" \"\($meta.local)\" {\n"
      + "  name        = \(.name | hclstr)\n"
      + (if (.description // "") != "" then "  description = \(.description | hclstr)\n" else "" end)
      + "  config = jsondecode(\(((.config // {}) | tojson) | hclstr))\n"
      + "}\n"
  ' "$1" > "$3"
  [ -s "$3" ] || rm -f "$3"
}

gen_secrets() { # map outfile
  jq -r "$JQ_DEFS"'
    .byid | to_entries
    | map(select(.value.type == "monad_secret"))
    | .[] | .value
    | "resource \"monad_secret\" \"\(.local)\" {\n"
      + "  name  = \(.name | hclstr)\n"
      + "  value = var.secret_\(.local)\n"
      + "}\n"
  ' "$1" > "$2"
  [ -s "$2" ] || rm -f "$2"
}

gen_pipelines() { # items map outfile
  jq -r --slurpfile m "$2" "$JQ_DEFS"'
    ($m[0]) as $MAP
    | .[] | ($MAP.byid[.id]) as $meta
    | (reduce (.nodes[]?) as $n ({}; .[$n.id] = $n.slug)) as $slug
    | "resource \"monad_pipeline\" \"\($meta.local)\" {\n"
      + "  name        = \(.name | hclstr)\n"
      + (if (.description // "") != "" then "  description = \(.description | hclstr)\n" else "" end)
      + "  enabled     = \(.enabled // true)\n"
      + ( [ .nodes[]? | ($MAP.byid[.component_id]) as $cm
          | "  nodes {\n"
            + "    slug           = \(.slug | hclstr)\n"
            + "    component_type = \((.component_type // "") | hclstr)\n"
            + "    component_id   = " + (if $cm then "\($cm.addr).id" else (.component_id | hclstr) end) + "\n"
            + "  }\n"
        ] | join("") )
      + ( [ .edges[]? | (.conditions // {}) as $c
          | "  edges {\n"
            + (if (.name // "") != ""        then "    name                    = \(.name | hclstr)\n" else "" end)
            + (if (.description // "") != "" then "    description             = \(.description | hclstr)\n" else "" end)
            + "    from_node_instance_slug = \(($slug[.from_node_instance_id] // "") | hclstr)\n"
            + "    to_node_instance_slug   = \(($slug[.to_node_instance_id] // "") | hclstr)\n"
            + "    condition {\n"
            + "      operator = \(($c.operator // "always") | hclstr)\n"
            + ( [ ($c.conditions // [])[] | (.config // {}) as $cfg
                | "      conditions {\n"
                  + (if (.type_id // "") != "" then "        type_id = \(.type_id | hclstr)\n" else "" end)
                  + ( [ (if ($cfg.key // "") != "" then "          key   = \($cfg.key | hclstr)" else empty end),
                        (if ($cfg.value != null and $cfg.value != "" and $cfg.value != [])
                          then "          value = [" + (($cfg.value | if type == "array" then . else [.] end)
                                 | map(tostring | hclstr) | join(", ")) + "]"
                          else empty end),
                        (if ($cfg.rate // "") != "" then "          rate  = \($cfg.rate | hclstr)" else empty end)
                      ] as $cl
                      | if ($cl | length) > 0 then "        config {\n" + ($cl | join("\n")) + "\n        }\n" else "" end )
                  + "      }\n"
              ] | join("") )
            + "    }\n"
            + "  }\n"
        ] | join("") )
      + "}\n"
  ' "$1" > "$3"
  [ -s "$3" ] || rm -f "$3"
}

gen_scaffold() { # map outdir emit_imports
  local map="$1" outdir="$2" emit="$3"

  cat > "$outdir/versions.tf" <<EOF
terraform {
  required_version = ">= 1.5"
  required_providers {
    monad = {
      source = "$PROVIDER_SOURCE"
    }
  }
}
EOF

  cat > "$outdir/provider.tf" <<'EOF'
provider "monad" {
  base_url        = var.monad_base_url
  api_token       = var.monad_api_token
  organization_id = var.monad_organization_id
}
EOF

  {
    cat <<EOF
variable "monad_base_url" {
  type    = string
  default = "$DEFAULT_BASE_URL"
}

variable "monad_api_token" {
  type      = string
  sensitive = true
}

variable "monad_organization_id" {
  type = string
}
EOF
    jq -r '
      .byid | to_entries | map(select(.value.type == "monad_secret")) | .[] | .value
      | "\nvariable \"secret_\(.local)\" {\n  description = \"Value for secret: \(.name)\"\n  type        = string\n  sensitive   = true\n}"
    ' "$map"
  } > "$outdir/variables.tf"

  {
    cat <<EOF
# Target connection — fill in the instance you are applying TO.
monad_base_url        = "$DEFAULT_BASE_URL"   # self-hosted: https://monad.your-domain
monad_api_token       = "REPLACE_ME"
monad_organization_id = "REPLACE_ME"
EOF
    if [ "$(jq '[.byid[] | select(.type=="monad_secret")] | length' "$map")" -gt 0 ]; then
      echo
      echo "# Secret values are NOT exported (Monad never returns them). Supply each:"
      jq -r '.byid | to_entries | map(select(.value.type=="monad_secret")) | .[] | .value
        | "secret_\(.local) = \"REPLACE_ME\"  # \(.name)"' "$map"
    fi
  } > "$outdir/terraform.tfvars.example"

  jq --arg org "$ORG" --arg base "$BASE" '
    {organization_id: $org, source_base_url: $base,
     resources: (.byid | map_values({address: .addr, name: .name, type: .type}))}
  ' "$map" > "$outdir/MANIFEST.json"

  if [ -n "$emit" ]; then
    {
      cat <<'EOF'
# Generated by monad-org-export.sh --emit-imports.
# Adopts the source org's existing resources into Terraform state.
# Requires Terraform >= 1.5. Delete this file after the first apply.
# NOTE: secret VALUES are still not readable, so an imported
# monad_secret may show a value diff until you supply it via tfvars.

EOF
      jq -r '.byid | to_entries[]
        | "import {\n  to = \(.value.addr)\n  id = \"\(.key)\"\n}"' "$map"
    } > "$outdir/imports.tf"
  fi

  write_readme "$outdir"
  write_notes "$map" "$outdir"
}

write_notes() { # map outdir
  {
    echo "# Export notes"
    echo
    echo "Source org: \`$ORG\`"
    echo "Source URL: \`$BASE\`"
    echo
    echo "## Resource counts"
    echo
    jq -r '[.byid[]] | group_by(.type) | .[] | "- \(.[0].type): \(length)"' "$1"
    echo
    echo "## Secrets"
    echo
    echo "Secret **values are never returned by the Monad API**, so this export"
    echo "contains secret *definitions* only. Before \`apply\`, set each"
    echo "\`secret_*\` variable in \`terraform.tfvars\` (or via \`TF_VAR_secret_*\`)."
    echo
    echo "Secret *references* embedded in a connector's \`config.secrets\` are"
    echo "emitted verbatim by this shell version; if you migrate to a different"
    echo "instance, remap them to \`monad_secret.<name>.reference\` by hand."
  } > "$2/EXPORT_NOTES.md"
}

write_readme() { # outdir
  cat > "$1/README.md" <<'EOF'
# Monad organization export (Terraform)

Generated by `monad-org-export.sh`. A portable snapshot of a Monad organization:
inputs, outputs, transforms, enrichments, secrets (definitions only), pipelines.

## Apply to a target instance

```sh
cp terraform.tfvars.example terraform.tfvars   # then edit it
terraform init
terraform plan
terraform apply
```

Connection settings (`monad_base_url`, `monad_api_token`,
`monad_organization_id`) select the target. `https://app.monad.com` is the SaaS
default; point `monad_base_url` at your own hostname for a self-hosted instance.

## Secrets

Secret values are not exported (the API never returns them). Set each
`secret_*` variable before applying — see `EXPORT_NOTES.md`.
EOF
}

# ---------------------------------------------------------------------------
# apply
# ---------------------------------------------------------------------------

cmd_apply() {
  local dir="" tbase="" torg="" auto="" token_file=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) need_value "$1" "${2:-}"; dir="$2"; shift 2;;
      --dir=*) dir="${1#*=}"; shift;;
      --target-base-url) need_value "$1" "${2:-}"; tbase="$2"; shift 2;;
      --target-base-url=*) tbase="${1#*=}"; shift;;
      --target-org-id) need_value "$1" "${2:-}"; torg="$2"; shift 2;;
      --target-org-id=*) torg="${1#*=}"; shift;;
      --token-file) need_value "$1" "${2:-}"; token_file="$2"; shift 2;;
      --token-file=*) token_file="${1#*=}"; shift;;
      --auto-approve) auto="-auto-approve"; shift;;
      -h|--help) usage; exit 0;;
      *) die "unknown option for apply: $1 (see --help)";;
    esac
  done
  [ -n "$dir" ] || die "--dir is required"
  [ -f "$dir/versions.tf" ] || die "$dir does not look like an exported module (no versions.tf)"
  command -v terraform >/dev/null || die "terraform 1.5+ is required for apply"

  [ -n "$tbase" ] && export TF_VAR_monad_base_url="$tbase"
  [ -n "$torg" ] && export TF_VAR_monad_organization_id="$torg"
  if [ -n "$token_file" ]; then
    TF_VAR_monad_api_token="$(cat "$token_file")"; export TF_VAR_monad_api_token
  elif [ -n "${MONAD_TARGET_API_TOKEN:-}" ]; then
    export TF_VAR_monad_api_token="$MONAD_TARGET_API_TOKEN"
  elif [ -n "${MONAD_API_TOKEN:-}" ]; then
    export TF_VAR_monad_api_token="$MONAD_API_TOKEN"
  fi

  ( cd "$dir" && terraform init -input=false && terraform apply -input=false $auto )
}

# ---------------------------------------------------------------------------
# push (Git backup / version control)
# ---------------------------------------------------------------------------

cmd_push() {
  local dir="" remote="" branch="main" message="Monad org export" no_push=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir) need_value "$1" "${2:-}"; dir="$2"; shift 2;;
      --dir=*) dir="${1#*=}"; shift;;
      --remote) need_value "$1" "${2:-}"; remote="$2"; shift 2;;
      --remote=*) remote="${1#*=}"; shift;;
      --branch) need_value "$1" "${2:-}"; branch="$2"; shift 2;;
      --branch=*) branch="${1#*=}"; shift;;
      -m|--message) need_value "$1" "${2:-}"; message="$2"; shift 2;;
      --message=*) message="${1#*=}"; shift;;
      --no-push) no_push=1; shift;;
      -h|--help) usage; exit 0;;
      *) die "unknown option for push: $1 (see --help)";;
    esac
  done
  [ -n "$dir" ] || die "--dir is required"
  [ -d "$dir" ] || die "$dir does not exist"
  command -v git >/dev/null || die "git is required for push"

  cat > "$dir/.gitignore" <<'EOF'
*.tfstate
*.tfstate.*
.terraform/
.terraform.lock.hcl
terraform.tfvars
*.auto.tfvars
EOF

  if [ ! -d "$dir/.git" ]; then
    git -C "$dir" init -b "$branch" >/dev/null 2>&1 || git -C "$dir" init >/dev/null
  fi
  git -C "$dir" checkout -B "$branch" >/dev/null 2>&1 || true
  if [ -n "$remote" ]; then
    if git -C "$dir" remote | grep -qx origin; then
      git -C "$dir" remote set-url origin "$remote"
    else
      git -C "$dir" remote add origin "$remote"
    fi
  fi
  git -C "$dir" add -A
  if git -C "$dir" diff --cached --quiet; then
    echo "Nothing to commit (working tree matches last backup)." >&2
  else
    git -C "$dir" commit -m "$message" >/dev/null
  fi
  if [ -n "$remote" ] && [ -z "$no_push" ]; then
    git -C "$dir" push -u origin "$branch"
  fi
}

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

resolve_token() { # token_file env_name  -> sets global TOKEN
  local tf="$1" env_name="$2"
  if [ -n "$tf" ]; then
    [ -f "$tf" ] || die "token file not found: $tf"
    TOKEN="$(cat "$tf")"
  else
    eval "TOKEN=\"\${$env_name:-\${MONAD_API_TOKEN:-}}\""
  fi
  [ -n "${TOKEN:-}" ] || die "API token required: set \$$env_name or pass --token-file. \
(Tokens are read from env/file, never argv, to keep them out of 'ps'.)"
}

main() {
  [ $# -ge 1 ] || { usage; exit 1; }
  local cmd="$1"; shift
  case "$cmd" in
    export) cmd_export "$@";;
    apply)  cmd_apply "$@";;
    push)   cmd_push "$@";;
    -h|--help) usage; exit 0;;
    *) echo "error: unknown command '$cmd' (expected export, apply, or push)" >&2; usage; exit 1;;
  esac
}

main "$@"

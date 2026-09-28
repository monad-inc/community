# monad-org-export

## Purpose

Export an entire Monad **organization** to a self-contained Terraform module,
then either migrate it to another instance or commit it to Git for backup and
version control, and **verify** afterwards that everything arrived.

Two interchangeable implementations are provided — pick whichever fits your
environment; they produce the same Terraform module and support the same
commands:

- **`monad-org-export.py`** — Python 3, standard library only (no `pip install`).
- **`monad-org-export.sh`** — Bash, using `curl` + `jq`.

Monad's [Terraform provider](https://registry.terraform.io/providers/monad-inc/monad/latest)
can manage every resource type in an org, but it has **no data sources** — so on
its own it cannot discover "everything in my org." This tool closes that gap: it
reads every resource over the Monad REST API and writes a Terraform module
(`inputs.tf`, `outputs.tf`, `transforms.tf`, `enrichments.tf`, `secrets.tf`,
`pipelines.tf`, `alert_rules.tf`, plus provider/variable scaffolding). That
single module is the artifact behind every workflow below.

The same module works in all directions, because **"SaaS vs. self-hosted" is
only a different base URL** — the three connection settings (base URL, API
token, organization id) are the *only* things that change between any source and
target:

| Scenario | How |
|---|---|
| SaaS → SaaS | `export` from one org, `apply` to another, `verify` |
| SaaS → self-hosted | `export` from `app.monad.com`, `apply` with `--target-base-url https://monad.your-domain` |
| self-hosted → SaaS | `export` with `--base-url https://monad.your-domain`, `apply` to `app.monad.com` |
| either → Git backup | `export`, then `push` to a GitHub/GitLab remote |

**Monad API surface (all read-only):** `GET /v1/{org}/inputs`, `GET /v1/{org}/outputs`,
`GET /v1/{org}/transforms`, `GET /v3/{org}/enrichments`, `GET /v2/{org}/secrets`,
`GET /v2/{org}/pipelines` + `GET /v2/{org}/pipelines/{id}`,
`GET /v3/{org}/alert_rules`, `GET /v1|v3/{org}/<kind>/{id}` for any component a
pipeline references that the list endpoints did not return, and the type catalogs
`GET /v1/inputs` + `GET /v1/outputs` (to compare each connector's version with the
latest). The `apply` and
`push` subcommands shell out to `terraform` and `git` respectively; `verify`
reads the target with the same list endpoints and, when run inside an applied
module, `terraform state list`.

## Requirements

- **Python version (`monad-org-export.py`):** `python` 3.8+, standard library
  only — no third-party packages.
- **Bash version (`monad-org-export.sh`):** `bash` 3.2+ (macOS default), plus
  [`curl`](https://curl.se/) and [`jq`](https://jqlang.github.io/jq/) **1.6+**.
- Both: [`terraform`](https://developer.hashicorp.com/terraform) **1.11+** is
  needed for `apply`, because the module's secret values are write-only
  arguments; `git` is needed for `push`. Neither is needed for `export` itself (if `terraform` is present,
  `export` runs `terraform fmt` on the output).
- The generated module pins the provider to **`monad-inc/monad ~> 0.5.0`** (0.5.x
  patches only; the provider is pre-1.0 and ships breaking changes as minor
  bumps). The HCL it emits (scalar edge `value`, `values` lists,
  `monad_alert_rule`, structured `{ id = ... }` secret references, edge
  `schema_detection_spec`) does not load on older releases.
- Platform notes: macOS/Linux.

Examples below use the Python entrypoint; substitute `./monad-org-export.sh` for
the Bash version — the subcommands, flags, and output are identical.

## Authentication

Supply the Monad API token via environment variable (never on the command line,
so it stays out of the process list):

- `export` reads `MONAD_API_TOKEN` (or `--token-file <path>`).
- `apply` and `verify` read `MONAD_TARGET_API_TOKEN` (falling back to
  `MONAD_API_TOKEN`); `apply` passes it to Terraform as `TF_VAR_monad_api_token`.

The token must belong to the relevant organization: `export` needs **read**
access to inputs/outputs/transforms/enrichments/secrets/pipelines/alert rules;
`apply` needs **write** access on the target org; `verify` needs read on the
target. The token is sent as `Authorization: ApiKey <token>` (matching the
official Terraform provider).

## Usage

```bash
# 1) Export a SaaS org to ./org-tf, with every pipeline disabled on arrival
export MONAD_API_TOKEN=...
./monad-org-export.py export --org-id <SRC_ORG_ID> --out ./org-tf --pipelines-disabled

# 1b) …or export from a self-hosted instance
./monad-org-export.py export --base-url https://monad.your-domain \
    --org-id <SRC_ORG_ID> --out ./org-tf

# 2) Fill in secret values, then migrate into another org (SaaS or self-hosted)
cp org-tf/terraform.tfvars.example org-tf/terraform.tfvars   # set each secret_*
MONAD_TARGET_API_TOKEN=... ./monad-org-export.py apply --dir ./org-tf \
    --target-base-url https://app.monad.com --target-org-id <DST_ORG_ID>

# 3) Confirm everything landed
MONAD_TARGET_API_TOKEN=... ./monad-org-export.py verify --dir ./org-tf \
    --target-base-url https://app.monad.com --target-org-id <DST_ORG_ID>

# 4) Back up to a Git repo
./monad-org-export.py push --dir ./org-tf \
    --remote git@github.com:acme/monad-org-backup.git -m "nightly backup"
```

### `export` flags

| Flag | Required | Description |
|------|----------|-------------|
| `--out` | yes | Output directory for the generated module |
| `--org-id` | yes | Source organization id (or `$MONAD_ORGANIZATION_ID`) |
| `--base-url` | no | Source instance base URL (default `https://app.monad.com`) |
| `--token-file` | no | File containing the source API token (alternative to `$MONAD_API_TOKEN`) |
| `--pipelines-disabled` | no | Emit every pipeline with `enabled = false` so nothing runs on the target until its secret values are in place. **Recommended for migrations**; omit for a faithful backup |
| `--emit-imports` | no | Also write `imports.tf` with `import {}` blocks to **adopt** the source org's existing resources into Terraform state in place (Terraform 1.5+) instead of creating new ones |
| `--customer-only` | no | Skip resources whose `managed_by` is not `customer` (system/auto-provisioned) |
| `--insecure` | no | Skip TLS verification (self-signed self-hosted only; not recommended) |

`export` is read-only. `apply` is the only state-changing step — run
`terraform plan` in the module directory, or `apply` without `--auto-approve`, to
preview before committing.

### `apply` flags

| Flag | Required | Description |
|------|----------|-------------|
| `--dir` | yes | Exported module directory |
| `--target-base-url` | no | Target instance base URL |
| `--target-org-id` | no | Target organization id |
| `--token-file` | no | File containing the target API token |
| `--parallelism` | no | Terraform `-parallelism` (default **1**; see *Pipeline creation is slow* below) |
| `--auto-approve` | no | Pass `-auto-approve` to Terraform |

### `verify` flags

| Flag | Required | Description |
|------|----------|-------------|
| `--dir` | yes | Exported module directory (reads `MANIFEST.json`, and Terraform state if present) |
| `--target-org-id` | yes | Target organization id |
| `--target-base-url` | no | Target instance base URL (default `https://app.monad.com`) |
| `--token-file` | no | File containing the target API token |
| `--write-imports` | no | Write `imports-recover.tf` for resources that exist on the target but are missing from Terraform state |
| `--insecure` | no | Skip TLS verification |

`verify` prints one row per resource kind — exported / on target / missing — and
exits `2` if anything is missing. It matches by **name**.

### Adopting an existing org in place (`--emit-imports`)

When the target **is** the org you exported from (e.g. you want to bring an
existing org under Terraform management without recreating anything), export with
`--emit-imports`. Terraform reads each resource by id and reconciles state
instead of planning a create. **Delete `imports.tf` after the first successful
apply** — import blocks are one-time.

### Recovering from a partial apply

If `apply` is interrupted (the run is killed, or a create on a resource type
other than `monad_pipeline` times out), resources the API finished creating can
exist on the target but not in Terraform state — and a plain re-run would try to
create them again. Pipelines are covered by the provider itself: it adopts a
pipeline whose create outlived its timeout. For everything else, run:

```bash
./monad-org-export.py verify --dir ./org-tf --target-org-id <DST_ORG_ID> --write-imports
./monad-org-export.py apply  --dir ./org-tf --target-org-id <DST_ORG_ID>
rm org-tf/imports-recover.tf
```

The first command lists the orphans and writes `import {}` blocks for them; the
second adopts them and creates whatever is still missing; then `verify` again.

## Inputs / outputs

- **Input:** a reachable Monad instance + an org-scoped API token.
- **Output / effects:** a Terraform module directory containing one `.tf` file
  per resource type, `terraform.tfvars.example` (target connection + secret value
  stubs), `MANIFEST.json` (source-id → Terraform-address map), `EXPORT_NOTES.md`
  (counts, caveats, and any warnings), and a generated `README.md`. `push` adds a
  `.gitignore` that keeps state and `terraform.tfvars` out of the backup repo.

## Limitations & caveats

- **Secret values are never exported.** The Monad API does not return secret
  values, so the module contains secret *definitions* only: each becomes a
  `monad_secret` whose `value` is a sensitive Terraform variable, with a stub in
  `terraform.tfvars.example`. You must supply each value before `apply`.
- **Secret references are rewritten, unresolvable ones are flagged.** Connector
  `config.secrets` slots (`{ "id": "<secret id>" }`) and secret ids embedded in
  transform operations (`mask`, `encrypt`) are rewritten to the recreated
  `monad_secret.<name>.id`. A reference to a secret this export did not see
  (deleted, or owned by another org) is emitted literally and listed in
  `EXPORT_NOTES.md`; it will not resolve on a different instance.
- **The API creates pipelines one request at a time.** At Terraform's default
  parallelism the later pipeline creates queue behind the earlier ones. The
  provider gives each call 5 minutes (`request_timeout`) and, when a pipeline
  create outlives that budget but finishes on the server, adopts it into state
  instead of leaving a duplicate for the next run. `apply` still defaults to
  `-parallelism=1`, which avoids the queue; if you run `terraform apply`
  yourself, pass it explicitly. If a run is interrupted anyway, see
  *Recovering from a partial apply*.
- **Schema drift detection settings are carried, the learned schema is not.**
  Edges with detection on are emitted with a `schema_detection_spec` block
  (`enabled`, and `disable_alerting` where set). On a different org or instance
  each of those edges starts learning again (about 48 hours) before it can
  raise drift alerts. `EXPORT_NOTES.md` counts them.
- **Disabled edges are created enabled** (no `disabled` attribute in the
  provider); **nested logical conditions** (a logical operator inside another)
  are dropped with a warning — the provider models one logical layer over leaf
  rules. Both are reported in `EXPORT_NOTES.md`.
- **Connector versions are not pinned.** The provider has no `version` attribute,
  so a create on the target gets each connector type's **latest** version. A
  source component pinned below the latest version (checked against the source
  instance's type catalog) is flagged, because settings written for the older
  version may be rejected by the newer one. Adopting the same org in place with
  `--emit-imports` keeps every pinned version, so nothing is flagged there.
- **System-managed alert rules are skipped** (`Schema Drift Detection`,
  `Pipeline Throttled`): every org already has them. Customer-managed rules are
  exported with their `pipeline_ids` rewritten to the recreated pipelines.
- **Cosmetic plan diffs on complex transforms.** After a successful apply the
  provider re-serializes jq-heavy transform configs, so a few `monad_transform`
  resources can show a permanent `will be updated in-place` on `config` with no
  real change. Applying it is harmless.
- **`verify` matches by name.** Two same-named resources of one kind on the
  target satisfy a single exported entry; renamed resources show as missing.
- **`--emit-imports` requires the resource ids to exist on the target.** It is
  for adopting the *same* org in place, not for cross-instance migration (a
  different instance has different ids). Imported `monad_secret` and connector
  resources show a one-time `value_hash` / `secrets_hash` diff until applied.
- **API-key permissions:** `export` and `verify` require read on all listed
  endpoints; `apply` requires write on the target org.
- **Idempotency:** `export` overwrites the output directory's `.tf` files on each
  run. `push` commits only when something changed and (unless `--no-push`) pushes
  to `origin`.
- **What it does NOT do:** it does not copy ingested data, KV store contents, or
  pipeline run history; it does not manage users, roles, API keys, or billing. It
  captures the resource types the Terraform provider supports (inputs, outputs,
  transforms, enrichments, secrets, pipelines, alert rules).
- **Throughput:** list endpoints are paginated 100 at a time and pipelines are
  fetched individually, so very large orgs make correspondingly many GET calls.

## Safety

- `export` and `verify` are strictly read-only against Monad. The only
  state-changing path is `apply`; preview it with `terraform plan` (or omit
  `--auto-approve`) first.
- Credentials are read from environment variables or `--token-file`, never from
  argv, and are never written into the generated module.
- `push` writes a `.gitignore` excluding `*.tfstate*`, `.terraform/`,
  `terraform.tfvars`, and `*.auto.tfvars`, so state and secret values are not
  committed to the backup repo.

## Related

- [Monad Terraform provider](https://registry.terraform.io/providers/monad-inc/monad/latest/docs)
- [Terraform import blocks](https://developer.hashicorp.com/terraform/language/import)
- [Monad documentation](https://app.monad.com/docs)

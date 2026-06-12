# monad-org-export

## Purpose

Export an entire Monad **organization** to a self-contained Terraform module,
then either migrate it to another instance or commit it to Git for backup and
version control.

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
`pipelines.tf`, plus provider/variable scaffolding). That single module is the
artifact behind every workflow below.

The same module works in all directions, because **"SaaS vs. self-hosted" is
only a different base URL** — the three connection settings (base URL, API
token, organization id) are the *only* things that change between any source and
target:

| Scenario | How |
|---|---|
| SaaS → SaaS | `export` from one org, `apply` to another |
| SaaS → self-hosted | `export` from `app.monad.com`, `apply` with `--target-base-url https://monad.your-domain` |
| self-hosted → SaaS | `export` with `--base-url https://monad.your-domain`, `apply` to `app.monad.com` |
| either → Git backup | `export`, then `push` to a GitHub/GitLab remote |

**Monad API surface:** `GET /v1/{org}/inputs`, `GET /v1/{org}/outputs`,
`GET /v1/{org}/transforms`, `GET /v3/{org}/enrichments`, `GET /v2/{org}/secrets`,
`GET /v2/{org}/pipelines` + `GET /v2/{org}/pipelines/{id}` (all read-only). The
`apply` and `push` subcommands shell out to `terraform` and `git` respectively.

## Requirements

- **Python version (`monad-org-export.py`):** `python` 3.8+, standard library
  only — no third-party packages.
- **Bash version (`monad-org-export.sh`):** `bash` 3.2+ (macOS default), plus
  [`curl`](https://curl.se/) and [`jq`](https://jqlang.github.io/jq/).
- Both: [`terraform`](https://developer.hashicorp.com/terraform) **1.5+** is
  needed for `apply` (and required by `--emit-imports`); `git` is needed for
  `push`. Neither is needed for `export` itself.
- Platform notes: macOS/Linux.

Examples below use the Python entrypoint; substitute `./monad-org-export.sh` for
the Bash version — the subcommands, flags, and output are identical.

## Authentication

Supply the Monad API token via environment variable (never on the command line,
so it stays out of the process list):

- `export` reads `MONAD_API_TOKEN` (or `--token-file <path>`).
- `apply` reads `MONAD_TARGET_API_TOKEN` (falls back to `MONAD_API_TOKEN`), which
  it passes to Terraform as `TF_VAR_monad_api_token`.

The token must belong to the relevant organization: `export` needs **read**
access to inputs/outputs/transforms/enrichments/secrets/pipelines; `apply` needs
**write** access on the target org. The token is sent as
`Authorization: ApiKey <token>` (matching the official Terraform provider).

## Usage

```bash
# 1) Export a SaaS org to ./org-tf
export MONAD_API_TOKEN=...
./monad-org-export.py export --org-id <SRC_ORG_ID> --out ./org-tf

# 1b) …or export from a self-hosted instance
./monad-org-export.py export --base-url https://monad.your-domain \
    --org-id <SRC_ORG_ID> --out ./org-tf

# 2) Migrate into another org (SaaS or self-hosted — just change the URL)
MONAD_TARGET_API_TOKEN=... ./monad-org-export.py apply --dir ./org-tf \
    --target-base-url https://app.monad.com --target-org-id <DST_ORG_ID>

# 3) Back up to a Git repo
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
| `--emit-imports` | no | Also write `imports.tf` with `import {}` blocks to **adopt** the source org's existing resources into Terraform state in place (Terraform 1.5+) instead of creating new ones |
| `--customer-only` | no | Skip resources whose `managed_by` is not `customer` (system/auto-provisioned) |
| `--insecure` | no | Skip TLS verification (self-signed self-hosted only; not recommended) |

`export` is read-only. `apply` is the only state-changing step — run
`terraform plan` in the module directory, or `apply` without `--auto-approve`, to
preview before committing.

### Adopting an existing org in place (`--emit-imports`)

When the target **is** the org you exported from (e.g. you want to bring an
existing org under Terraform management without recreating anything), export with
`--emit-imports`. Terraform reads each resource by id and reconciles state
instead of planning a create. **Delete `imports.tf` after the first successful
apply** — import blocks are one-time.

## Inputs / outputs

- **Input:** a reachable Monad instance + an org-scoped API token.
- **Output / effects:** a Terraform module directory containing one `.tf` file
  per resource type, `terraform.tfvars.example` (target connection + secret value
  stubs), `MANIFEST.json` (source-id → Terraform-address map), `EXPORT_NOTES.md`
  (counts and any warnings), and a generated `README.md`. `push` adds a
  `.gitignore` that keeps state and `terraform.tfvars` out of the backup repo.

## Limitations & caveats

- **Secret values are never exported.** The Monad API does not return secret
  values, so the module contains secret *definitions* only: each becomes a
  `monad_secret` whose `value` is a sensitive Terraform variable, with a stub in
  `terraform.tfvars.example`. You must supply each value before `apply`.
- **Secret references inside connector config.** The Python version remaps them
  best-effort: where a connector's `config.secrets` value contains a known
  exported secret id, it is rewritten to `monad_secret.<name>.reference`
  (unrecognized references are emitted literally and flagged in
  `EXPORT_NOTES.md`). The Bash version emits `config.secrets` verbatim; if you
  migrate to a different instance, remap those references to
  `monad_secret.<name>.reference` by hand.
- **`--emit-imports` requires the resource ids to exist on the target.** It is
  for adopting the *same* org in place, not for cross-instance migration (a
  different instance has different ids). Imported `monad_secret` resources may
  show a value diff until you supply the value via tfvars.
- **API-key permissions:** `export` requires read on all listed endpoints;
  `apply` requires write on the target org.
- **Idempotency:** `export` overwrites the output directory's `.tf` files on each
  run. `push` commits only when something changed and (unless `--no-push`) pushes
  to `origin`.
- **What it does NOT do:** it does not copy ingested data or pipeline run
  history; it does not manage users, roles, API keys, or billing. It captures the
  resource types the Terraform provider supports (inputs, outputs, transforms,
  enrichments, secrets, pipelines).
- **Throughput:** list endpoints are paginated 100 at a time and pipelines are
  fetched individually, so very large orgs make correspondingly many GET calls.

## Safety

- `export` is strictly read-only against Monad. The only state-changing path is
  `apply`; preview it with `terraform plan` (or omit `--auto-approve`) first.
- Credentials are read from environment variables or `--token-file`, never from
  argv, and are never written into the generated module.
- `push` writes a `.gitignore` excluding `*.tfstate*`, `.terraform/`,
  `terraform.tfvars`, and `*.auto.tfvars`, so state and secret values are not
  committed to the backup repo.

## Related

- [Monad Terraform provider](https://registry.terraform.io/providers/monad-inc/monad/latest/docs)
- [Terraform import blocks](https://developer.hashicorp.com/terraform/language/import)
- [Monad documentation](https://app.monad.com/docs)

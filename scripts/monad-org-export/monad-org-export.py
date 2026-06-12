#!/usr/bin/env python3
"""
monad-org-export — export a Monad organization's resources as Terraform, then
migrate them to another instance or commit them to a Git repo for backup.

A Monad organization is fully manageable through the Terraform provider
(monad-inc/monad), but the provider has no data sources, so it cannot discover
"everything in my org" on its own. This tool fills that gap: it reads every
resource from a SOURCE instance over the REST API and writes a self-contained
Terraform module. That single module then serves every direction of travel:

  - SaaS  -> SaaS     export from one app.monad.com org, apply to another
  - SaaS  -> on-prem  export from app.monad.com, apply to a self-hosted instance
  - on-prem -> SaaS   export from a self-hosted instance, apply to app.monad.com
  - either -> Git     export, then push the module to GitHub/GitLab for backup

"SaaS vs on-prem" is nothing more than a different --base-url; the three
connection settings (base URL, API token, org id) are all that change between
any source and any target.

Subcommands:
  export   read SOURCE org -> write a Terraform module to a directory
  apply    run `terraform apply` against a TARGET org using that module
  push     commit the module to a Git remote (backup / version control)

Run `monad-org-export.py <subcommand> --help` for details.
"""

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
from pathlib import Path

PROVIDER_SOURCE = "monad-inc/monad"
DEFAULT_BASE_URL = "https://app.monad.com"

# REST paths per resource type. Monad serves a deliberate mix of API versions
# (verified against the live API): inputs/outputs/transforms on v1, secrets and
# pipelines on v2, enrichments on v3. Each entry: (api_version, path_segment,
# list_envelope_key, terraform_resource_type).
# Kinds whose HCL shape is `type = ...` + a `config { settings {} secrets {} }`
# block. Transforms are NOT here — their schema has no `type` and a single
# required dynamic `config = {...}` attribute, so they are rendered separately.
RESOURCE_KINDS = [
    ("v1", "inputs", "inputs", "monad_input"),
    ("v1", "outputs", "outputs", "monad_output"),
    ("v3", "enrichments", "enrichments", "monad_enrichment"),
]

# ---------------------------------------------------------------------------
# API client
# ---------------------------------------------------------------------------


class MonadAPIError(Exception):
    pass


class Client:
    """Minimal Monad REST client. Auth header is `Authorization: ApiKey <tok>`
    (NOT Bearer) — this matches the official Terraform provider's transport."""

    def __init__(self, base_url, token, org_id, insecure=False):
        self.base = base_url.rstrip("/") + "/api"
        self.token = token
        self.org = org_id
        self._ctx = None
        if insecure:
            import ssl

            self._ctx = ssl.create_default_context()
            self._ctx.check_hostname = False
            self._ctx.verify_mode = ssl.CERT_NONE

    def _get(self, path):
        url = self.base + path
        req = urllib.request.Request(url, headers={"Authorization": "ApiKey " + self.token})
        try:
            with urllib.request.urlopen(req, context=self._ctx) as resp:
                return json.load(resp)
        except urllib.error.HTTPError as e:
            body = e.read().decode("utf-8", "replace")
            raise MonadAPIError(f"GET {path} -> HTTP {e.code}: {body[:300]}") from None
        except urllib.error.URLError as e:
            raise MonadAPIError(f"GET {path} -> {e.reason}") from None

    def list(self, version, segment, envelope_key):
        """Paginate a list endpoint. Envelope is {"<key>": [...], "pagination":
        {"total","limit","offset"}}."""
        out, offset, limit = [], 0, 100
        while True:
            d = self._get(f"/{version}/{self.org}/{segment}?limit={limit}&offset={offset}")
            if isinstance(d, list):  # defensive: bare array
                out.extend(d)
                break
            items = d.get(envelope_key) or _first_list(d)
            out.extend(items)
            pg = d.get("pagination") or {}
            total = pg.get("total")
            offset += limit
            if total is None or offset >= total or not items:
                break
        return out

    def get(self, version, segment, rid):
        d = self._get(f"/{version}/{self.org}/{segment}/{rid}")
        return d.get("data", d) if isinstance(d, dict) else d


def _first_list(d):
    for v in d.values():
        if isinstance(v, list):
            return v
    return []


# ---------------------------------------------------------------------------
# HCL generation
# ---------------------------------------------------------------------------

_IDENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_-]*$")


def hcl_string(s):
    s = s.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")
    # Escape Terraform interpolation so literal ${...} / %{...} in data is inert.
    s = s.replace("${", "$${").replace("%{", "%%{")
    return f'"{s}"'


class Raw(str):
    """A value emitted verbatim (no quoting) — used for Terraform references."""


def hcl_value(v, indent):
    pad = "  " * indent
    pad1 = "  " * (indent + 1)
    if isinstance(v, Raw):
        return str(v)
    if isinstance(v, bool):
        return "true" if v else "false"
    if v is None:
        return "null"
    if isinstance(v, (int, float)):
        return json.dumps(v)
    if isinstance(v, str):
        return hcl_string(v)
    if isinstance(v, list):
        if not v:
            return "[]"
        items = [pad1 + hcl_value(x, indent + 1) for x in v]
        return "[\n" + ",\n".join(items) + "\n" + pad + "]"
    if isinstance(v, dict):
        if not v:
            return "{}"
        lines = []
        for k, val in v.items():
            key = k if _IDENT_RE.match(str(k)) else hcl_string(str(k))
            lines.append(f"{pad1}{key} = {hcl_value(val, indent + 1)}")
        return "{\n" + "\n".join(lines) + "\n" + pad + "}"
    return hcl_string(str(v))


def sanitize_name(name, used):
    """Turn a resource name into a unique, valid Terraform local name."""
    base = re.sub(r"[^a-z0-9_]+", "_", (name or "").lower()).strip("_") or "resource"
    if base[0].isdigit():
        base = "r_" + base
    candidate, n = base, 1
    while candidate in used:
        n += 1
        candidate = f"{base}_{n}"
    used.add(candidate)
    return candidate


# ---------------------------------------------------------------------------
# Export
# ---------------------------------------------------------------------------


def build_config_block(config, secret_ref_map, warnings, ctx_label):
    """Render a `config { settings {...} secrets {...} }` block body from the
    API config object. settings/secrets are dynamic maps, so native HCL objects
    reproduce them faithfully. Secret references are remapped where recognized."""
    if not config:
        return None
    settings = config.get("settings") or {}
    secrets = config.get("secrets") or {}
    lines = []
    if settings:
        lines.append(f"    settings = {hcl_value(settings, 2)}")
    if secrets:
        remapped = _remap_secret_refs(secrets, secret_ref_map, warnings, ctx_label)
        lines.append(f"    secrets = {hcl_value(remapped, 2)}")
    if not lines:
        return None
    return "  config {\n" + "\n".join(lines) + "\n  }"


def _remap_secret_refs(secrets, secret_ref_map, warnings, ctx_label):
    """config.secrets values embed an org-specific secret id/reference. Where a
    value contains a known source secret id, rewrite it to a Terraform reference
    so it resolves against the recreated secret on the target."""
    out = {}
    for slot, val in secrets.items():
        if isinstance(val, str):
            for sid, addr in secret_ref_map.items():
                if sid and sid in val:
                    out[slot] = Raw(f"{addr}.reference")
                    break
            else:
                out[slot] = val
                if val:
                    warnings.append(
                        f"{ctx_label}: secret slot '{slot}' could not be matched to an "
                        f"exported secret; its value is emitted literally and may need "
                        f"manual remapping on the target."
                    )
        else:
            out[slot] = val
    return out


def export(args):
    token = resolve_token(args, "MONAD_API_TOKEN")
    if not args.org_id:
        die("--org-id is required (or set MONAD_ORGANIZATION_ID)")
    client = Client(args.base_url, token, args.org_id, insecure=args.insecure)
    outdir = Path(args.out)
    outdir.mkdir(parents=True, exist_ok=True)

    warnings = []
    id_to_addr = {}       # component id -> "monad_input.foo"
    secret_ref_map = {}   # secret id    -> "monad_secret.bar"
    manifest = {"organization_id": args.org_id, "source_base_url": args.base_url, "resources": {}}

    # ---- secrets first (their addresses are referenced by component configs)
    print("Fetching secrets ...", file=sys.stderr)
    secrets = client.list("v2", "secrets", "secrets")
    used_names = set()
    secret_blocks, secret_vars, secret_tfvars = [], [], []
    for s in secrets:
        local = sanitize_name(s.get("name"), used_names)
        addr = f"monad_secret.{local}"
        secret_ref_map[s["id"]] = addr
        manifest["resources"][s["id"]] = {"address": addr, "name": s.get("name"), "type": "secret"}
        var = f"secret_{local}"
        block = [f'resource "monad_secret" "{local}" {{']
        block.append(f"  name  = {hcl_string(s.get('name') or local)}")
        block.append(f"  value = var.{var}")
        block.append("}")
        secret_blocks.append("\n".join(block))
        secret_vars.append(
            f'variable "{var}" {{\n'
            f'  description = {hcl_string("Value for secret: " + (s.get("name") or local))}\n'
            f"  type        = string\n  sensitive   = true\n}}"
        )
        secret_tfvars.append(f'{var} = "REPLACE_ME"  # {s.get("name")}')

    # ---- component resources (inputs/outputs/transforms/enrichments)
    component_blocks = {tf: [] for _, _, _, tf in RESOURCE_KINDS}
    for version, segment, env_key, tf_type in RESOURCE_KINDS:
        print(f"Fetching {segment} ...", file=sys.stderr)
        try:
            items = client.list(version, segment, env_key)
        except MonadAPIError as e:
            warnings.append(f"Could not list {segment}: {e}")
            continue
        for it in items:
            if args.customer_only and it.get("managed_by") not in (None, "customer"):
                continue
            local = sanitize_name(it.get("name"), used_names)
            addr = f"{tf_type}.{local}"
            id_to_addr[it["id"]] = addr
            manifest["resources"][it["id"]] = {
                "address": addr, "name": it.get("name"), "type": tf_type,
                "connector_type": it.get("type"),
            }
            block = [f'resource "{tf_type}" "{local}" {{']
            block.append(f"  name        = {hcl_string(it.get('name') or local)}")
            if it.get("description"):
                block.append(f"  description = {hcl_string(it['description'])}")
            block.append(f"  type        = {hcl_string(it.get('type') or '')}")
            cfg = build_config_block(it.get("config"), secret_ref_map, warnings, addr)
            if cfg:
                block.append(cfg)
            block.append("}")
            component_blocks[tf_type].append("\n".join(block))

    # ---- transforms (distinct schema: required dynamic `config`, no `type`)
    print("Fetching transforms ...", file=sys.stderr)
    transform_blocks = []
    try:
        transforms = client.list("v1", "transforms", "transforms")
    except MonadAPIError as e:
        warnings.append(f"Could not list transforms: {e}")
        transforms = []
    for it in transforms:
        if args.customer_only and it.get("managed_by") not in (None, "customer"):
            continue
        local = sanitize_name(it.get("name"), used_names)
        addr = f"monad_transform.{local}"
        id_to_addr[it["id"]] = addr
        manifest["resources"][it["id"]] = {"address": addr, "name": it.get("name"), "type": "monad_transform"}
        block = [f'resource "monad_transform" "{local}" {{']
        block.append(f"  name        = {hcl_string(it.get('name') or local)}")
        if it.get("description"):
            block.append(f"  description = {hcl_string(it['description'])}")
        block.append(f"  config = {hcl_value(it.get('config') or {}, 1)}")
        block.append("}")
        transform_blocks.append("\n".join(block))

    # ---- pipelines (need per-pipeline GET for nodes/edges)
    print("Fetching pipelines ...", file=sys.stderr)
    pipeline_blocks = []
    pipelines = client.list("v2", "pipelines", "pipelines")
    for p in pipelines:
        full = client.get("v2", "pipelines", p["id"])
        block = render_pipeline(full, id_to_addr, used_names, warnings, manifest)
        if block:
            pipeline_blocks.append(block)

    write_module(
        outdir, args, secret_blocks, secret_vars, secret_tfvars,
        component_blocks, transform_blocks, pipeline_blocks, manifest, warnings,
    )

    print(f"\nExported to {outdir}/", file=sys.stderr)
    print(f"  secrets:    {len(secret_blocks)}", file=sys.stderr)
    for _, seg, _, tf in RESOURCE_KINDS:
        print(f"  {seg:10} {len(component_blocks[tf])}", file=sys.stderr)
    print(f"  transforms: {len(transform_blocks)}", file=sys.stderr)
    print(f"  pipelines:  {len(pipeline_blocks)}", file=sys.stderr)
    if warnings:
        print(f"\n{len(warnings)} warning(s) — see {outdir}/EXPORT_NOTES.md", file=sys.stderr)


def render_pipeline(p, id_to_addr, used_names, warnings, manifest):
    name = p.get("name") or "pipeline"
    local = sanitize_name(name, used_names)
    manifest["resources"][p.get("id")] = {"address": f"monad_pipeline.{local}", "name": name, "type": "pipeline"}
    nodes = p.get("nodes") or []
    edges = p.get("edges") or []

    # node instance id -> slug (edges in the API reference node ids; the
    # provider wires edges by slug, so we translate).
    nodeid_to_slug = {n.get("id"): n.get("slug") for n in nodes if n.get("id")}

    lines = [f'resource "monad_pipeline" "{local}" {{']
    lines.append(f"  name        = {hcl_string(name)}")
    if p.get("description"):
        lines.append(f"  description = {hcl_string(p['description'])}")
    lines.append(f"  enabled     = {'true' if p.get('enabled', True) else 'false'}")

    for n in nodes:
        cid = n.get("component_id")
        ref = id_to_addr.get(cid)
        comp_id = Raw(f"{ref}.id") if ref else cid
        if not ref and cid:
            warnings.append(
                f"pipeline '{name}': node '{n.get('slug')}' references component "
                f"{cid} that was not exported; emitting the literal id. It will not "
                f"resolve on a different instance."
            )
        lines.append("  nodes {")
        lines.append(f"    slug           = {hcl_string(n.get('slug') or '')}")
        lines.append(f"    component_type = {hcl_string(n.get('component_type') or '')}")
        lines.append(f"    component_id   = {comp_id if isinstance(comp_id, Raw) else hcl_string(comp_id or '')}")
        lines.append("  }")

    for e in edges:
        frm = nodeid_to_slug.get(e.get("from_node_instance_id"), "")
        to = nodeid_to_slug.get(e.get("to_node_instance_id"), "")
        cond = e.get("conditions") or {}
        lines.append("  edges {")
        if e.get("name"):
            lines.append(f"    name                    = {hcl_string(e['name'])}")
        if e.get("description"):
            lines.append(f"    description             = {hcl_string(e['description'])}")
        lines.append(f"    from_node_instance_slug = {hcl_string(frm)}")
        lines.append(f"    to_node_instance_slug   = {hcl_string(to)}")
        lines.append("    condition {")
        lines.append(f"      operator = {hcl_string(cond.get('operator') or 'always')}")
        for c in cond.get("conditions") or []:
            cc = c.get("config") or {}
            lines.append("      conditions {")
            if c.get("type_id"):
                lines.append(f"        type_id = {hcl_string(c['type_id'])}")
            cfg_lines = []
            if cc.get("key"):
                cfg_lines.append(f"          key   = {hcl_string(str(cc['key']))}")
            if cc.get("value") not in (None, "", []):
                # provider expects a list of strings; coerce scalars/elements.
                raw = cc["value"]
                vals = raw if isinstance(raw, list) else [raw]
                vals = [str(v) for v in vals]
                cfg_lines.append(f"          value = {hcl_value(vals, 5)}")
            if cc.get("rate"):
                cfg_lines.append(f"          rate  = {hcl_string(str(cc['rate']))}")
            if cfg_lines:
                lines.append("        config {")
                lines.extend(cfg_lines)
                lines.append("        }")
            lines.append("      }")
        lines.append("    }")
        lines.append("  }")

    lines.append("}")
    return "\n".join(lines)


def write_module(outdir, args, secret_blocks, secret_vars, secret_tfvars,
                 component_blocks, transform_blocks, pipeline_blocks, manifest, warnings):
    def w(fn, content):
        (outdir / fn).write_text(content.rstrip() + "\n")

    w("versions.tf", (
        "terraform {\n"
        '  required_version = ">= 1.5"\n'
        "  required_providers {\n"
        "    monad = {\n"
        f'      source = "{PROVIDER_SOURCE}"\n'
        "    }\n  }\n}\n"
    ))
    w("provider.tf", (
        'provider "monad" {\n'
        "  base_url        = var.monad_base_url\n"
        "  api_token       = var.monad_api_token\n"
        "  organization_id = var.monad_organization_id\n"
        "}\n"
    ))
    conn_vars = (
        'variable "monad_base_url" {\n  type    = string\n'
        f'  default = "{DEFAULT_BASE_URL}"\n}}\n\n'
        'variable "monad_api_token" {\n  type      = string\n  sensitive = true\n}\n\n'
        'variable "monad_organization_id" {\n  type = string\n}\n'
    )
    w("variables.tf", conn_vars + ("\n\n" + "\n\n".join(secret_vars) if secret_vars else ""))
    if secret_blocks:
        w("secrets.tf", "\n\n".join(secret_blocks))
    for _, seg, _, tf in RESOURCE_KINDS:
        if component_blocks[tf]:
            w(f"{seg}.tf", "\n\n".join(component_blocks[tf]))
    if transform_blocks:
        w("transforms.tf", "\n\n".join(transform_blocks))
    if pipeline_blocks:
        w("pipelines.tf", "\n\n".join(pipeline_blocks))

    if getattr(args, "emit_imports", False):
        # `import {}` blocks adopt EXISTING resources (matched by their source
        # ids) into Terraform state — use these when applying against the SAME
        # org you exported from, so `apply` reconciles instead of duplicating.
        # Remove imports.tf after the first successful apply.
        blocks = [
            "# Generated by monad-org-export --emit-imports.",
            "# Adopts the source org's existing resources into Terraform state.",
            "# Requires Terraform >= 1.5. Delete this file after the first apply.",
            "# NOTE: secret VALUES are still not readable, so an imported",
            "# monad_secret may show a value diff until you supply it via tfvars.",
            "",
        ]
        for rid, meta in manifest["resources"].items():
            blocks.append(f'import {{\n  to = {meta["address"]}\n  id = {hcl_string(rid)}\n}}')
        w("imports.tf", "\n".join(blocks))

    tfvars = [
        "# Target connection — fill in the instance you are applying TO.",
        f'monad_base_url        = "{DEFAULT_BASE_URL}"   # self-hosted: https://monad.your-domain',
        'monad_api_token       = "REPLACE_ME"',
        'monad_organization_id = "REPLACE_ME"',
    ]
    if secret_tfvars:
        tfvars += ["", "# Secret values are NOT exported (Monad never returns them). Supply each:"]
        tfvars += secret_tfvars
    w("terraform.tfvars.example", "\n".join(tfvars))

    w("MANIFEST.json", json.dumps(manifest, indent=2))
    w("EXPORT_NOTES.md", render_notes(warnings, manifest))
    w("README.md", render_readme())


def render_notes(warnings, manifest):
    counts = {}
    for r in manifest["resources"].values():
        counts[r["type"]] = counts.get(r["type"], 0) + 1
    lines = ["# Export notes\n", f"Source org: `{manifest['organization_id']}`",
             f"Source URL: `{manifest['source_base_url']}`\n", "## Resource counts\n"]
    for t, c in sorted(counts.items()):
        lines.append(f"- {t}: {c}")
    lines.append("\n## Secrets\n")
    lines.append("Secret **values are never returned by the Monad API**, so this export "
                 "contains secret *definitions* only. Before `apply`, set each "
                 "`secret_*` variable in `terraform.tfvars` (or via `TF_VAR_secret_*`).")
    if warnings:
        lines.append("\n## Warnings\n")
        for wn in warnings:
            lines.append(f"- {wn}")
    return "\n".join(lines)


def render_readme():
    return (
        "# Monad organization export (Terraform)\n\n"
        "Generated by `monad-org-export.py`. This module is a faithful, portable\n"
        "snapshot of a Monad organization: inputs, outputs, transforms, enrichments,\n"
        "secrets (definitions only), and pipelines.\n\n"
        "## Apply to a target instance\n\n"
        "```sh\n"
        "cp terraform.tfvars.example terraform.tfvars   # then edit it\n"
        "terraform init\n"
        "terraform plan\n"
        "terraform apply\n"
        "```\n\n"
        "Connection settings (`monad_base_url`, `monad_api_token`,\n"
        "`monad_organization_id`) select the target. `https://app.monad.com` is the\n"
        "SaaS default; point `monad_base_url` at your own hostname for a self-hosted\n"
        "instance. Nothing else differs between SaaS and on-prem.\n\n"
        "## Secrets\n\n"
        "Secret values are not exported (the API never returns them). Set each\n"
        "`secret_*` variable before applying — see `EXPORT_NOTES.md`.\n\n"
        "## Files\n\n"
        "- `versions.tf` / `provider.tf` / `variables.tf` — provider + inputs\n"
        "- `inputs.tf` `outputs.tf` `transforms.tf` `enrichments.tf` `secrets.tf` `pipelines.tf`\n"
        "- `MANIFEST.json` — source id -> Terraform address map\n"
        "- `EXPORT_NOTES.md` — counts, caveats, and any export warnings\n"
    )


# ---------------------------------------------------------------------------
# apply
# ---------------------------------------------------------------------------


def apply(args):
    d = Path(args.dir)
    if not (d / "versions.tf").exists():
        die(f"{d} does not look like an exported module (no versions.tf)")
    env = dict(os.environ)
    if args.target_base_url:
        env["TF_VAR_monad_base_url"] = args.target_base_url
    if args.target_org_id:
        env["TF_VAR_monad_organization_id"] = args.target_org_id
    token = resolve_token(args, "MONAD_TARGET_API_TOKEN", required=False)
    if token:
        env["TF_VAR_monad_api_token"] = token
    run(["terraform", "init", "-input=false"], cwd=d, env=env)
    cmd = ["terraform", "apply", "-input=false"]
    if args.auto_approve:
        cmd.append("-auto-approve")
    run(cmd, cwd=d, env=env)


# ---------------------------------------------------------------------------
# push (Git backup / version control)
# ---------------------------------------------------------------------------


def push(args):
    d = Path(args.dir)
    if not d.exists():
        die(f"{d} does not exist")
    # A .gitignore so state/secrets never get committed to the backup repo.
    (d / ".gitignore").write_text(
        "*.tfstate\n*.tfstate.*\n.terraform/\n.terraform.lock.hcl\n"
        "terraform.tfvars\n*.auto.tfvars\n"
    )
    if not (d / ".git").exists():
        run(["git", "init", "-b", args.branch], cwd=d)
    else:
        # ensure we are on the requested branch
        run(["git", "checkout", "-B", args.branch], cwd=d)
    if args.remote:
        existing = subprocess.run(["git", "remote"], cwd=d, capture_output=True, text=True).stdout.split()
        if "origin" in existing:
            run(["git", "remote", "set-url", "origin", args.remote], cwd=d)
        else:
            run(["git", "remote", "add", "origin", args.remote], cwd=d)
    run(["git", "add", "-A"], cwd=d)
    # Commit only if there is something staged.
    if subprocess.run(["git", "diff", "--cached", "--quiet"], cwd=d).returncode != 0:
        run(["git", "commit", "-m", args.message], cwd=d)
    else:
        print("Nothing to commit (working tree matches last backup).", file=sys.stderr)
    if args.remote and not args.no_push:
        run(["git", "push", "-u", "origin", args.branch], cwd=d)


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------


def resolve_token(args, env_name, required=True):
    if getattr(args, "token_file", None):
        tok = Path(args.token_file).read_text().strip()
    else:
        tok = os.environ.get(env_name) or os.environ.get("MONAD_API_TOKEN")
    if not tok and required:
        die(f"API token required: set ${env_name} or pass --token-file. "
            f"(Tokens are read from env/file, never argv, to keep them out of `ps`.)")
    return tok


def run(cmd, cwd=None, env=None):
    print("+ " + " ".join(cmd), file=sys.stderr)
    r = subprocess.run(cmd, cwd=cwd, env=env)
    if r.returncode != 0:
        die(f"command failed ({r.returncode}): {' '.join(cmd)}")


def die(msg):
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


def build_parser():
    p = argparse.ArgumentParser(
        prog="monad-org-export.py",
        description="Export a Monad organization to Terraform; migrate it to another "
                    "instance or back it up to Git.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "examples:\n"
            "  # Export a SaaS org to ./org-tf\n"
            "  export MONAD_API_TOKEN=...\n"
            "  monad-org-export.py export --org-id <SRC_ORG> --out ./org-tf\n\n"
            "  # Export from a self-hosted instance instead\n"
            "  monad-org-export.py export --base-url https://monad.corp.internal \\\n"
            "      --org-id <SRC_ORG> --out ./org-tf\n\n"
            "  # Migrate into another org (SaaS or on-prem -- just change the URL)\n"
            "  MONAD_TARGET_API_TOKEN=... monad-org-export.py apply --dir ./org-tf \\\n"
            "      --target-base-url https://app.monad.com --target-org-id <DST_ORG>\n\n"
            "  # Back up to a Git repo\n"
            "  monad-org-export.py push --dir ./org-tf \\\n"
            "      --remote git@github.com:acme/monad-org-backup.git -m 'nightly backup'\n"
        ),
    )
    sub = p.add_subparsers(dest="cmd", required=True)

    e = sub.add_parser("export", help="read a SOURCE org and write a Terraform module",
                       formatter_class=argparse.RawDescriptionHelpFormatter)
    e.add_argument("--base-url", default=os.environ.get("MONAD_BASE_URL", DEFAULT_BASE_URL),
                   help=f"source instance base URL (default {DEFAULT_BASE_URL})")
    e.add_argument("--org-id", default=os.environ.get("MONAD_ORGANIZATION_ID"),
                   help="source organization id (or $MONAD_ORGANIZATION_ID)")
    e.add_argument("--out", required=True, help="output directory for the module")
    e.add_argument("--token-file", help="file containing the source API token")
    e.add_argument("--customer-only", action="store_true",
                   help="skip resources whose managed_by is not 'customer' (system/auto)")
    e.add_argument("--emit-imports", action="store_true",
                   help="also write imports.tf with `import {}` blocks (Terraform 1.5+) to "
                        "ADOPT the source org's existing resources into state in place, "
                        "instead of creating new ones on a target")
    e.add_argument("--insecure", action="store_true",
                   help="skip TLS verification (self-signed on-prem only; not recommended)")
    e.set_defaults(func=export)

    a = sub.add_parser("apply", help="terraform apply the module against a TARGET org")
    a.add_argument("--dir", required=True, help="exported module directory")
    a.add_argument("--target-base-url", help="target instance base URL")
    a.add_argument("--target-org-id", help="target organization id")
    a.add_argument("--token-file", help="file containing the target API token")
    a.add_argument("--auto-approve", action="store_true", help="pass -auto-approve to terraform")
    a.set_defaults(func=apply)

    g = sub.add_parser("push", help="commit the module to a Git remote for backup")
    g.add_argument("--dir", required=True, help="exported module directory")
    g.add_argument("--remote", help="git remote URL (GitHub/GitLab); omit for local-only commit")
    g.add_argument("--branch", default="main", help="branch name (default main)")
    g.add_argument("-m", "--message", default="Monad org export", help="commit message")
    g.add_argument("--no-push", action="store_true", help="commit but do not push")
    g.set_defaults(func=push)
    return p


def main(argv):
    args = build_parser().parse_args(argv)
    try:
        args.func(args)
    except MonadAPIError as e:
        die(str(e))
    except KeyboardInterrupt:
        sys.exit(130)


if __name__ == "__main__":
    main(sys.argv[1:])

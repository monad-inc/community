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
  verify   compare a TARGET org against the export's MANIFEST.json and list
           anything that did not make it across

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
# The HCL this tool emits (scalar edge `value`, `values` lists, `monad_alert_rule`,
# structured `{ id = ... }` secret references) matches the provider from 0.4.1 on.
PROVIDER_MIN_VERSION = "0.4.1"
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
TRANSFORM_KIND = ("v1", "transforms", "transforms", "monad_transform")
ALERT_RULE_KIND = ("v3", "alert_rules", "alert_rules", "monad_alert_rule")
# pipeline node component_type -> (api_version, path_segment) for fetching a
# component the list endpoints did not return (e.g. a system-managed one).
COMPONENT_TYPE_PATHS = {
    "input": ("v1", "inputs"),
    "output": ("v1", "outputs"),
    "transform": ("v1", "transforms"),
    "enrichment": ("v3", "enrichments"),
}

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
            if not items:
                break
            pg = d.get("pagination") or {}
            total = pg.get("total")
            # Advance by what the server actually returned, not by what we asked
            # for: a server that clamps `limit` would otherwise make us skip a
            # window of resources on every page.
            offset += len(items)
            if total is not None and offset >= total:
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
        lines.append(f"    settings = {hcl_value(remap_secret_ids(settings, secret_ref_map), 2)}")
    if secrets:
        remapped = _remap_secret_refs(secrets, secret_ref_map, warnings, ctx_label)
        lines.append(f"    secrets = {hcl_value(remapped, 2)}")
    if not lines:
        return None
    return "  config {\n" + "\n".join(lines) + "\n  }"


def _remap_secret_refs(secrets, secret_ref_map, warnings, ctx_label):
    """config.secrets slots reference an org-specific secret as `{"id": "<uuid>"}`
    (the API never returns the value). Rewrite each known id to a Terraform
    reference so it resolves against the recreated secret on the target, and
    flag slots that point at a secret this export did not see."""
    out = remap_secret_ids(secrets, secret_ref_map)
    for slot, val in (out or {}).items():
        sid = val.get("id") if isinstance(val, dict) else val
        if isinstance(sid, str) and sid and not isinstance(sid, Raw) and _looks_like_uuid(sid):
            warnings.append(
                f"{ctx_label}: secret slot '{slot}' references secret {sid}, which is "
                f"not in this export (deleted, or owned by another org). The literal "
                f"id is emitted and will NOT resolve on a different instance."
            )
    return out


_UUID_RE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$", re.I)


def _looks_like_uuid(s):
    return bool(_UUID_RE.match(s or ""))


def remap_secret_ids(value, secret_ref_map):
    """Deep-walk any JSON value and replace every string that IS a known source
    secret id with a `monad_secret.<name>.id` reference. Covers `{id: ...}`
    references in connector `config.secrets`, and the secret ids that transform
    operations such as `mask`/`encrypt` embed inside their `config`."""
    if isinstance(value, Raw):
        return value
    if isinstance(value, str):
        addr = secret_ref_map.get(value)
        return Raw(f"{addr}.id") if addr else value
    if isinstance(value, list):
        return [remap_secret_ids(v, secret_ref_map) for v in value]
    if isinstance(value, dict):
        return {k: remap_secret_ids(v, secret_ref_map) for k, v in value.items()}
    return value


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
        block.append(f"  name        = {hcl_string(s.get('name') or local)}")
        if s.get("description"):
            block.append(f"  description = {hcl_string(s['description'])}")
        block.append(f"  value       = var.{var}")
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
            component_blocks[tf_type].append(
                render_component(it, tf_type, id_to_addr, secret_ref_map, used_names, warnings, manifest)
            )

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
        transform_blocks.append(
            render_transform(it, id_to_addr, secret_ref_map, used_names, warnings, manifest)
        )

    # A pipeline node may reference a component the list endpoints did not
    # return (the API hides `internal`-managed components, and a listing can
    # race a concurrent create). Rather than emit a literal id that can never
    # resolve on another instance, fetch the component by id and export it too.
    def resolve_component(node, pipeline_name):
        cid, ctype = node.get("component_id"), node.get("component_type")
        if not cid or cid in id_to_addr:
            return
        ver_seg = COMPONENT_TYPE_PATHS.get(ctype)
        if not ver_seg:
            warnings.append(
                f"pipeline '{pipeline_name}': node '{node.get('slug')}' has unknown "
                f"component_type '{ctype}'; the literal component id is emitted."
            )
            return
        try:
            it = client.get(ver_seg[0], ver_seg[1], cid)
        except MonadAPIError as e:
            warnings.append(
                f"pipeline '{pipeline_name}': node '{node.get('slug')}' references "
                f"{ctype} {cid}, which the list endpoint did not return and GET failed "
                f"({e}). The literal id is emitted and will not resolve elsewhere."
            )
            return
        if it.get("managed_by") not in (None, "customer"):
            warnings.append(
                f"pipeline '{pipeline_name}': node '{node.get('slug')}' references "
                f"{ctype} '{it.get('name')}' ({cid}) managed_by={it.get('managed_by')}, "
                f"which is not listed to customers. It is exported so the pipeline can "
                f"be recreated, but the target may reject creating it."
            )
        if ctype == "transform":
            transform_blocks.append(
                render_transform(it, id_to_addr, secret_ref_map, used_names, warnings, manifest)
            )
        else:
            tf_type = {"input": "monad_input", "output": "monad_output", "enrichment": "monad_enrichment"}[ctype]
            component_blocks[tf_type].append(
                render_component(it, tf_type, id_to_addr, secret_ref_map, used_names, warnings, manifest)
            )

    # ---- pipelines (need per-pipeline GET for nodes/edges)
    print("Fetching pipelines ...", file=sys.stderr)
    pipeline_blocks = []
    pipelines = client.list("v2", "pipelines", "pipelines")
    pipeline_stats = {"schema_detection_enabled": 0, "disabled_edges": 0}
    for p in pipelines:
        if args.customer_only and p.get("managed_by") not in (None, "customer"):
            continue
        full = client.get("v2", "pipelines", p["id"])
        for n in full.get("nodes") or []:
            resolve_component(n, full.get("name") or p.get("name"))
        block = render_pipeline(full, id_to_addr, used_names, warnings, manifest,
                                force_disabled=args.pipelines_disabled, stats=pipeline_stats)
        if block:
            pipeline_blocks.append(block)
    if pipeline_stats["schema_detection_enabled"]:
        warnings.append(
            f"{pipeline_stats['schema_detection_enabled']} edge(s) have schema drift "
            f"detection enabled on the source. The Terraform provider cannot express "
            f"`schema_detection_spec`, so on the target these edges start with detection "
            f"disabled; re-enable it after the first apply (PATCH "
            f"/v2/{{org}}/pipelines/{{id}}/edges/{{edge_id}})."
        )
    if pipeline_stats["disabled_edges"]:
        warnings.append(
            f"{pipeline_stats['disabled_edges']} edge(s) are disabled on the source. The "
            f"provider has no `disabled` attribute, so they are created enabled."
        )
    if args.pipelines_disabled:
        warnings.append(
            "All pipelines are emitted with `enabled = false` (--pipelines-disabled). "
            "Enable them on the target once the secret values are in place."
        )

    # ---- alert rules (customer-managed only; the org-seeded system rules such
    # as "Schema Drift Detection" and "Pipeline Throttled" already exist on any
    # target org and must not be duplicated)
    print("Fetching alert rules ...", file=sys.stderr)
    alert_rule_blocks = []
    try:
        rules = client.list(*ALERT_RULE_KIND[:3])
    except MonadAPIError as e:
        warnings.append(f"Could not list alert_rules: {e}")
        rules = []
    skipped_system = 0
    for r in rules:
        if r.get("managed_by") not in (None, "customer"):
            skipped_system += 1
            continue
        alert_rule_blocks.append(render_alert_rule(r, id_to_addr, manifest, used_names, warnings))
    if skipped_system:
        warnings.append(
            f"Skipped {skipped_system} system-managed alert rule(s); every org already "
            f"has them, so exporting them would create duplicates."
        )

    write_module(
        outdir, args, secret_blocks, secret_vars, secret_tfvars,
        component_blocks, transform_blocks, pipeline_blocks, alert_rule_blocks,
        manifest, warnings,
    )

    print(f"\nExported to {outdir}/", file=sys.stderr)
    print(f"  secrets:    {len(secret_blocks)}", file=sys.stderr)
    for _, seg, _, tf in RESOURCE_KINDS:
        print(f"  {seg:10} {len(component_blocks[tf])}", file=sys.stderr)
    print(f"  transforms: {len(transform_blocks)}", file=sys.stderr)
    print(f"  pipelines:  {len(pipeline_blocks)}", file=sys.stderr)
    print(f"  alert rules: {len(alert_rule_blocks)}", file=sys.stderr)
    if warnings:
        print(f"\n{len(warnings)} warning(s) — see {outdir}/EXPORT_NOTES.md", file=sys.stderr)


def _warn_version(it, addr, warnings):
    # The provider has no `version` attribute, so the target always creates the
    # connector type's current default version. Flag anything that isn't v1.
    v = it.get("version")
    if v not in (None, 0, 1, "1"):
        warnings.append(
            f"{addr}: source runs connector version {v} of type '{it.get('type')}'. "
            f"The provider cannot pin a connector version, so the target gets the "
            f"type's default version; check the settings still apply."
        )


def render_component(it, tf_type, id_to_addr, secret_ref_map, used_names, warnings, manifest):
    local = sanitize_name(it.get("name"), used_names)
    addr = f"{tf_type}.{local}"
    id_to_addr[it["id"]] = addr
    manifest["resources"][it["id"]] = {
        "address": addr, "name": it.get("name"), "type": tf_type,
        "connector_type": it.get("type"),
    }
    _warn_version(it, addr, warnings)
    block = [f'resource "{tf_type}" "{local}" {{']
    block.append(f"  name        = {hcl_string(it.get('name') or local)}")
    if it.get("description"):
        block.append(f"  description = {hcl_string(it['description'])}")
    block.append(f"  type        = {hcl_string(it.get('type') or '')}")
    cfg = build_config_block(it.get("config"), secret_ref_map, warnings, addr)
    if cfg:
        block.append(cfg)
    block.append("}")
    return "\n".join(block)


def render_transform(it, id_to_addr, secret_ref_map, used_names, warnings, manifest):
    local = sanitize_name(it.get("name"), used_names)
    addr = f"monad_transform.{local}"
    id_to_addr[it["id"]] = addr
    manifest["resources"][it["id"]] = {"address": addr, "name": it.get("name"), "type": "monad_transform"}
    block = [f'resource "monad_transform" "{local}" {{']
    block.append(f"  name        = {hcl_string(it.get('name') or local)}")
    if it.get("description"):
        block.append(f"  description = {hcl_string(it['description'])}")
    # mask/encrypt operations embed the secret id inside the operation config;
    # remap those so the transform is created against the target's secret.
    config = remap_secret_ids(it.get("config") or {}, secret_ref_map)
    block.append(f"  config = {hcl_value(config, 1)}")
    block.append("}")
    return "\n".join(block)


def render_alert_rule(r, id_to_addr, manifest, used_names, warnings):
    local = sanitize_name(r.get("name"), used_names)
    addr = f"monad_alert_rule.{local}"
    manifest["resources"][r["id"]] = {"address": addr, "name": r.get("name"), "type": "monad_alert_rule"}
    block = [f'resource "monad_alert_rule" "{local}" {{']
    block.append(f"  name        = {hcl_string(r.get('name') or local)}")
    if r.get("description"):
        block.append(f"  description = {hcl_string(r['description'])}")
    block.append(f"  type        = {hcl_string(r.get('type') or '')}")
    block.append(f"  severity    = {hcl_string(r.get('severity') or 'medium')}")
    block.append(f"  active      = {'true' if r.get('active', True) else 'false'}")
    pids = r.get("pipeline_ids") or []
    if pids:
        refs = []
        for pid in pids:
            ref = id_to_addr.get(pid)
            if ref:
                refs.append(Raw(f"{ref}.id"))
            else:
                refs.append(pid)
                warnings.append(
                    f"{addr}: watches pipeline {pid}, which is not in this export; the "
                    f"literal id is emitted and will not resolve on a different instance."
                )
        block.append(f"  pipeline_ids = {hcl_value(refs, 1)}")
    block.append(f"  rule_config = {hcl_value(r.get('rule_config') or {}, 1)}")
    block.append("}")
    return "\n".join(block)


# Edge condition `config` keys the provider models, with the HCL type each takes.
# Anything else is emitted as-is so `terraform plan` can report it.
_COND_LIST_KEYS = {"values"}
_COND_BOOL_KEYS = {"not", "case_insensitive", "raw", "null", "whitespace_string"}
_COND_NUM_KEYS = {"percent"}


def render_condition_config(cfg, type_id, ctx_label, warnings):
    """Emit one leaf condition's `config {}` body faithfully. The API stores each
    rule's config as a free-form map; the provider (>= 0.4.0) models `value` as a
    single string and `values` as a list, plus typed boolean/number knobs."""
    lines = []
    for k, v in (cfg or {}).items():
        if v is None or v == "" or v == []:
            continue
        key = k
        if k == "value" and isinstance(v, list):
            # Legacy shape (pre-0.4.0 provider wrote lists); the API rule that
            # takes a set is `equals_any`, which the provider spells `values`.
            key = "values"
            if type_id != "equals_any":
                warnings.append(
                    f"{ctx_label}: condition '{type_id}' has a list `value` "
                    f"{v!r}; emitted as `values`, which only `equals_any` accepts."
                )
        if key in _COND_LIST_KEYS:
            vals = v if isinstance(v, list) else [v]
            lines.append(f"          {key} = {hcl_value([str(x) for x in vals], 5)}")
        elif key in _COND_BOOL_KEYS:
            lines.append(f"          {key} = {'true' if v else 'false'}")
        elif key in _COND_NUM_KEYS:
            lines.append(f"          {key} = {json.dumps(v) if isinstance(v, (int, float)) else hcl_string(str(v))}")
        elif isinstance(v, (dict, list)):
            lines.append(f"          {key} = {hcl_value(v, 5)}")
        else:
            lines.append(f"          {key} = {hcl_string(str(v))}")
    return lines


def render_pipeline(p, id_to_addr, used_names, warnings, manifest, force_disabled=False, stats=None):
    name = p.get("name") or "pipeline"
    local = sanitize_name(name, used_names)
    manifest["resources"][p.get("id")] = {"address": f"monad_pipeline.{local}", "name": name, "type": "pipeline"}
    id_to_addr[p.get("id")] = f"monad_pipeline.{local}"  # alert rules reference pipelines by id
    nodes = p.get("nodes") or []
    edges = p.get("edges") or []
    stats = stats if stats is not None else {}

    # node instance id -> slug (edges in the API reference node ids; the
    # provider wires edges by slug, so we translate).
    nodeid_to_slug = {n.get("id"): n.get("slug") for n in nodes if n.get("id")}

    lines = [f'resource "monad_pipeline" "{local}" {{']
    lines.append(f"  name        = {hcl_string(name)}")
    if p.get("description"):
        lines.append(f"  description = {hcl_string(p['description'])}")
    enabled = False if force_disabled else p.get("enabled", True)
    lines.append(f"  enabled     = {'true' if enabled else 'false'}")

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
        edge_label = f"pipeline '{name}' edge {frm or '?'} -> {to or '?'}"
        if (e.get("schema_detection_spec") or {}).get("enabled"):
            stats["schema_detection_enabled"] = stats.get("schema_detection_enabled", 0) + 1
        if e.get("disabled"):
            stats["disabled_edges"] = stats.get("disabled_edges", 0) + 1
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
            if c.get("operator") and not c.get("type_id"):
                # The API allows logical operators to nest; the provider models a
                # single logical layer over leaf rules.
                warnings.append(
                    f"{edge_label}: nested logical condition ({c.get('operator')}) "
                    f"cannot be expressed by the provider and was dropped. Recreate "
                    f"it on the target by hand."
                )
                continue
            cc = c.get("config") or {}
            lines.append("      conditions {")
            if c.get("type_id"):
                lines.append(f"        type_id = {hcl_string(c['type_id'])}")
            cfg_lines = render_condition_config(cc, c.get("type_id"), edge_label, warnings)
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
                 component_blocks, transform_blocks, pipeline_blocks, alert_rule_blocks,
                 manifest, warnings):
    def w(fn, content):
        (outdir / fn).write_text(content.rstrip() + "\n")

    w("versions.tf", (
        "terraform {\n"
        '  required_version = ">= 1.5"\n'
        "  required_providers {\n"
        "    monad = {\n"
        f'      source  = "{PROVIDER_SOURCE}"\n'
        f'      version = ">= {PROVIDER_MIN_VERSION}"\n'
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
    if alert_rule_blocks:
        w("alert_rules.tf", "\n\n".join(alert_rule_blocks))

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

    # Canonical formatting is cosmetic but keeps `terraform fmt -check` (and
    # reviewers of a Git backup) quiet. Best effort: skip if terraform is absent.
    try:
        subprocess.run(["terraform", "fmt", "-no-color"], cwd=outdir, check=False,
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except OSError:
        pass


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
                 "`secret_*` variable in `terraform.tfvars` (or via `TF_VAR_secret_*`). "
                 "Every `{ id = ... }` secret reference in connector configs and every "
                 "secret id embedded in a transform operation has been rewritten to "
                 "`monad_secret.<name>.id`, so they resolve against the target's copies.")
    lines.append("\n## Applying\n")
    lines.append("Use `monad-org-export.py apply` or run `terraform apply -parallelism=1`. "
                 "Pipeline creation is slow server-side and the provider's HTTP client "
                 "times out after 60 s; at Terraform's default parallelism several pipelines "
                 "are created at once, the later ones exceed the timeout, and Terraform "
                 "records them as failed even though the server finishes creating them. "
                 "If that happens anyway, `verify --write-imports` adopts the orphans.")
    lines.append("\n## After apply\n")
    lines.append("Run `monad-org-export.py verify --dir <this dir> --target-base-url ... "
                 "--target-org-id ...` to confirm every exported resource exists on the "
                 "target by name. Anything listed as missing did not migrate.")
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
        "terraform apply -parallelism=1   # pipeline creates are slow; see EXPORT_NOTES.md\n"
        "```\n\n"
        "Connection settings (`monad_base_url`, `monad_api_token`,\n"
        "`monad_organization_id`) select the target. `https://app.monad.com` is the\n"
        "SaaS default; point `monad_base_url` at your own hostname for a self-hosted\n"
        "instance. Nothing else differs between SaaS and on-prem.\n\n"
        "## Secrets\n\n"
        "Secret values are not exported (the API never returns them). Set each\n"
        "`secret_*` variable before applying — see `EXPORT_NOTES.md`.\n\n"
        "## Verify\n\n"
        "After `apply`, run the exporter's `verify` subcommand against the target to\n"
        "list anything from `MANIFEST.json` that does not exist there by name.\n\n"
        "## Files\n\n"
        "- `versions.tf` / `provider.tf` / `variables.tf` — provider + inputs\n"
        "- `inputs.tf` `outputs.tf` `transforms.tf` `enrichments.tf` `secrets.tf` `pipelines.tf` `alert_rules.tf`\n"
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
    # Pipeline creation is slow on the API side and the provider's HTTP client
    # gives up after 60 s. With Terraform's default parallelism (10) several
    # pipelines are created at once, the later ones exceed the timeout, and
    # Terraform records them as failed even though the server finishes creating
    # them -- leaving resources on the target that are missing from state. A
    # low parallelism keeps each create inside the timeout.
    cmd = ["terraform", "apply", "-input=false", f"-parallelism={args.parallelism}"]
    if args.auto_approve:
        cmd.append("-auto-approve")
    run(cmd, cwd=d, env=env)


# ---------------------------------------------------------------------------
# verify (did everything make it to the target?)
# ---------------------------------------------------------------------------

# manifest type -> (api_version, segment, envelope_key)
_VERIFY_KINDS = {
    "secret": ("v2", "secrets", "secrets"),
    "monad_input": ("v1", "inputs", "inputs"),
    "monad_output": ("v1", "outputs", "outputs"),
    "monad_enrichment": ("v3", "enrichments", "enrichments"),
    "monad_transform": ("v1", "transforms", "transforms"),
    "pipeline": ("v2", "pipelines", "pipelines"),
    "monad_alert_rule": ("v3", "alert_rules", "alert_rules"),
}


def verify(args):
    """Read-only: list every resource kind on the TARGET org and report which
    entries of MANIFEST.json have no same-named counterpart there. This is the
    check that turns "the run finished" into "everything migrated"."""
    d = Path(args.dir)
    mpath = d / "MANIFEST.json"
    if not mpath.exists():
        die(f"{mpath} not found; point --dir at an exported module")
    manifest = json.loads(mpath.read_text())
    token = resolve_token(args, "MONAD_TARGET_API_TOKEN")
    if not args.target_org_id:
        die("--target-org-id is required")
    client = Client(args.target_base_url, token, args.target_org_id, insecure=args.insecure)

    wanted = {}  # type -> [(name, address)]
    for rid, meta in manifest["resources"].items():
        wanted.setdefault(meta["type"], []).append((meta["name"], meta["address"]))

    # Addresses Terraform already tracks (only meaningful when run from a module
    # that has been applied). A resource that exists on the target but is absent
    # from state is an orphan of an interrupted apply -- typically a pipeline
    # whose create outlived the provider's 60 s timeout. Those are what
    # --write-imports recovers.
    in_state = None
    try:
        r = subprocess.run(["terraform", "state", "list"], cwd=d, capture_output=True, text=True)
        if r.returncode == 0:
            in_state = set(r.stdout.split())
    except OSError:
        pass

    missing_total, orphans = 0, []
    print(f"{'kind':18} {'exported':>8} {'on target':>9} {'missing':>7}")
    for kind, entries in sorted(wanted.items()):
        spec = _VERIFY_KINDS.get(kind)
        if not spec:
            print(f"{kind:18} {len(entries):8} {'?':>9} {'?':>7}   (no list endpoint known)")
            continue
        try:
            present = {r.get("name"): r.get("id") for r in client.list(*spec)}
        except MonadAPIError as e:
            print(f"{kind:18} {len(entries):8} {'ERR':>9} {'?':>7}   {e}")
            missing_total += len(entries)
            continue
        missing = [n for n, _ in entries if n not in present]
        missing_total += len(missing)
        print(f"{kind:18} {len(entries):8} {len(entries) - len(missing):9} {len(missing):7}")
        for n in missing:
            print(f"    missing: {n}")
        if in_state is not None:
            for n, addr in entries:
                if n in present and addr not in in_state:
                    orphans.append((addr, present[n], n))

    if orphans:
        print(f"\n{len(orphans)} resource(s) exist on the target but are not in Terraform state "
              f"(created by an apply that timed out):", file=sys.stderr)
        for addr, tid, n in orphans:
            print(f"    {addr}  <-  {tid}  ({n})", file=sys.stderr)
        if args.write_imports:
            blocks = ["# Generated by monad-org-export verify --write-imports.",
                      "# Adopts resources an interrupted apply created but never recorded.",
                      "# Run `terraform apply` once, then delete this file.", ""]
            for addr, tid, _ in orphans:
                blocks.append(f'import {{\n  to = {addr}\n  id = {hcl_string(tid)}\n}}')
            (d / "imports-recover.tf").write_text("\n".join(blocks) + "\n")
            print(f"    wrote {d / 'imports-recover.tf'}; re-run apply to adopt them.", file=sys.stderr)
        else:
            print("    re-run with --write-imports to generate import blocks for them.", file=sys.stderr)

    if missing_total:
        print(f"\n{missing_total} resource(s) from the export are not on the target.", file=sys.stderr)
        sys.exit(2)
    print("\nAll exported resources exist on the target.", file=sys.stderr)


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
            "  # Confirm everything landed on the target\n"
            "  MONAD_TARGET_API_TOKEN=... monad-org-export.py verify --dir ./org-tf \\\n"
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
    e.add_argument("--pipelines-disabled", action="store_true",
                   help="emit every pipeline with enabled = false so nothing runs on the "
                        "target until its secret values are in place (recommended for "
                        "migrations; omit for a faithful backup)")
    e.add_argument("--insecure", action="store_true",
                   help="skip TLS verification (self-signed on-prem only; not recommended)")
    e.set_defaults(func=export)

    a = sub.add_parser("apply", help="terraform apply the module against a TARGET org")
    a.add_argument("--dir", required=True, help="exported module directory")
    a.add_argument("--target-base-url", help="target instance base URL")
    a.add_argument("--target-org-id", help="target organization id")
    a.add_argument("--token-file", help="file containing the target API token")
    a.add_argument("--auto-approve", action="store_true", help="pass -auto-approve to terraform")
    a.add_argument("--parallelism", type=int, default=1,
                   help="terraform -parallelism (default 1: pipeline creates are slow and the "
                        "provider times out after 60 s when several run at once)")
    a.set_defaults(func=apply)

    v = sub.add_parser("verify", help="check that every exported resource exists on a TARGET org")
    v.add_argument("--dir", required=True, help="exported module directory (reads MANIFEST.json)")
    v.add_argument("--target-base-url", default=os.environ.get("MONAD_BASE_URL", DEFAULT_BASE_URL),
                   help=f"target instance base URL (default {DEFAULT_BASE_URL})")
    v.add_argument("--target-org-id", default=os.environ.get("MONAD_ORGANIZATION_ID"),
                   help="target organization id")
    v.add_argument("--token-file", help="file containing the target API token")
    v.add_argument("--write-imports", action="store_true",
                   help="write imports-recover.tf for resources that exist on the target but are "
                        "missing from Terraform state (left behind by a timed-out apply)")
    v.add_argument("--insecure", action="store_true", help="skip TLS verification")
    v.set_defaults(func=verify)

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

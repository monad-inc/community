#!/usr/bin/env python3
"""Validate a Monad onboarding intake document.

Usage: validate-intake.py <intake.yaml|intake.json>

Checks the document against references/intake.schema.json, then applies the
skill's own rules:
  - a data_model.strategy is required when any output is index-based
    (per references/modules/outputs/_registry.yaml);
  - no credential-like keys anywhere in the document;
  - warnings for answers the skill will have to ask about.

YAML input needs `yq` (mikefarah, v4) on PATH; JSON input needs nothing but
python3 (standard library only).

Exit status: 0 valid (warnings allowed), 1 invalid, 2 usage or read error.
"""

import json
import os
import re
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SKILL = os.path.dirname(HERE)
SCHEMA = os.path.join(SKILL, "references", "intake.schema.json")
OUTPUT_REGISTRY = os.path.join(SKILL, "references", "modules", "outputs", "_registry.yaml")

# Keys that hold credentials. Matched case-insensitively against the whole key.
CREDENTIAL_KEYS = re.compile(
    r"^(token|hec_token|password|passwd|secret|client_secret|api_key|apikey|"
    r"api_token|access_key|secret_key|secret_access_key|private_key|"
    r"bearer|auth_token|session_token|credentials?)$",
    re.IGNORECASE,
)
PLACEHOLDER = "REPLACE_ME"


def usage(msg):
    print(f"validate-intake: {msg}", file=sys.stderr)
    print("usage: validate-intake.py <intake.yaml|intake.json>", file=sys.stderr)
    sys.exit(2)


def load(path):
    """Load JSON directly, or YAML through yq."""
    try:
        with open(path, encoding="utf-8") as f:
            text = f.read()
    except OSError as e:
        usage(f"cannot read {path}: {e}")
    if not path.lower().endswith((".yaml", ".yml")):
        try:
            return json.loads(text)
        except json.JSONDecodeError:
            pass  # fall through: maybe YAML with another extension
    if not shutil.which("yq"):
        usage("YAML input needs yq (mikefarah, v4) on PATH; or pass a JSON file")
    proc = subprocess.run(
        ["yq", "-o=json", ".", path], capture_output=True, text=True
    )
    if proc.returncode != 0:
        usage(f"yq could not parse {path}: {proc.stderr.strip()}")
    try:
        return json.loads(proc.stdout)
    except json.JSONDecodeError as e:
        usage(f"yq produced invalid JSON for {path}: {e}")


TYPES = {
    "object": dict,
    "array": list,
    "string": str,
    "boolean": bool,
}


def type_ok(value, expected):
    if expected == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    if expected == "number":
        return isinstance(value, (int, float)) and not isinstance(value, bool)
    return isinstance(value, TYPES[expected])


def validate(value, schema, path, errors):
    """The subset of JSON Schema that intake.schema.json uses."""
    expected = schema.get("type")
    if expected and not type_ok(value, expected):
        errors.append(f"{path}: expected {expected}, got {type(value).__name__}")
        return
    if "const" in schema and value != schema["const"]:
        errors.append(f"{path}: must be {schema['const']!r}")
    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path}: {value!r} is not one of {schema['enum']}")
    if isinstance(value, dict):
        for key in schema.get("required", []):
            if key not in value:
                errors.append(f"{path}: missing required field '{key}'")
        props = schema.get("properties", {})
        for key, sub in value.items():
            if key in props:
                validate(sub, props[key], f"{path}.{key}", errors)
            elif schema.get("additionalProperties") is False:
                errors.append(f"{path}: unknown field '{key}'")
    if isinstance(value, list):
        if len(value) < schema.get("minItems", 0):
            errors.append(f"{path}: needs at least {schema['minItems']} item(s)")
        if "items" in schema:
            for i, item in enumerate(value):
                validate(item, schema["items"], f"{path}[{i}]", errors)


def index_based_types():
    """Output types the registry marks index-based. Empty set if unreadable."""
    try:
        registry = load(OUTPUT_REGISTRY)
    except SystemExit:
        return set()
    return {
        o["type"]
        for o in (registry or {}).get("outputs", [])
        if o.get("index_based")
    }


def find_credentials(value, path, errors):
    if isinstance(value, dict):
        for key, sub in value.items():
            here = f"{path}.{key}"
            if CREDENTIAL_KEYS.match(str(key)) and sub not in (None, "", PLACEHOLDER):
                errors.append(
                    f"{here}: looks like a credential. Remove it: the skill creates "
                    f"a {PLACEHOLDER} placeholder secret and you set the real value "
                    "in the Monad UI"
                )
            find_credentials(sub, here, errors)
    elif isinstance(value, list):
        for i, item in enumerate(value):
            find_credentials(item, f"{path}[{i}]", errors)


def rules(doc, errors, warnings):
    outputs = doc.get("outputs") or []
    indexed = index_based_types()
    chosen = sorted({o.get("type") for o in outputs if o.get("type") in indexed})
    strategy = (doc.get("data_model") or {}).get("strategy")
    if chosen and not strategy:
        errors.append(
            f"data_model.strategy: required because {', '.join(chosen)} "
            "is index-based (single | per_source | by_category)"
        )
    if strategy and not chosen:
        warnings.append("data_model: set, but no chosen output is index-based; it will be ignored")

    template = ((doc.get("data_model") or {}).get("options") or {}).get("index_name_template")
    if strategy == "by_category" and template and "{category}" not in template:
        warnings.append(
            "data_model.options.index_name_template: has no {category} token, "
            "so every category would get the same index name"
        )
    for o in outputs:
        cfg = o.get("config") or {}
        if o.get("type") == "splunk" and str(cfg.get("index", "")).lower() == "main":
            errors.append("outputs: a Splunk output targets 'main'; never use the default index")

    sources = doc.get("data_sources") or []
    if not any(s.get("care") for s in sources):
        errors.append("data_sources: no category has care: true, so there is nothing to build")
    for i, s in enumerate(sources):
        if s.get("care") and not s.get("tools"):
            warnings.append(
                f"data_sources[{i}] ({s.get('category')}): collected but no tools "
                "listed; the skill will ask"
            )

    env = doc.get("environment_name", "")
    if isinstance(env, str) and env and not re.fullmatch(r"[a-z0-9][a-z0-9-]*", env):
        warnings.append(
            "environment_name: use lowercase letters, digits, and hyphens so "
            "generated component and index names stay valid"
        )

    layout = doc.get("pipeline_layout") or {}
    streams = layout.get("mixed_streams") or []
    stream_sources = {s.get("source") for s in streams}
    for i, s in enumerate(sources):
        for j, tool in enumerate(s.get("tools") or []):
            via = tool.get("via")
            if via is not None and via not in stream_sources:
                errors.append(
                    f"data_sources[{i}].tools[{j}].via: '{via}' is not the source of "
                    f"any pipeline_layout.mixed_streams entry {sorted(stream_sources)}"
                )
    for i, stream in enumerate(streams):
        if strategy == "by_category" and chosen:
            for j, t in enumerate(stream.get("types") or []):
                if not t.get("category") and not t.get("destination"):
                    errors.append(
                        f"pipeline_layout.mixed_streams[{i}].types[{j}] ({t.get('name')}): "
                        "needs a category or destination, because data_model.strategy "
                        "is by_category"
                    )
        names = [t.get("name") for t in stream.get("types") or []]
        dupes = sorted({n for n in names if names.count(n) > 1})
        if dupes:
            errors.append(
                f"pipeline_layout.mixed_streams[{i}]: duplicate type names {dupes}"
            )
        for j, t in enumerate(stream.get("types") or []):
            if not t.get("match"):
                warnings.append(
                    f"pipeline_layout.mixed_streams[{i}].types[{j}] ({t.get('name')}): "
                    "no match rule; the skill will ask how to recognize it"
                )

    find_credentials(doc, "$", errors)


def main():
    if len(sys.argv) != 2 or sys.argv[1] in ("-h", "--help"):
        print(__doc__.strip())
        sys.exit(0 if len(sys.argv) == 2 else 2)
    doc = load(sys.argv[1])
    with open(SCHEMA, encoding="utf-8") as f:
        schema = json.load(f)

    errors, warnings = [], []
    if not isinstance(doc, dict):
        errors.append("$: the intake must be a mapping/object")
    else:
        validate(doc, schema, "$", errors)
        rules(doc, errors, warnings)

    for w in warnings:
        print(f"warning: {w}")
    for e in errors:
        print(f"error: {e}")
    if errors:
        print(f"INVALID: {len(errors)} error(s), {len(warnings)} warning(s)")
        sys.exit(1)
    print(f"VALID: {len(warnings)} warning(s)")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Restore per-attribute `profile` annotations in a bundled OCSF schema.

Since 1.8.0 the schema server's /api/classes/<name> (and /api/objects/<name>,
/api/base_event) endpoints return every profile attribute flattened to
`profile: null`, so a bundle assembled from them treats profile attributes
(device, policy, action_id, disposition_id, proxy_endpoint, ...) as base
attributes. The hosted validator does not: it rejects them as
`attribute_unknown` unless the event declares the profile in
`metadata.profiles`.

The same endpoints accept `?profiles=<list>` and then return only the base
attributes plus the listed profiles' attributes. So for each class/object:

    base        = keys(GET ...?profiles=)
    attrs(p)    = keys(GET ...?profiles=p) - base
    profile[a]  = p   for every a in attrs(p)

Usage:
    restore-profile-annotations.py <version>          # e.g. 1.9.0
    restore-profile-annotations.py <version> --check  # report only, no write

Rewrites references/ocsf/v<version>/schema.json in place (same formatting
as before) and prints a per-profile count of annotated attributes. Requires
network access to schema.ocsf.io (or OCSF_SCHEMA_URL).
"""

import json
import os
import sys
import urllib.parse
import urllib.request
from collections import Counter
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

BASE_URL = os.environ.get("OCSF_SCHEMA_URL", "https://schema.ocsf.io").rstrip("/")


def attr_keys(doc):
    attrs = doc.get("attributes") or {}
    if isinstance(attrs, list):  # 1.6/1.7 servers return a list of single-key maps
        merged = {}
        for item in attrs:
            merged.update(item)
        attrs = merged
    return set(attrs)


def fetch(version, path, profiles):
    q = urllib.parse.urlencode({"profiles": ",".join(profiles)})
    url = f"{BASE_URL}/{version}/api/{path}?{q}"
    with urllib.request.urlopen(url, timeout=60) as resp:
        return attr_keys(json.load(resp))


def profile_map(version, path, profiles):
    """Return {attribute: profile} for the profile attributes of one class/object."""
    base = fetch(version, path, [])
    out = {}
    for p in profiles:
        for a in sorted(fetch(version, path, [p]) - base):
            out.setdefault(a, p)  # an attribute shared by several profiles keeps the first
    return out


def api_path(kind, key):
    # Extension entries are keyed "win/<name>" in the bundle and served at
    # .../api/<kind>/win/<name>.
    return f"{kind}/{key}"


def main():
    if len(sys.argv) < 2:
        print(__doc__, file=sys.stderr)
        sys.exit(64)
    version = sys.argv[1]
    check_only = "--check" in sys.argv[2:]
    schema_path = Path(__file__).resolve().parent.parent / "references" / "ocsf" / f"v{version}" / "schema.json"
    text = schema_path.read_text()
    pretty = text.startswith("{\n")  # keep the bundle's existing formatting
    schema = json.loads(text)

    jobs = []
    for key, cls in schema.get("classes", {}).items():
        if cls.get("profiles"):
            jobs.append(("classes", key, cls))
    for key, obj in schema.get("objects", {}).items():
        if obj.get("profiles"):
            jobs.append(("objects", key, obj))
    base_event = schema.get("base_event")
    if base_event and base_event.get("profiles"):
        jobs.append(("base_event", None, base_event))

    def run(job):
        kind, key, doc = job
        path = "base_event" if kind == "base_event" else api_path(kind, key)
        return job, profile_map(version, path, doc["profiles"])

    counts = Counter()
    changed = 0
    with ThreadPoolExecutor(max_workers=8) as pool:
        for (kind, key, doc), pmap in pool.map(run, jobs):
            attrs = doc.get("attributes") or {}
            for name, prof in pmap.items():
                if name in attrs and attrs[name].get("profile") != prof:
                    attrs[name]["profile"] = prof
                    changed += 1
                counts[prof] += 1

    print(f"v{version}: {len(jobs)} classes/objects checked, {changed} attribute annotations restored")
    for prof, n in sorted(counts.items()):
        print(f"  {prof}: {n}")
    if not check_only:
        if pretty:
            schema_path.write_text(json.dumps(schema, indent=2, ensure_ascii=False) + "\n")
        else:
            schema_path.write_text(json.dumps(schema, separators=(",", ":"), ensure_ascii=False) + "\n")


if __name__ == "__main__":
    main()

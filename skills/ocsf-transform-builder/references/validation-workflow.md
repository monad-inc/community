# Validation Workflow

How to verify that an OCSF transform — new or existing — actually produces
schema-conformant output.

## Required inputs

1. The transform YAML (e.g., `ocsf/v1.1.0/okta/okta-systemlog.yaml`).
2. A synthetic input record matching the transform's declared `inputs:` type.
   Provided by the user, or hand-crafted to exercise edge cases.
3. The OCSF version the transform targets (read from the `tags:` block or the
   path: `ocsf/v<X.Y.Z>/...`).
4. The OCSF class the transform claims to produce. Usually inferable from the
   transform's hard-coded `class_uid` in the jq query; fall back to asking the
   user if ambiguous.

## Steps

### 1. Run the transform

```bash
scripts/run-transform.sh <transform.yaml> <input.json>
```

Confirm it produces valid JSON with no jq errors. If the input is a JSON array
and the transform expects to receive the whole array (rare — most transforms
operate per-record), pass `--slurp`.

### 2. Check schema conformance (local, version-pinned)

```bash
scripts/validate-against-ocsf.sh <transform.yaml> <input.json> <version> <class_name_or_uid> [profiles]
```

This is an offline structural diff against the bundled schema for the exact
target version. It emits three sections:

- **MISSING REQUIRED** — fields the OCSF class requires that the output does
  not have. Each is a real bug; fix before merging.
- **MISSING RECOMMENDED** — fields OCSF says SHOULD be present. Not blocking,
  but worth populating if the source data carries them.
- **UNKNOWN TOP-LEVEL KEYS** — keys in the output that aren't part of the
  OCSF class. Common causes:
  - Typo in the field name (e.g., `"ip "` with a trailing space).
  - Field belongs nested (e.g., `auth_protocol_id` belongs at the top level,
    not inside a made-up `authentication_info` wrapper).
  - Vendor-specific extension — should go inside the `unmapped` object.
  - `raw_data`, `unmapped`, and `ref_time` are allowlisted as conventional
    extensions used across the community-transformations repo.

The local check only compares top-level key presence. It does NOT understand
constraints, enums, or types — that is what the official validator (next step)
is for. Run both.

### 2b. Validate against the official OCSF validator API (authoritative)

```bash
scripts/validate-ocsf-api.sh <transform.yaml> <input.json> [--slurp]
```

This runs the transform and POSTs the resulting event(s) to the official OCSF
validator — the `validate2` endpoint
(`POST https://schema.ocsf.io/api/v2/validate`, documented at
<https://schema.ocsf.io/doc/index.html#/Tools/SchemaWeb.SchemaController.validate2>),
or `/api/v2/validate_bundle` when the transform emits more than one event. It
reports per-event **errors** and **warnings** and exits non-zero on any error.

It catches whole classes of bugs the local check is blind to:

- **Constraint failures** — e.g. the Authentication class requires
  `at_least_one` of `service`/`dst_endpoint`; a transform with neither passes
  the local check (both are optional individually) but fails here.
- **Enum value errors** — an `activity_id` or `severity_id` outside the
  class's allowed set.
- **Type mismatches** — a string where OCSF requires an integer, etc.
- **UID consistency** — `type_uid` must equal `class_uid * 100 + activity_id`;
  `category_uid`/`class_uid` must agree.
- **Deprecation warnings** — attributes deprecated in the schema.

**Schema-version caveat.** The hosted validator at `schema.ocsf.io` always
validates against the *latest* published OCSF schema. It reads
`metadata.version` from each event only to emit a `version_earlier` warning —
it does not switch schemas per event. For a transform targeting an older
version (say v1.1.0), expect a `version_earlier` warning plus any deprecation
warnings introduced in later versions; these do not necessarily apply to the
targeted version. Triage:

- **Errors** from the API are real conformance bugs at any version — fix them.
- **Warnings** that are purely `version_earlier`/deprecation noise from a newer
  schema can be acknowledged and ignored when the transform targets an older
  version. Confirm against the bundled `references/ocsf/v<version>/schema.json`
  if unsure.

To validate against a *specific* version instead of latest, run the OCSF
server locally pinned to that schema (see
<https://github.com/ocsf/ocsf-server>) and point the script at it:

```bash
OCSF_VALIDATOR_URL=http://localhost:8080 scripts/validate-ocsf-api.sh <transform.yaml> <input.json>
```

The local structural check (step 2) remains the version-exact complement when
running a local server isn't practical.

### 3. Inspect required objects

OCSF required fields are often nested objects (e.g., the Authentication class
requires a `user` object). Listing top-level keys doesn't validate the inner
shape. For each required object, drill in:

```bash
scripts/lookup-ocsf-object.sh <version> <object_name>
```

Then re-read the jq output and confirm the nested object carries at least the
object's required attributes.

### 4. Profiles

Some OCSF attributes are profile-scoped. The `cloud` profile, for instance,
makes `cloud` a required top-level object; the `host` profile adds `device`;
`security_control` adds `policy`, `action_id`, `disposition_id`, etc. By
default the validator uses the profiles the event declares in
`metadata.profiles` — the same set the hosted validator uses — enforces their
required attributes, and reports:

```
UNDECLARED PROFILE ATTRIBUTES (add the profile to metadata.profiles or drop the attribute; validate2 rejects them):
  - device (profile: host)
```

for any top-level profile attribute the event emits without declaring its
profile. That is a failure: fix it by declaring the profile or dropping the
attribute. To check against a different profile set:

```bash
scripts/validate-against-ocsf.sh ... 1.1.0 authentication cloud,host
```

Pass `all` to enforce every profile the class declares.

A transform should only claim a profile if it can populate that profile's
required fields from the source data. Nested objects can carry profile
attributes too; the local check covers top-level attributes only, so the hosted
validator remains the authority for nested ones.

### 5. Test multiple inputs

Run validation against several synthetic inputs that cover:

- The success path.
- A failure outcome (e.g., authentication failure, vulnerability resolved).
- Missing optional fields in the source.
- Null/empty values where the source can legitimately omit them.

For each, the required fields must still be populated (often via `// ""`
defaults or conditional `if/elif` blocks in jq).

## Auditing existing transforms in community-transformations

To audit a set of existing OCSF transforms, list them from the clone
(`find "$REPO/ocsf/v<version>" -name '*.yaml'`) and, for each one, get a sample
record (see `contributing-workflow.md`), then run both `validate-against-ocsf.sh`
and, where applicable, `validate-ocsf-api.sh`. Propose a fix (and a pull
request, with the user's approval) for any transform that reports MISSING
REQUIRED locally or any error from the official validator.

## What "fix" means

For each missing-required finding, the fix is one of:

1. Populate the field from the source data via jq. Preferred when source data
   carries the value.
2. Synthesize a sensible default (e.g., `severity_id: 0` for "Unknown"). Use
   sparingly — defaults that don't reflect reality are worse than missing.
3. Demote the transform: if the source data fundamentally cannot satisfy a
   required field, the transform may be targeting the wrong class. Re-check
   the class choice using `lookup-ocsf-class.sh --list` and the source's
   semantics.

Never silence the validator by adding the missing key to the allowlist.

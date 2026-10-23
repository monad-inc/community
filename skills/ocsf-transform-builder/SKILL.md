---
name: ocsf-transform-builder
description: Build and validate jq-based data transformations that map vendor-specific records into OCSF (Open Cybersecurity Schema Framework) events, packaged for contribution to the monad-inc/community-transformations repository. Use when asked to write, edit, audit, or validate a transform targeting OCSF, for example "build a transform", "map X to OCSF", "validate this transform", "check the okta transform", or "OCSF v1.4 conformance".
---

# ocsf-transform-builder

Builds transforms for the
[`monad-inc/community-transformations`](https://github.com/monad-inc/community-transformations)
repository. Each transform is a YAML file containing a jq program that maps one
input record into one OCSF event. Merged transforms sync to the Monad platform,
where any Monad user can add them to a pipeline.

The clone, attribution, input-ID, sample-data, and pull-request steps are shared
with the ECS and CEF builders and live in
[references/contributing-workflow.md](references/contributing-workflow.md).
Read it before starting; its rules are part of this skill.

## Requirements

- `jq` and `yq` (mikefarah, v4) on `PATH`, plus `bash` and `git`.
- `curl` and network access for the official OCSF validator API
  (`schema.ocsf.io`) and for installing additional schema versions.
- Optional: the GitHub CLI (`gh`) for forking and opening the pull request.
- Optional: the Monad MCP server (`https://app.monad.com/mcp`) for live sample
  data and pipeline testing. Without it, use user-provided or synthetic records.

## When to use this skill

- Author a new OCSF transform for a vendor and data type.
- Validate or audit an existing transform.
- Migrate a transform between OCSF versions.
- Answer "does this transform produce valid OCSF?"

Not for unrelated jq questions or other output formats. ECS targets belong to
`ecs-transform-builder` and CEF/ArcSight targets to `cef-transform-builder`
(the `ecs/`, `cef/`, and `utility/cef/` trees in the repo). A request like
"build a transform" with no schema named lands here.

## OCSF versions

Each OCSF version gets its own subtree in the repo (`ocsf/v<X.Y.Z>/`). If the
user names a version, use it. Otherwise confirm the target before writing
files, and **ask whether older versions should also be built** rather than
producing them automatically.

| Version | Classes | Notes |
|---------|---------|-------|
| 1.0.0 | 36 | Initial GA. 6 categories: System Activity, Findings, IAM, Network, Discovery, Application. |
| 1.1.0 | 50 | Historically the most common version in the repo. |
| 1.2.0 | 65 | Adds the Remediation category. |
| 1.3.0 | 72 | Extended class coverage. |
| 1.4.0 | 79 | Extended class coverage. |
| 1.5.0 | 81 | Adds the Unmanned Systems category. |
| 1.6.0–1.8.0 | — | GenAI/agent constructs arrive: the `ai_operation` profile and the `ai_model` / `message_context` objects. |
| 1.9.0 | 87 | Latest stable at the time of writing and the `schema.ocsf.io` default. Adds Peripheral Activity (1010), Device Power State Activity (1011), Clipboard Activity (1012), IAM Analysis Finding (2008), User Management (3007), Role Management (3008). |

Check `https://schema.ocsf.io/api/versions` for anything newer.

### Schema files

The skill ships the **1.9.0** schema at `references/ocsf/v1.9.0/`
(`schema.json` plus a compact `classes-index.json`). Install any other version
before working with it:

```bash
scripts/fetch-ocsf-schema.sh 1.4.0      # installs references/ocsf/v1.4.0/
scripts/fetch-ocsf-schema.sh --list     # versions the server offers
```

The lookup and validation scripts print this command when a version is missing.
The fetch script assembles the schema from the `schema.ocsf.io` `/api`
endpoints and applies the normalizations the scripts depend on (see the
comments at the top of the script). Set `OCSF_SCHEMA_URL` to use a locally-run
[ocsf-server](https://github.com/ocsf/ocsf-server) instead.

If a construct isn't in an installed schema, check the live schema:
`https://schema.ocsf.io/<version>/api/classes`, `…/api/objects/<name>`,
`…/api/profiles/<name>`.

### `cloud` and `osint` are optional profile attributes

They belong to the `cloud` and `osint` profiles, not the base class. Two traps:

- On 1.8.0 and later, the live `/<ver>/api/classes/<name>` endpoint reports them
  as `requirement: required, profile: null`. That is a quirk of the browse API.
  `fetch-ocsf-schema.sh` restores the profile, so `validate-against-ocsf.sh`
  does not demand them. Emit them only when the source truly carries cloud or
  OSINT data.
- The hosted validator rejects a `cloud`/`osint` attribute ("not defined in
  class …") unless the event declares the profile. If you emit them, set
  `metadata.profiles: ["cloud","osint"]` and pass `cloud,osint` as the profiles
  argument to `validate-against-ocsf.sh`.

### The hosted validator checks the server's default version

`validate-ocsf-api.sh` validates against whatever version `schema.ocsf.io`
currently defaults to (1.9.0 at the time of writing), not the version you
target. It is authoritative when your target equals that default. For any other
version it adds `version_earlier` and newer-schema warnings, and the
version-pinned `validate-against-ocsf.sh` is the authority.

## Workflow: writing a new transform

1. **Set up the clone.** `REPO="$(scripts/community-repo.sh setup)"`. Use
   `$REPO` as the root for every path below.
2. **Get sample records** per
   [contributing-workflow.md § Sample data](references/contributing-workflow.md#sample-data),
   and identify the entity: authentication event, vulnerability finding,
   device inventory snapshot, API call, and so on.
3. **Verify the input connector ID** per
   [contributing-workflow.md § Input connector IDs](references/contributing-workflow.md#input-connector-ids-must-be-real).
4. **Choose the OCSF class.** Browse with
   `scripts/lookup-ocsf-class.sh <version> --list`, then inspect a candidate
   with `scripts/lookup-ocsf-class.sh <version> <class_name>`. Confirm the
   choice with the user.
5. **Check for an existing transform** in `$REPO/ocsf/v<version>/<vendor>/`. If
   one exists the work is an update: keep `author` and append to
   `contributors`.
6. **Draft the YAML** from [templates/ocsf-transform.yaml](templates/ocsf-transform.yaml)
   and save it to `$REPO/ocsf/v<version>/<vendor>/<input-slug>.yaml`. Use the
   [standard jq helpers](#standard-jq-helpers) for time, severity captions, IP
   guards, JSON strings, and pruning; paste them with
   `scripts/jq-helpers.sh show <name>...`.
7. **Run and validate** (see [Validation](#validation)). The version-pinned
   local check is always required. The official validator API is required when
   targeting the hosted validator's default version and optional otherwise.
   Iterate until the applicable validators report no errors, and until
   `scripts/jq-helpers.sh check <transform>` reports no drift.
8. **Test at least three records** derived from the samples: success, failure,
   and missing optional fields. Required OCSF fields must stay populated in
   every case.
9. **Open the pull request** per
   [contributing-workflow.md § Opening the pull request](references/contributing-workflow.md#opening-the-pull-request).

## Workflow: validating or auditing an existing transform

1. Set up the clone (unless the user points at a file elsewhere) and read the
   target YAML.
2. Read the OCSF version from `tags:` or the path, and install that schema if
   it isn't present.
3. Identify the class from the jq query's hard-coded `class_uid` (ask the user
   if it isn't obvious).
4. Get a sample record per
   [contributing-workflow.md § Sample data](references/contributing-workflow.md#sample-data).
5. Run `scripts/validate-against-ocsf.sh <transform> <input> <version> <class>`.
   If the transform targets the hosted validator's default version, also run
   `scripts/validate-ocsf-api.sh <transform> <input>`.
6. Report findings in the structure from
   [references/validation-workflow.md](references/validation-workflow.md):
   missing required, missing recommended, unknown top-level keys, and the
   official validator's errors and warnings.
   Run `scripts/jq-helpers.sh check <transform>` and report drifted or
   unmarked helper definitions too.
7. Propose a fix for each finding. Show the diff and ask before saving; never
   rewrite silently.

## Validation

All scripts live in `scripts/`. Full procedure and triage guidance:
[references/validation-workflow.md](references/validation-workflow.md).

- **`run-transform.sh <transform.yaml> <input.json> [--slurp]`** runs every jq
  operation in `config.operations` against the input and prints the result.
  Use `--slurp` only when the transform expects a whole JSON array as one value.
- **`validate-against-ocsf.sh <transform.yaml> <input.json> <version> <class> [profiles]`**
  is the offline, version-pinned structural check: required and recommended
  attributes of the class, plus unknown top-level keys. Exits non-zero on
  missing required attributes. Profiles default to none; pass a comma-separated
  list or `all`.
- **`validate-ocsf-api.sh <transform.yaml> <input.json> [--slurp]`** POSTs the
  output to the official OCSF validator (`/api/v2/validate`, or
  `/api/v2/validate_bundle` for multiple events) and exits non-zero on any
  error. It catches what the local check can't: `at_least_one` constraints,
  enum values, types, `type_uid`/`class_uid`/`activity_id` consistency, and
  deprecations. Set `OCSF_VALIDATOR_URL` to use a locally-run server pinned to
  a specific version.
- **`lookup-ocsf-class.sh <version> <class_or_uid> [--full] | <version> --list`**
  prints a class's required and recommended attributes, split into base and
  per-profile groups.
- **`lookup-ocsf-object.sh <version> <object_name> [--full] | <version> --list`**
  does the same for nested objects (`user`, `device`, `metadata`,
  `finding_info`, and so on).
- **`fetch-ocsf-schema.sh <version> [--force] | --list`** installs another
  schema version.
- **`jq-helpers.sh list | show <name>... | check <yaml>... | sync <yaml>... | test [yaml]`**
  manages the [standard jq helpers](#standard-jq-helpers): print them for
  pasting, detect and fix drift in transforms, and run their fixtures under jq
  and gojq. `validate-against-ocsf.sh` runs `check` and prints its findings.

## Authoring rules

The repo's reviewers enforce these; a pull request that breaks them will be
sent back. Full format details:
[references/transform-file-format.md](references/transform-file-format.md).

- Path: `ocsf/v<version>/<vendor>/<input-slug>.yaml`. An extra product-line
  directory is allowed (see `ocsf/v1.1.0/crowdstrike/edr/`).
- The filename stem matches the value in `inputs:`, and that value is a real
  Monad input connector ID.
- `name` ends with ` to OCSF v<X.Y.Z>`, for example
  `"CrowdStrike Vulnerability Findings to OCSF v1.4.0"`. Without the suffix,
  transforms for the same input at different versions collide under one
  display name in the Monad UI.
- `description` embeds the version too, for example
  `"Transforms ... into the OCSF v1.4.0 Vulnerability Finding class"`.
- Tags include the version (`v1.4.0`), `ocsf`, and the vendor slug.
- `author` and `contributors` follow
  [contributing-workflow.md § Attribution](references/contributing-workflow.md#attribution).

## Standard jq helpers

These helpers are shared by the OCSF, ECS, and CEF transform builders, and this
section is identical in all three `SKILL.md` files. Most apply to every format;
`sev_caption`, `sev_to_id`, `status_to_id`, and `status_caption` are OCSF
enums, `cef_sev` is CEF, and `present_unique` is mainly for ECS. The definitions below are the
**only** permitted implementations of these names, so every generated transform
handles a value the same way regardless of the source.

| Helper | Use |
|---|---|
| `to_epoch_ms($ts)` | Epoch **milliseconds** from epoch s/ms/us/ns numbers or strings, protobuf `{seconds,nanos}`, MongoDB `$date`, ISO 8601 / RFC 3339 with any offset, RFC 1123/2822/850, CEF/ArcSight `Oct 20 2026 13:04:05`, Unix `date` / ANSIC / JavaScript dates, Apache CLF, and .NET `/Date(…)/`. No zone means UTC. Returns `null` (never an error) for empty or unparseable input, unknown zone abbreviations, syslog dates without a year, ambiguous `10/20/2026` dates, and 12-hour clocks. OCSF `timestamp_t` fields and CEF time keys. |
| `to_iso($ts)` | UTC ISO 8601 with milliseconds (`2026-10-20T13:04:05.123Z`) from anything `to_epoch_ms` accepts; `null` otherwise. ECS `@timestamp` and other `date` fields. Requires `to_epoch_ms`. |
| `sev_caption($id)` | OCSF `severity` caption for a `severity_id` (0–6, 99); `null` outside the enum. For 99 (Other), prefer the source's own label. |
| `sev_to_id($s)` | OCSF `severity_id` from a source label (`info`, `low`, `moderate`, `high`, `critical`, `fatal`, …, case-insensitive) or a 0–10 score (CVSS ranges). `0` for empty or `unknown`, `99` for an unrecognized label (keep the source label in `severity`). Map vendor-specific numeric scales (such as 1–5) explicitly. |
| `status_to_id($s; $kind)` | OCSF `status_id` from a source status word or boolean. `$kind` is `"event"` (activity classes: Success/Failure), `"finding"` (finding classes, 1.1.0+: New/In Progress/Suppressed/Resolved), or `"incident"` (Incident Finding: New/In Progress/On Hold/Resolved/Closed). `0` for empty or `unknown`, `99` otherwise. Finding Archived (5) and Deleted (6) exist only in newer versions, so set them explicitly. |
| `status_caption($id; $kind)` | OCSF `status` caption for a `status_id`, same `$kind` values; `null` outside the enum. |
| `cef_sev($s)` | CEF severity (0–10) from a label or a 0–10 number, in the CEF spec's buckets (`info` 1, `low` 3, `medium` 5, `high` 7, `critical` 9, `fatal` 10). `null` for empty, `unknown`, or unrecognized input; map vendor scales explicitly. |
| `truthy($v)` | `true` for a real boolean `true` or the string `"true"` in any case. |
| `is_ip($s)` | `true` only for a valid IPv4 or IPv6 address (no port, zone, or CIDR). Guard every `ip`-typed field: `(if is_ip($v) then $v else null end)`. |
| `json_str($v)` | JSON string of a nested value; strings pass through; `null`, `{}`, `[]` give `null`. For vendor blobs that would explode a downstream index mapping. |
| `present_unique($arr)` | Sorted unique values with `null` and `""` removed, flattening one level of nested arrays; for ECS `related.*`. `[]` when empty. |
| `prune` | Recursively drops `null`, `{}`, and `[]`; keeps `""`, `0`, `false`. Apply once, at the end. |
| `prune_blank` | `prune` that also drops `""`. Use instead of `prune` when the source sends empty strings for absent values. |

Rules:

1. **Copy, don't write.** Get the definitions with
   `scripts/jq-helpers.sh show <name>...`, which prints them with their marker
   comments and adds dependencies (`to_iso` pulls in `to_epoch_ms`) in the
   right order. Paste them at the top of the jq query, before any use, and
   include only the helpers the transform calls.
2. **Never edit an embedded copy, and never define these names any other way.**
   Need different behavior? Change this section (see 4) or write a helper with
   a different name.
3. **Keep the markers.** `# >>> helper: <name>` / `# <<< helper: <name>` let
   `scripts/jq-helpers.sh check <transform.yaml>...` detect drift and
   `scripts/jq-helpers.sh sync <transform.yaml>...` rewrite embedded copies from
   this section. The validators run `check` and warn on drift or on an unmarked
   definition of one of these names.
4. **Changing a helper:** edit the block below identically in all three skills'
   `SKILL.md`, add or update cases in `references/jq-helper-fixtures.json`, run
   `scripts/jq-helpers.sh test` (jq, and gojq, the jq implementation Monad uses,
   when installed), then run `scripts/jq-helpers.sh sync` over the repo's
   transforms (`find "$REPO" -name '*.yaml'`), review the diff, and open one pull
   request for the propagation.

```jq
# >>> helper: to_epoch_ms
# Epoch MILLISECONDS from any common timestamp form; null if empty or unparseable.
def to_epoch_ms($ts):
  def _n: if . == null then null else tonumber end;
  def _num_ms($n):
    if   $n >= 1e17 then ($n / 1000000 | floor)
    elif $n >= 1e14 then ($n / 1000 | floor)
    elif $n >= 1e11 then ($n | floor)
    else ($n * 1000 + 0.001 | floor) end;
  def _digits_ms($d):
    ($d | ltrimstr("-") | length) as $l
    | if   $l >= 18 then ($d[0:-6] | tonumber)
      elif $l >= 15 then ($d[0:-3] | tonumber)
      elif $l >= 12 then ($d | tonumber)
      else ($d | tonumber) * 1000 end;
  def _frac_ms($f): if $f == null then 0 else (($f + "000")[0:3] | tonumber) end;
  def _mon($m):
    if $m == null then null
    else {"JAN":1,"FEB":2,"MAR":3,"APR":4,"MAY":5,"JUN":6,
          "JUL":7,"AUG":8,"SEP":9,"OCT":10,"NOV":11,"DEC":12}[$m[0:3]] end;
  def _zone($z):
    if $z == null or $z == "" then 0
    else
      ($z | if test("^(UTC|GMT|UT)[+-]") then sub("^(UTC|GMT|UT)"; "") else . end) as $z
      | if ($z | test("^[+-][0-9]{1,2}(:?[0-9]{2})?$")) then
          ($z | capture("^(?<sg>[+-])(?<h>[0-9]{1,2}):?(?<m>[0-9]{2})?$")) as $o
          | (if $o.sg == "-" then -1 else 1 end)
            * (($o.h | tonumber) * 3600 + (($o.m // "0") | tonumber) * 60)
        else
          {"Z":0,"UTC":0,"GMT":0,"UT":0,"EST":-18000,"EDT":-14400,"CST":-21600,
           "CDT":-18000,"MST":-25200,"MDT":-21600,"PST":-28800,"PDT":-25200}[$z]
        end
    end;
  def _ms($c):
    ($c.y | tonumber | if . < 100 then (if . < 70 then . + 2000 else . + 1900 end) else . end) as $y
    | ($c.mo | _n) as $mo
    | ($c.d | tonumber) as $d
    | (($c.h // "0") | tonumber) as $h
    | (($c.mi // "0") | tonumber) as $mi
    | (($c.s // "0") | tonumber) as $s
    | _zone($c.z) as $off
    | if $mo == null or $off == null or $mo < 1 or $mo > 12 or $d < 1 or $d > 31
         or $h > 23 or $mi > 59 or $s > 60 then null
      else
        ($y - (if $mo <= 2 then 1 else 0 end)) as $yy
        | ($yy / 400 | floor) as $era
        | ($yy - $era * 400) as $yoe
        | (((153 * ($mo + (if $mo > 2 then -3 else 9 end)) + 2) / 5 | floor) + $d - 1) as $doy
        | ($yoe * 365 + ($yoe / 4 | floor) - ($yoe / 100 | floor) + $doy) as $doe
        | ($era * 146097 + $doe - 719468) as $days
        | ($days * 86400 + $h * 3600 + $mi * 60 + $s - $off) * 1000 + _frac_ms($c.f)
      end;
  def _str($raw):
    ($raw | ascii_upcase | sub("\\s*\\([^)]*\\)\\s*$"; "") | sub("^\\s+"; "") | sub("\\s+$"; "")) as $s
    | "(?<z>Z|(?:UTC|GMT|UT)?[+-][0-9]{1,2}(?::?[0-9]{2})?|[A-Z]{1,5})" as $Z
    | "(?<h>[0-9]{1,2}):(?<mi>[0-9]{2})(?::(?<s>[0-9]{2}))?(?:[.,](?<f>[0-9]+))?" as $T
    | if $s == "" then null
      elif ($s | test("^-?[0-9]+$")) then _digits_ms($s)
      elif ($s | test("^[0-9]+\\.[0-9]+$")) then
        ($s | split(".")) as $p
        | if ($p[0] | length) <= 11 then _digits_ms($p[0]) + _frac_ms($p[1])
          else _digits_ms($p[0]) end
      elif ($s | test("^/DATE\\(-?[0-9]+([+-][0-9]{4})?\\)/$")) then
        ($s | capture("(?<ms>-?[0-9]+)").ms | tonumber)
      else
        first(
          ($s | capture("^(?<y>[0-9]{4})[-/](?<mo>[0-9]{1,2})[-/](?<d>[0-9]{1,2})(?:[T ]+" + $T + ")?\\s*" + $Z + "?(?:\\s+[A-Z]{2,5})?$") | _ms(.)),
          ($s | capture("^(?<y>[0-9]{4})(?<mo>[0-9]{2})(?<d>[0-9]{2})T(?<h>[0-9]{2})(?<mi>[0-9]{2})(?<s>[0-9]{2})(?:[.,](?<f>[0-9]+))?" + $Z + "?$") | _ms(.)),
          ($s | capture("^(?:[A-Z]+,?\\s+)?(?<d>[0-9]{1,2})[ -](?<mon>[A-Z]{3,9})[ -](?<y>[0-9]{2,4})\\s+" + $T + "\\s*" + $Z + "?$") | .mo = _mon(.mon) | _ms(.)),
          ($s | capture("^(?:[A-Z]+,?\\s+)?(?<mon>[A-Z]{3,9})\\.?\\s+(?<d>[0-9]{1,2}),?\\s+(?<y>[0-9]{4})(?:,?\\s+" + $T + ")?\\s*" + $Z + "?$") | .mo = _mon(.mon) | _ms(.)),
          ($s | capture("^(?:[A-Z]+\\s+)?(?<mon>[A-Z]{3,9})\\s+(?<d>[0-9]{1,2})\\s+" + $T + "\\s+(?:" + $Z + "\\s+)?(?<y>[0-9]{4})$") | .mo = _mon(.mon) | _ms(.)),
          ($s | capture("^(?<d>[0-9]{1,2})/(?<mon>[A-Z]{3})/(?<y>[0-9]{4}):" + $T + "\\s*" + $Z + "?$") | .mo = _mon(.mon) | _ms(.))
        ) // null
      end;
  if $ts == null then null
  elif ($ts | type) == "number" then _num_ms($ts)
  elif ($ts | type) == "string" then _str($ts)
  elif ($ts | type) == "object" then
    if   $ts["$date"] != null then to_epoch_ms($ts["$date"])
    elif $ts["$numberLong"] != null then to_epoch_ms($ts["$numberLong"])
    elif $ts.seconds != null then
      ($ts.seconds | tostring | tonumber) * 1000
      + ((($ts.nanos // 0) | tostring | tonumber) / 1000000 | floor)
    else null end
  else null end;
# <<< helper: to_epoch_ms

# >>> helper: to_iso
# requires: to_epoch_ms
# UTC ISO 8601 with milliseconds ("2026-10-20T13:04:05.123Z") from any form
# to_epoch_ms accepts; null if empty or unparseable.
def to_iso($ts):
  to_epoch_ms($ts) as $ms
  | if $ms == null then null
    else
      ($ms / 1000 | floor) as $s
      | ($s | todate)[0:19] + "." + ("00" + (($ms - $s * 1000) | tostring))[-3:] + "Z"
    end;
# <<< helper: to_iso

# >>> helper: sev_caption
# OCSF severity caption for a severity_id (identical in OCSF 1.0.0-1.9.0);
# null for ids outside the enum. For 99 (Other), prefer the source's own label.
def sev_caption($id):
  {"0":"Unknown","1":"Informational","2":"Low","3":"Medium","4":"High",
   "5":"Critical","6":"Fatal","99":"Other"}[$id | tostring];
# <<< helper: sev_caption

# >>> helper: sev_to_id
# OCSF severity_id from a source severity: a label (case-insensitive) or a
# 0-10 score using the CVSS qualitative ranges (0 None -> 1, <4 Low, <7 Medium,
# <9 High, else Critical). 0 for null/empty/"unknown"; 99 for an unrecognized
# label (then keep the source label in `severity`). Map vendor-specific
# numeric scales (e.g. 1-5) explicitly instead.
def sev_to_id($s):
  def _score($n):
    if $n < 0 or $n > 10 then 99
    elif $n == 0 then 1 elif $n < 4 then 2 elif $n < 7 then 3 elif $n < 9 then 4
    else 5 end;
  if $s == null then 0
  elif ($s | type) == "number" then _score($s)
  elif ($s | type) != "string" then 99
  else
    ($s | ascii_downcase | sub("^\\s+"; "") | sub("\\s+$"; "")) as $l
    | if $l == "" or $l == "unknown" or $l == "unspecified" or $l == "untriaged" then 0
      elif ($l | test("^[0-9]+(\\.[0-9]+)?$")) then _score($l | tonumber)
      else
        {"info":1,"informational":1,"information":1,"none":1,"notice":1,"debug":1,"trace":1,
         "low":2,"minor":2,
         "medium":3,"moderate":3,"middle":3,"warning":3,"warn":3,
         "high":4,"major":4,"important":4,"error":4,
         "critical":5,"crit":5,"severe":5,"alert":5,
         "fatal":6,"emergency":6,"emerg":6}[$l] // 99
      end
  end;
# <<< helper: sev_to_id

# >>> helper: status_to_id
# OCSF status_id from a source status word (case-insensitive; "_"/"-" read as
# spaces) or boolean. $kind picks the class's enum:
#   "event"    - activity classes: 1 Success, 2 Failure
#   "finding"  - finding classes (OCSF 1.1.0+): 1 New, 2 In Progress,
#                3 Suppressed, 4 Resolved. Archived (5) and Deleted (6) exist
#                only in newer versions, so they map to 99; set them explicitly
#                when the target version has them.
#   "incident" - Incident Finding: 1 New, 2 In Progress, 3 On Hold,
#                4 Resolved, 5 Closed
# 0 for null/empty/"unknown"; 99 for unrecognized values; null for an unknown $kind.
def status_to_id($s; $kind):
  ($s | if type == "string" then ascii_downcase | gsub("[\\s_-]+"; " ") | sub("^ "; "") | sub(" $"; "")
        elif type == "boolean" then tostring else null end) as $l
  | {"event": {"success":1,"succeeded":1,"successful":1,"ok":1,"pass":1,"passed":1,
               "allow":1,"allowed":1,"accepted":1,"complete":1,"completed":1,"true":1,
               "failure":2,"failed":2,"fail":2,"error":2,"deny":2,"denied":2,
               "blocked":2,"rejected":2,"unsuccessful":2,"false":2},
     "finding": {"new":1,"open":1,"opened":1,"active":1,"unresolved":1,"reopened":1,"detected":1,
                 "in progress":2,"investigating":2,"triaged":2,"acknowledged":2,"assigned":2,
                 "suppressed":3,"ignored":3,"muted":3,"dismissed":3,"false positive":3,
                 "risk accepted":3,"accepted risk":3,"snoozed":3,"exception":3,
                 "resolved":4,"fixed":4,"remediated":4,"closed":4,"mitigated":4},
     "incident": {"new":1,"open":1,"opened":1,"triggered":1,"active":1,
                  "in progress":2,"investigating":2,"acknowledged":2,"assigned":2,"mitigating":2,
                  "on hold":3,"paused":3,"snoozed":3,"pending":3,
                  "resolved":4,"mitigated":4,"fixed":4,
                  "closed":5}}[$kind] as $map
  | if $map == null then null
    elif $l == null or $l == "" or $l == "unknown" then 0
    else ($map[$l] // 99) end;
# <<< helper: status_to_id

# >>> helper: status_caption
# OCSF status caption for a status_id, using the same $kind as status_to_id
# ("event" also covers the remediation classes' extra values). null outside
# the enum or for an unknown $kind.
def status_caption($id; $kind):
  {"event": {"0":"Unknown","1":"Success","2":"Failure","3":"Does Not Exist","4":"Partial",
             "5":"Unsupported","6":"Error","99":"Other"},
   "finding": {"0":"Unknown","1":"New","2":"In Progress","3":"Suppressed","4":"Resolved",
               "5":"Archived","6":"Deleted","99":"Other"},
   "incident": {"0":"Unknown","1":"New","2":"In Progress","3":"On Hold","4":"Resolved",
                "5":"Closed","99":"Other"}}[$kind][$id | tostring];
# <<< helper: status_caption

# >>> helper: cef_sev
# CEF severity (integer 0-10) from a label (case-insensitive) or a 0-10
# number (floored and clamped). Buckets follow the CEF spec: Low 0-3,
# Medium 4-6, High 7-8, Very-High 9-10. null for null, empty, "unknown", or
# unrecognized input; map vendor-specific scales explicitly.
def cef_sev($s):
  if $s == null then null
  elif ($s | type) == "number" then ([[($s | floor), 0] | max, 10] | min)
  elif ($s | type) != "string" then null
  else
    ($s | ascii_downcase | sub("^\\s+"; "") | sub("\\s+$"; "")) as $l
    | if ($l | test("^[0-9]+(\\.[0-9]+)?$")) then cef_sev($l | tonumber)
      else
        {"none":0,"debug":0,"trace":0,"info":1,"informational":1,"information":1,"notice":1,
         "low":3,"minor":3,
         "medium":5,"moderate":5,"middle":5,"warning":5,"warn":5,
         "high":7,"major":7,"important":7,"error":7,
         "very-high":9,"very high":9,"critical":9,"crit":9,"severe":9,"alert":9,
         "fatal":10,"emergency":10,"emerg":10}[$l]
      end
  end;
# <<< helper: cef_sev

# >>> helper: truthy
# True for a real boolean true or the string "true" (any case). Sources send
# both for the same field, and `== "true"` silently misses a boolean.
def truthy($v):
  ($v == true) or (($v | type) == "string" and ($v | ascii_downcase) == "true");
# <<< helper: truthy

# >>> helper: is_ip
# True only for a valid IPv4 or IPv6 address string (no port, no zone, no
# CIDR). Guard every ip-typed field with it.
def is_ip($s):
  def _v4: test("^((25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])[.]){3}(25[0-5]|2[0-4][0-9]|1[0-9]{2}|[1-9]?[0-9])$");
  def _v6:
    if (contains(":") and test("^[0-9A-Fa-f:.]+$")) | not then false
    else
      split("::") as $p
      | if ($p | length) > 2 then false
        else
          [$p[] | select(. != "") | split(":")[]] as $g
          | (($g | length) > 0 and ($g[-1] | contains("."))) as $tail4
          | (if $tail4 then $g[0:-1] else $g end) as $hex
          | (($hex | length) + (if $tail4 then 2 else 0 end)) as $n
          | (if $tail4 then ($g[-1] | _v4) else true end)
            and all($hex[]; test("^[0-9A-Fa-f]{1,4}$"))
            and (if ($p | length) == 2 then $n <= 7 else $n == 8 end)
        end
    end;
  ($s | type) == "string" and ($s | _v4 or _v6);
# <<< helper: is_ip

# >>> helper: json_str
# Serialize a nested value to a JSON string (to keep vendor blobs from
# exploding a downstream index mapping). Strings pass through unchanged;
# null, {} and [] give null.
def json_str($v):
  if $v == null or $v == {} or $v == [] then null
  elif ($v | type) == "string" then $v
  else ($v | tojson) end;
# <<< helper: json_str

# >>> helper: present_unique
# Sorted unique values, dropping null and "", from an array whose items may
# themselves be arrays (flattened one level). A single scalar is treated as a
# one-item array. [] when nothing remains. For ECS related.* fields.
def present_unique($arr):
  [ (if ($arr | type) == "array" then $arr[] elif $arr == null then empty else $arr end)
    | if type == "array" then .[] else . end
    | select(. != null and . != "") ] | unique;
# <<< helper: present_unique

# >>> helper: prune
# Recursively drop null, {} and [] from objects and arrays (bottom-up, so a
# parent emptied by pruning is dropped too). Keeps "", 0 and false.
def prune:
  walk(if type == "object" then with_entries(select(.value != null and .value != {} and .value != []))
       elif type == "array" then map(select(. != null and . != {} and . != []))
       else . end);
# <<< helper: prune

# >>> helper: prune_blank
# Like prune, but also drops empty strings (""). Keeps 0 and false.
def prune_blank:
  walk(if type == "object" then with_entries(select(.value != null and .value != "" and .value != {} and .value != []))
       elif type == "array" then map(select(. != null and . != "" and . != {} and . != []))
       else . end);
# <<< helper: prune_blank
```

## OCSF profiles

Profiles (`cloud`, `host`, `container`, `datetime`, `security_control`, …) add
required and recommended fields on top of a class. Claim a profile only if the
source data can populate its required fields. The validator ignores profile
fields unless you pass them explicitly. When in doubt, leave profiles out: a
correct base-class event is better than one that claims conformance it doesn't
have.

## Common pitfalls

- **Trailing spaces in keys** (`"ip "` instead of `"ip"`). The validator flags
  them as unknown top-level keys.
- **Invented wrapper objects** that aren't in OCSF, such as
  `authentication_info` or `user_info`. OCSF is flatter than most vendor
  formats: `auth_protocol_id` sits at the top level of an Authentication event.
- **Wrong `category_uid` / `class_uid`.** Always look the class up.
- **Missing `metadata.version`.** It must name the OCSF version (`"1.4.0"`).
- **Numbers as strings.** OCSF UIDs are integers; `tonumber` source IDs that
  arrive as strings.
- **Time in seconds.** OCSF `timestamp_t` fields (`time`, `start_time`,
  `end_time`, `created_time`, `modified_time`, `first_seen_time`,
  `last_seen_time`, `metadata.logged_time`, …) are epoch **milliseconds**.
  Convert every one with the standard `to_epoch_ms` helper. A `now` fallback
  must be `(now * 1000 | floor)`. Older transforms in the repo emitted seconds
  or hand-rolled their parsing, so don't copy time handling from them.
- **Timezone offsets.** `fromdateiso8601` only accepts a literal `Z`, so
  `+00:00` or `-06:00` timestamps error, and stripping the offset silently
  shifts the time. `to_epoch_ms` applies the offset; test at least one sample
  with a non-`Z` offset.
- **`at_least_one` and other constraints.** Classes and objects carry a
  `constraints` block separate from required fields. Known traps: `process`
  needs one of `[pid, uid, cpid]` (not `name`/`cmd_line`); `message_context`
  `[application, service]`; `user` `[account, name, uid]`; the `authentication`
  class `[service, dst_endpoint]`; `ai_model` `[name, uid]`. Only the hosted
  validator catches these.
- **`observable.name` must reference a real attribute of the class**:
  `actor.user.email_addr` only on classes with an `actor`, `api.request.uid`
  only where `api` exists. `metadata.uid` is valid everywhere. When one
  transform fans out to several classes, build observables per class.
- **`type_uid` = `class_uid` × 100 + `activity_id`.** For the Other activity
  (99) that is `…99`, for example 6003 → `600399`, not `609999`.
- **Boolean vs. string.** A field documented as `"true"`/`"false"` may arrive
  as a real boolean, and `== "true"` silently misses it. Use the standard
  `truthy`.
- **Prune empties last**, once, with the standard `prune` (or `prune_blank`
  when the source sends `""` for absent values). Confirm required fields
  survive it.
- **Severity.** Derive `severity_id` with `sev_to_id(<source severity>)` and
  the `severity` caption with `sev_caption(<severity_id>)`, except for 99
  (Other), where the source's own label is the caption. Map vendor-specific
  numeric scales explicitly.
- **Status.** `status_id` enums differ by class: activity classes use
  Success/Failure, finding classes New/In Progress/Suppressed/Resolved, and
  Incident Finding adds On Hold/Closed. Use `status_to_id(<source>; "event" |
  "finding" | "incident")` and `status_caption(<status_id>; <same kind>)`.
- **OTLP / OpenTelemetry inputs and GenAI telemetry** have their own gotchas
  (kvlist attribute decoding, int64 as string, one event per logRecord, the
  `ai_operation` profile, the identity guard). See
  [references/otlp-and-genai.md](references/otlp-and-genai.md).

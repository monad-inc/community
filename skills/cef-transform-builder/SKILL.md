---
name: cef-transform-builder
description: Build and validate jq-based data transformations that map vendor-specific records into CEF (Common Event Format / ArcSight) events, packaged for contribution to the monad-inc/community-transformations repository. Use when asked to write, edit, audit, or validate a transform targeting CEF, for example "build a CEF transform", "map X to CEF", "validate this CEF transform", "ArcSight CEF output", or "CEF:0 conformance".
---

# cef-transform-builder

Builds transforms for the
[`monad-inc/community-transformations`](https://github.com/monad-inc/community-transformations)
repository. Sibling of `ocsf-transform-builder` and `ecs-transform-builder`.

The clone, attribution, input-ID, sample-data, and pull-request steps are shared
with the OCSF and ECS builders and live in
[references/contributing-workflow.md](references/contributing-workflow.md).
Read it before starting; its rules are part of this skill.

**CEF differs from OCSF and ECS: the target is a flat, pipe-delimited string,
not a nested JSON schema**, and serialization (escaping, header assembly) is
where bugs live. So CEF uses a **two-transform chain** instead of one transform
per source:

```
[source] → [T1: <vendor> CEF mapping (per source)] → [T2: CEF Serializer (shared)] → [syslog/HTTP output]
```

- **T1** (per source) does all the *semantic* mapping and emits a normalized
  `{_cef:{…}}` intermediate. It does **no escaping**.
- **T2** is one shared transform, already in the repo at
  `utility/cef/cef-serializer.yaml` (a copy ships in this skill as
  `templates/cef-serializer.yaml`). It owns **all** serialization (escaping,
  header assembly, severity clamp) and renders `{message: "CEF:0|…"}`. Authors
  of per-source mappings never touch escaping.
- In a Monad pipeline each node has exactly one incoming edge, so every
  source→CEF chain gets its own serializer node. The sharing is at the template
  level. The extra hop is accepted in exchange for correctness and one place to
  maintain escaping.

## Requirements

- `jq` and `yq` (mikefarah, v4) on `PATH`, plus `bash` and `git`.
- Optional: the GitHub CLI (`gh`) for forking and opening the pull request.
- Optional: the Monad MCP server (`https://app.monad.com/mcp`) for live sample
  data and pipeline testing. Without it, use user-provided or synthetic records.
- **No schema server.** CEF has no hosted validator; conformance is the static
  `validate-cef.sh`. Format details: [references/cef-format.md](references/cef-format.md).

## When to use this skill

- Author or migrate a vendor→CEF transform; validate or audit an existing one.

Not for OCSF (`ocsf-transform-builder`) or ECS (`ecs-transform-builder`).

## The intermediate contract (T1 → T2)

T1 emits exactly one object under `_cef`. Values are in **final form** (correct
types, times already epoch milliseconds, custom slots paired with labels) and
unescaped.

```json
{ "_cef": {
    "vendor": "Okta", "product": "Okta System Log", "version": "",
    "signature_id": "user.session.start", "name": "User login to Okta",
    "severity": 2,
    "extension": { "rt": 1786528800000, "suser": "alice@example.com",
                   "src": "203.0.113.5", "act": "user.session.start",
                   "outcome": "SUCCESS", "cs1Label": "transactionId", "cs1": "txn-123" } } }
```

Rules:

- `vendor`, `product`, `signature_id`, and `name` are required; `version` may
  be `""`.
- `severity` is an integer **0–10**; T1 owns the mapping from the source's
  severity. Use the standard `cef_sev` for label or 0–10 sources so the same
  word gives the same number in every mapping (`critical` is always 9), and
  map vendor-specific scales explicitly.
- Every time value in `extension` is epoch milliseconds, produced by the
  standard `to_epoch_ms` helper (see [Timestamps](#timestamps)).
- Every `cs*` / `cn*` / `cfp*` / `flexString*` / `deviceCustomDate*` slot comes
  with its `…Label`.
- T2 treats `extension` as opaque, so **new source fields need no serializer
  change**.

Start from `templates/cef-mapping.yaml` (the T1 skeleton).

## CEF format essentials

Full reference: [references/cef-format.md](references/cef-format.md).

- Emit `CEF:0`. Header:
  `CEF:0|Vendor|Product|Version|SignatureID|Name|Severity|Extension`, seven
  fields, all present.
- Escaping (backslash first): header fields escape `\`→`\\` and `|`→`\|` (not
  `=`); extension values escape `\`→`\\`, `=`→`\=`, and newlines → `\n`/`\r`
  (not `|`).
- Severity is an integer 0–10. Times are epoch milliseconds.
- Prefer standard dictionary keys (`references/cef-extension-dictionary.json`,
  `scripts/lookup-cef-key.sh`); overflow to `cs*` / `cn*` / `cfp*` **with**
  labels.

**The shared serializer implements all of this. T1 mappings must never escape.**

## Timestamps

Sources deliver time in many shapes, sometimes several within one connector, so
every CEF mapping converts time with the standard `to_epoch_ms` helper (see
[Standard jq helpers](#standard-jq-helpers)) and calls it for `rt`, `start`,
`end`, `art`, and any `deviceCustomDate*` / `flexDate1` value. Never hand-roll
`fromdateiso8601`, `strptime`, or `mktime` chains: `fromdateiso8601` only
accepts a literal `Z` and errors on `+02:00`, and stripping the offset silently
shifts the time. If a source uses a form the helper returns `null` for (a
syslog date without a year, an ambiguous `10/20/2026`, a 12-hour clock),
convert it explicitly in the mapping and say so in a comment.

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

## Performance rules (T1 and T2)

Monad runs each transform as its own pipeline node that processes one record
per invocation, and scales nodes horizontally, so records from one source can
land on different replicas. **Correctness first; performance second.**

1. **Per-record purity.** No state shared across records. Never compute `cnt`
   by counting records; set it from a per-record field or omit it.
2. **One jq pass per transform.**
3. **No recursive prune.** T1 drops nulls with a shallow
   `with_entries(select(...))` on the one-level `extension` object; T2's
   `cef_ext` filters again. No `walk` or `del(..)`.
4. Bind subtrees once; prefer string builtins over regex.
5. **Small hand-off.** T1 emits only `_cef` (no `raw_data`, no passthrough),
   keeping the hop between nodes small.
6. **Guarded escaping (T2 only).** A plain `contains` check skips the regex
   engine for clean values.

## Packaging

- **T1 (per-source mapping):** `cef/v0/<vendor>/<input-slug>.yaml`. The
  filename stem is the real `inputs:` connector slug, verified per
  [contributing-workflow.md § Input connector IDs](references/contributing-workflow.md#input-connector-ids-must-be-real).
  `name` ends with ` to CEF`. `tags`: `v0`, `cef`, the vendor, the data type.
  `v0` is the CEF format marker.
- **T2 (shared serializer):** `utility/cef/cef-serializer.yaml`
  (`inputs: []`). It already exists; change it only to fix a serialization bug,
  and then update `templates/cef-serializer.yaml` here to match.
- `author` and `contributors` follow
  [contributing-workflow.md § Attribution](references/contributing-workflow.md#attribution).

## Scripts

- `scripts/run-transform.sh <t.yaml> <input.json>` runs a transform's jq on a
  record.
- `scripts/validate-cef.sh <mapping.yaml> <input.json>` runs T1, checks the
  `_cef` contract (required fields, severity range, custom-slot labels,
  epoch-ms times), renders through the serializer, and structurally validates
  the `CEF:0` string (header shape, severity, no raw newlines; warnings for
  non-standard keys and non-epoch times). `--string 'CEF:0|…'` validates a raw
  string only. Exits non-zero on errors.
- `scripts/lookup-cef-key.sh <key|--list|--custom>` looks up the CEF extension
  dictionary.
- `scripts/jq-helpers.sh list | show <name>... | check <yaml>... | sync <yaml>... | test [yaml]`
  manages the [standard jq helpers](#standard-jq-helpers): print them for
  pasting, detect and fix drift in transforms, and run their fixtures under jq
  and gojq. `validate-cef.sh` runs `check` and also warns when a mapping parses
  time without `to_epoch_ms`.

`validate-cef.sh` renders with `templates/cef-serializer.yaml`. If the repo's
`utility/cef/cef-serializer.yaml` has changed since this skill was published,
copy it over the template first so you validate against what ships.

## Workflow: writing a new transform

1. `REPO="$(scripts/community-repo.sh setup)"`.
2. Get sample records per
   [contributing-workflow.md § Sample data](references/contributing-workflow.md#sample-data)
   and verify the input connector ID.
3. Check `$REPO/cef/v0/<vendor>/` for an existing transform. If one exists, the
   work is an update.
4. From `templates/cef-mapping.yaml`, write
   `$REPO/cef/v0/<vendor>/<input-slug>.yaml`: pick Vendor and Product constants,
   a low-cardinality `signature_id`, a human-readable `name`, map the source
   severity to 0–10 with `cef_sev`, guard `src`/`dst` with `is_ip`, map fields to CEF dictionary keys (`lookup-cef-key.sh`),
   overflow to `cs*` with labels, and convert every time with `to_epoch_ms`.
   One jq pass, shallow null-drop, **no escaping**.
5. Run `validate-cef.sh <mapping.yaml> <sample.json>` until clean (no helper
   warnings), and test at least three records: success, failure, missing
   optional fields. Include at least one record whose timestamp uses a non-`Z`
   offset or a different format than the others, if the source ever sends one.
6. Run `scripts/jq-helpers.sh check <mapping.yaml>` and confirm no drift.
7. Open the pull request per
   [contributing-workflow.md § Opening the pull request](references/contributing-workflow.md#opening-the-pull-request).
   In Monad, a CEF pipeline chains T1, then the CEF Serializer, then a syslog
   output (the usual CEF transport) or an HTTP output.

## Which inputs suit a CEF transform

Map each source directly to CEF (no OCSF step in between). The fit is broad:
CEF carries any event with a vendor, product, signature, and severity. Skip
shapeless passthrough and transport inputs (generic HTTP, syslog, S3, Kafka,
warehouses, object storage, queues), metrics-only inputs, pure business or
financial records, and synthetic data generators.

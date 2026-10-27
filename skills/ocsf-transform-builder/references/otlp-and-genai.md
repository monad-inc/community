# OTLP-shaped inputs, GenAI mapping, and the identity guard

Lessons from building the `anthropic-claude-code` transform. These generalize to
any OpenTelemetry-fed connector (e.g. `openai-codex`, `monad-otel`) and any
AI/agent telemetry source.

## OTLP / OpenTelemetry connector inputs

Some connectors forward **raw OTLP**, not flat decoded records. One input
"record" is an OTLP envelope. Inspect a live sample before assuming a flat shape.

- Top-level key is `resourceLogs[]` (events/logs), `resourceMetrics[]` (metrics),
  or `resourceSpans[]` (traces).
- Logs nesting: `resourceLogs[].resource.attributes` (kvlist) →
  `scopeLogs[].scope` + `scopeLogs[].logRecords[]`; each logRecord has
  `timeUnixNano`, `observedTimeUnixNano`, `body`, and `attributes` (kvlist).
- **Attributes are kvlist arrays**, not a flat object:
  `{"key":"k","value":{"stringValue"|"intValue"|"doubleValue"|"boolValue"|"arrayValue"|"kvlistValue": …}}`.
  Per the protobuf→JSON mapping, **int64 and nanosecond timestamps are STRINGS**
  (`"26"`) — `tonumber` them. Booleans are real JSON bools.
- **Event name**: prefer `logRecord.body.stringValue` (often the full name, e.g.
  `claude_code.api_request`). An `event.name` *attribute* may be a SHORT form
  (`api_request`). Do not assume an `eventName` field exists.
- **Standard fields may live in resource attrs**: e.g. version is
  `service.version` in `resource.attributes`, not a per-record `app.version`.

Decode + fan-out skeleton (jq):

```
def av($v):
  if   $v == null            then null
  elif $v.stringValue != null then $v.stringValue
  elif $v.intValue    != null then ($v.intValue | tonumber)   # int64 is a string
  elif $v.doubleValue != null then $v.doubleValue
  elif $v.boolValue   != null then $v.boolValue
  elif $v.arrayValue  != null then ((($v.arrayValue.values) // []) | map(av(.)))
  elif $v.kvlistValue != null then (reduce ((($v.kvlistValue.values) // [])[]) as $a ({}; .[$a.key] = av($a.value)))
  else null end;
def kv($arr): reduce (($arr // [])[]) as $a ({}; .[$a.key] = av($a.value));

(.resourceLogs // [])[] as $rl
| kv($rl.resource.attributes) as $res
| ($rl.scopeLogs // [])[] as $sl
| ($sl.logRecords // [])[] as $lr
| ($res + kv($lr.attributes)) as $r      # flat attribute map for this record
| # …derive event name from $lr.body.stringValue, then emit one OCSF event…
```

- **Emit one OCSF event per `logRecord`** (multi-emit, like the crowdstrike
  `recent_logins[]` pattern).
- **Metrics envelopes produce no output** for an OCSF *event* transform:
  iterating `.resourceLogs[]` naturally yields nothing for a `resourceMetrics`
  envelope. OCSF is an event schema, not a metrics schema — route metrics to a
  metrics store, don't force them into OCSF.
- **Fan out by semantic type** so SIEM detections fire. Don't collapse
  heterogeneous activity into one `activity_id: 99 / Other` bucket. Example
  tool→class mapping: shell execution → Process Activity (1007, Launch),
  file read/write → File System Activity (1001, Read=2/Update=3/Create=1),
  web fetch/search → Network Activity (4001) or HTTP Activity (4002). Pick a
  class only when you can satisfy its required objects (e.g. 1001 needs a
  `file.name` — fall back if the path isn't in the record).

## GenAI / AI telemetry mapping

- **OCSF ≤ 1.5 has no AI class or object.** If a request references an
  "ai / genai / llm block," it is pointing at a newer version — check before
  emulating it via `enrichments`/`unmapped`.
- **OCSF 1.8.0 adds the `ai_operation` profile**, carried by **Process Activity
  (1007)** and **Datastore Activity (6005)**. It adds two objects:
  - `ai_model` — `name`, `ai_provider` (both required; constraint
    `at_least_one:[name,uid]`); plus `version`, `uid`.
  - `message_context` — `prompt_tokens`, `completion_tokens`, `total_tokens`,
    `ai_role_id` (0 Unknown / 1 User / 2 Assistant / 3 Tool / 4 Agent /
    5 Orchestrator / 6 Retriever / 99 Other), `service`, `application`
    (constraint `at_least_one:[application,service]`).
- **Declare the profile**: set `metadata.profiles: ["ai_operation"]` on events
  that populate those objects.
- **Cost/latency**: map latency to the class `duration` (ms) where present.
  Cost has **no native field** → put it in `unmapped`.

## Identity guard pattern

Events that lack identity (no user/session) should not pass silently — the
absence is itself a signal. Tag and keep the event rather than dropping it:

- add `metadata.labels: ["identity.missing"]`,
- raise the `severity_id` floor (e.g. to `3`/Medium),
- note it in `message`,
- and provide a fallback so required identity objects stay valid (e.g.
  `user.name: "unknown"` to satisfy `user.at_least_one:[account,name,uid]`).

# Data organization: pipeline layout and routing

Loaded in Phase 5b. [index-modeling.md](index-modeling.md) decides how data is
laid out **inside** a destination; this file decides how data moves **through
Monad**: how many pipelines, what each one carries, and how mixed streams are
split by type.

## How routing works (the rules every layout must respect)

From the [routing docs](https://app.monad.com/docs/routing/index):

- A pipeline is a tree: data flows forward from an input through optional
  transforms and enrichments to outputs. No loops.
- **Every node has exactly one incoming edge**, but any number of outgoing
  edges. A destination fed from two branches of one pipeline therefore needs
  one edge whose condition covers both branches (for example `or`), or the
  branches belong in separate pipelines.
- **Every outgoing edge is evaluated independently.** A record that matches
  three edges goes to three destinations. When each record should go to exactly
  one place, make the conditions mutually exclusive.
- An edge condition's root is a logical operator (`always`, `never`, `and`,
  `or`, `nor`, `xor`). Wrap a single rule in `and`. Leaf rules include
  `equals`, `equals_any`, `contains`, `starts_with`, `ends_with`,
  `matches_regex`, `key_exists`, `is_empty`, `greater_than`, `less_than`, and
  `sample`. Most leaf rules accept `not: true`. Call `list_condition_types` or
  `list_edge_condition_rules` (whichever the MCP server offers) for the current
  list and config shapes; trust it over any older names you have seen. String
  rules are case-sensitive unless you set `case_insensitive: true`.
- Name every conditional edge for where it goes ("Firewall → Splunk netfw") and
  describe which records take it and why. An unnamed edge shows up in the UI
  labelled only by its operator.

## Pattern 1: one pipeline per source (the default)

```
Okta input ──always──▶ Splunk (identity index)
CrowdStrike event stream ──always──▶ Splunk (endpoint index)
```

- **Use when:** each input carries one kind of data. That is most API-based
  inputs.
- **Why:** each pipeline can be enabled, tested, and debugged on its own, and its
  metrics show exactly one source.
- **Shared destinations are fine.** An output component can appear in many
  pipelines; create the Splunk output once per index and reuse it.

## Pattern 2: split a mixed stream with conditional edges (one pipeline)

A syslog or HTTP collector, or a bucket shared by several log types, sends many
kinds of data through one input. Split it inside one pipeline:

```
Syslog input ─▶ (optional) classify transform
   ├─ "Firewall → netfw"      matches_regex  msg ^1,[^,]*,[^,]*,(TRAFFIC|THREAT),
   ├─ "Linux auth → os_auth"  equals_any     app-name [sshd, sudo, su, CRON]
   └─ "Unmatched → archive"   nor(<the two rules above>)
```

The syslog input (`monad-syslog`) emits one record per message, shaped
`{"pri", "timestamp", "hostname", "app-name", "procid", "msg"}`, with the
message body in `msg`. Other collectors have their own shape; sample one
before writing conditions (see [iterative-build.md](iterative-build.md)).

- **Route on raw fields when you can.** If a field already tells the types apart
  (an app name, a log type, a prefix), put the rule straight on the edge. You
  don't need a transform.
- **Classify once when you can't.** If recognizing a type needs parsing, add one
  transform that sets a field such as `data_type`, then route with
  `equals_any data_type [...]`. Keep the rules in one place so they can't
  disagree.
- **Always add a catch-all.** One edge with `nor` over every type rule sends
  anything unrecognized to an archive, so nothing is silently dropped and a new
  log format shows up instead of disappearing. Skip it only if the user chose
  `unmatched: drop`, or if an `always` archive edge already exists on that node
  (for example from `cold-storage-archive`).
- **Use when:** the types share the same processing needs, or need only light
  per-type work on each branch. Branches can have their own transforms before
  their outputs.

## Pattern 3: intake pipeline feeding per-type pipelines

```
INTAKE: Syslog input ─▶ classify
   ├─ "Firewall"   ─▶ HTTP output ─▶ [FIREWALL pipeline: HTTP input ─▶ parse ─▶ enrich ─▶ outputs]
   ├─ "Linux auth" ─▶ HTTP output ─▶ [LINUX AUTH pipeline: …]
   └─ "Unmatched"  ─▶ archive
```

- **Use when:** each data type needs substantial processing of its own (parsing,
  enrichment, tiering to several destinations), or different teams own
  different types and need to change their pipeline without touching the rest.
- **Costs:** the hop leaves Monad and comes back in through an HTTP input, so
  data is counted as new ingest at each downstream pipeline, and every HTTP
  output needs an organization API key stored as a secret. Raise both with the
  user before choosing this pattern, and prefer pattern 2 when it would do.

## Pattern 4: tiering by value (hot / warm / cold)

Route by how much a record matters, not by what type it is:

```
… ─▶ score transform (sets tier)
   ├─ "Hot → SIEM"          equals tier hot
   ├─ "Warm → data lake"    equals tier warm
   └─ "Cold → archive"      equals tier cold
```

- Keeps expensive destinations for the records analysts actually search.
- The tiers must be mutually exclusive (see "evaluated independently" above),
  and every record must get a tier, or it is dropped. Give the score transform a
  default tier.
- Combines with patterns 2 and 3: split by type first, then tier within each
  type.

## Choosing

| Situation | Pattern |
|---|---|
| API input that carries one kind of data | 1 |
| Collector or bucket with a few types, similar processing | 2 |
| Collector with types that each need heavy, separate processing or separate owners | 3 |
| Large volume where only some records are worth SIEM cost | 4, on top of 1–3 |

Record the decision in `pipeline_layout` and show every pipeline and named edge
in the Phase 7 plan.

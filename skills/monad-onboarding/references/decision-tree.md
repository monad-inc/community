# Onboarding decision tree (the spine)

This is the backbone of the flow. Everything that varies by the user's choices
is delegated to a **module** listed in a `_registry.yaml` and loaded only when
needed. To add a capability, add a module; don't edit this file (see
[extending.md](extending.md)).

Throughout: never request real credentials. Every secret field becomes a
placeholder secret with the value `REPLACE_ME`. Tell the user to set real values
in the Monad UI under Settings → Secrets before enabling pipelines.

---

## Phase 0: Mode

- If the user supplied an **intake document**, run
  `python3 ../scripts/validate-intake.py <file>` (or check it by hand against
  [intake.schema.json](intake.schema.json)). Fix or ask about every error it
  reports, load the answers, and go to **Phase 6**.
- Otherwise run **interactively**: walk Phases 1–5, asking the questions from
  [questions.yaml](questions.yaml) in order and skipping any whose `ask_when`
  is false. Ask one question at a time.

Both modes fill one in-memory **intake object** shaped like
`intake.schema.json`. Everything after Phase 5 reads from that object.

## Phase 1: Environment basics

- Resolve `org_id` with `list_organizations`. If the user has exactly one
  organization, use it and say so. If the user wants to experiment first,
  suggest building in a sub-organization so their main workspace stays clean.
- Ask for `environment_name`, a short prefix for every component name (for
  example `prod` or `acme-poc`).

## Phase 2: Outputs (where does the data go?)

- Ask for `outputs`: one or more destinations. This is the primary fork.
- Resolve each to a connector type with `list_output_types(search: …)`.
- For each chosen type, look it up in
  [modules/outputs/_registry.yaml](modules/outputs/_registry.yaml) and load
  **only** the matching module. The module gives the type's questions, whether
  it is index-based, its settings and secrets, and build directives.
- A type with no module still works: use `get_output_type` to learn its
  settings and secrets, and ask about each required setting.

## Phase 3: Data model (only if an index-based output was chosen)

- Run only if a loaded output module says the output is index-based.
- Read [index-modeling.md](index-modeling.md) and walk the user through
  `data_model.strategy`: one index, one per source, or grouped by data
  category. Give the trade-offs and the driver questions (access, sensitivity,
  retention, volume). Inform the choice; don't make it for them.

## Phase 4: Data sources (what do they care about?)

- Ask by **category**, not by product name. Read
  [data-source-catalog.md](data-source-catalog.md).
- For each category: does the user collect it? If yes, which tools? Offer the
  catalog's common vendors.
- Resolve each tool to input types with `list_input_types(search: <vendor>)`.
  A vendor often has **several** input types (one per feed or API). When it
  does, look the vendor up in
  [modules/inputs/_registry.yaml](modules/inputs/_registry.yaml) and follow
  the module it names (usually
  [modules/inputs/multi-feed-vendors.md](modules/inputs/multi-feed-vendors.md)).
- For each selected input type, `get_input_type` gives its settings and
  secrets. Most cron-based inputs need a schedule; many support
  `use_synthetic_data`, which the build loop uses for the first test.
- If a source sends **several data types through one input** (a syslog or HTTP
  collector, a shared bucket), note it. Phase 5b decides how to split it.

## Phase 5: Pipeline layout and modifiers

### 5a. Modifiers (cross-cutting add-ons)

- Offer the modifiers in
  [modules/modifiers/_registry.yaml](modules/modifiers/_registry.yaml) whose
  `offer_when` matches the answers so far, such as archiving everything to cold
  storage or inserting a normalization transform.
- Record choices under `modifiers[]`. Each modifier module says how it changes
  the build plan in Phase 7.

### 5b. Pipeline layout

- Read [data-organization.md](data-organization.md) and decide with the user:
  - the default of one pipeline per source, or a different grouping;
  - for each mixed stream, how to split it by type (conditional edges in one
    pipeline, or an intake pipeline feeding per-type pipelines);
  - what happens to records that match no route. The default is a catch-all
    edge to an archive, so nothing is silently dropped.
- Record the decision under `pipeline_layout`.

## Phase 6: Gap-fill (intake) or review (interactive)

- Compare the intake object with `questions.yaml`. Any required answer that is
  missing, fuzzy, or ambiguous (for example "we use the CrowdStrike thing")
  becomes a **targeted question**. Never re-ask answered questions.
- Resolve fuzzy vendor names to concrete input types and confirm the mapping
  with the user when it isn't exact.

## Phase 7: Plan, confirm, build

1. **Show the plan** before creating anything. List every:
   - input (type, name, schedule, synthetic or real),
   - output (type, name, index or bucket),
   - transform and enrichment,
   - placeholder secret,
   - pipeline, with its nodes and every edge (name, condition, destination),
   - effect of each modifier (for example "+1 archive edge on each of 6
     pipelines").
2. **Get one explicit approval** for the whole plan.
3. **Build idempotently.** Before each create, list the existing components of
   that kind and reuse an exact match. Re-running the same intake must
   reconcile, not duplicate.
4. **Order:** placeholder secrets → inputs and outputs → transforms and
   enrichments → pipelines. Reference components by ID and secrets by
   reference. Create pipelines with `enabled: false`, passed explicitly.
5. **Build iteratively** per [iterative-build.md](iterative-build.md): finish
   and verify the first pipeline before building the rest. In intake mode with
   an approved plan you may build everything in one pass, but verify the first
   pipeline before reporting success.

## Phase 8: Handoff

- Summarize what was built, with names and IDs.
- List every placeholder secret and where to set its real value in the Monad UI.
- Tell the user which tests to run (`test_input_connection`,
  `test_output_connection`) once the secrets are real, and to enable each
  pipeline only after its tests pass.
- In intake mode, point out that the intake document is now the record of this
  environment: they can edit it and re-run the skill to reconcile.

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
  `python3 scripts/validate-intake.py <file>` from the skill root (or check it
  by hand against [intake.schema.json](intake.schema.json)). Fix or ask about
  every error it reports, then load the answers and walk Phases 1–5
  **without asking** what the intake answers: still load every module those
  phases call for, resolve types, and read the live schemas. Collect anything
  missing as a gap for Phase 6 instead of asking it on the spot.
- Otherwise run **interactively**: walk Phases 1–5, asking the questions from
  [questions.yaml](questions.yaml) in order and skipping any whose `ask_when`
  is false. Ask one question at a time.

Both modes fill one in-memory **intake object** shaped like
`intake.schema.json`. Everything after Phase 5 reads from that object.

## Phase 1: Environment basics

- Resolve `org_id` with `list_organizations` (pass a high `limit`; the default
  page is small). It may be a name or an ID. If the user has exactly one
  organization, use it and say so; if a name matches more than one, or none,
  stop and ask. If the user wants to experiment first,
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
- Record any source that gets its own index because of a driver under
  `data_model.options.dedicated` (see index-modeling.md). In intake mode, if
  that key is absent, assume no carve-outs and list the driver questions as an
  open item in the plan rather than blocking on them.

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
- A tool with `via: <mixed stream source>` arrives through a collector (for
  example firewall logs over syslog). Don't search for a vendor API input for
  it; it is one of that collector's types.
- For each selected input type, `get_input_type` gives its settings and
  secrets. If the schema has a `cron` setting, set a schedule; many inputs
  support `use_synthetic_data`, which the build loop uses for the first test.
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
- **Required settings are gaps too.** For every component in the plan, each
  setting the live schema marks required (from `get_input_type` /
  `get_output_type`) that neither the intake nor a module default supplies is
  a question: for example an Okta org URL, or S3 access (an IAM role ARN or
  access keys). Ask them together, in one message. If the user can't answer
  yet, use a placeholder that is obviously not real, written in capitals with
  `YOUR-` (for example `https://YOUR-ORG.okta.com`, `YOUR-BUCKET`), list it in
  the plan and the handoff as something to edit in the Monad UI, and never
  invent a real-looking value. Free-form labels that only name something on
  the Monad side (such as a CrowdStrike `app_name`) can default to
  `environment_name`; say so in the plan.

## Phase 7: Plan, confirm, build

1. **Show the plan** before creating anything. List every:
   - input (type, name, schedule, synthetic or real),
   - output (type, name, index or bucket),
   - transform and enrichment,
   - placeholder secret,
   - pipeline, with its nodes and every edge (name, condition, destination),
   - effect of each modifier (for example "+1 archive edge on each of 6
     pipelines").

   Group them as **reuse / update / create**, plus **left alone** for
   existing components the intake doesn't mention. Then add an **Open items**
   section with everything the modules defer to the plan:
   - feeds available but not selected (multi-feed-vendors.md);
   - driver questions, if `data_model.options.dedicated` was absent;
   - defaults you chose for unanswered questions, and every `YOUR-…`
     placeholder;
   - routes that can't be verified before real traffic (iterative-build.md);
   - module notes, such as "an IAM role is preferred over keys" (s3.md).
2. **Get one explicit approval** for the whole plan.
3. **Reconcile, don't duplicate.** Before each create, list the existing
   components of that kind. A component **matches** when its name and type are
   the ones the plan would create. For a match, compare its settings with the
   plan: identical → reuse; different → update it (show the change in the
   plan, and carry its secret references forward per SKILL.md rule 3). Never
   modify or delete a component the plan doesn't name. Existing secrets are
   reused as they are; their values can't be read, so list them in the handoff
   as "confirm this is set". Re-running the same intake must change nothing.
4. **Order:** placeholder secrets → inputs and outputs → transforms and
   enrichments → pipelines. Reference components by ID and secrets by
   reference. Create pipelines with `enabled: false`, passed explicitly.
5. **Names.** Prefix everything with `environment_name`:
   - inputs: `<env>-<vendor>-<feed>` (for example `acme-okta-systemlog`);
   - outputs: `<env>-<type>-<target>`, where the target is what tells
     outputs of one type apart (an index, a bucket purpose), for example
     `acme-splunk-identity`; the shared archive is `<env>-cold-archive`;
   - secrets: `<env>-<vendor or output>-<field>`;
   - pipelines: the input's name.
6. **Build iteratively** per [iterative-build.md](iterative-build.md): verify
   the first source's record shape and routing with a synthetic verification
   pipeline before building the rest. In intake mode with an approved plan you
   may build everything in one pass, but run that verification before
   reporting success.

## Phase 8: Handoff

- Summarize what was built, with names and IDs.
- List every placeholder secret and where to set its real value in the Monad UI.
- Tell the user which tests to run (`test_input_connection`,
  `test_output_connection`) once the secrets are real, and to enable each
  pipeline only after its tests pass.
- In intake mode, point out that the intake document is now the record of this
  environment: they can edit it and re-run the skill to reconcile.

---
name: monad-onboarding
description: Guided onboarding for the Monad security data pipeline platform. Turns a few high-level answers (where the data goes, which sources matter, how to organize it) into a working Monad environment of inputs, outputs, transforms, and pipelines, built through the Monad MCP server with placeholder secrets the user fills in later. Use when someone asks to "get set up in Monad", "onboard me", "bootstrap an environment", "how should I organize my data in Monad", "help me build my first pipelines", or hands over a filled-in onboarding intake document.
---

# monad-onboarding

Guides a user from "I just got a Monad account" to a set of working pipelines.
You make the judgment calls (which destinations, how to lay out indexes and
pipelines, how to route mixed data); the [Monad MCP server](https://app.monad.com/docs/mcp/index)
does the work (`list_input_types`, `create_secret`, `create_pipeline`, and so on).
This skill never calls the Monad API directly.

## Requirements

- The Monad MCP server, connected and authenticated to the user's Monad account.
  Setup per client: <https://app.monad.com/docs/mcp/index>.
- `python3` (standard library only) and `yq` (mikefarah, v4) to run the helper
  scripts. The scripts are optional: without them, check the intake by hand
  against [references/intake.schema.json](references/intake.schema.json).

## Rules that always apply

1. **Never ask for credentials.** For every secret field, create a placeholder
   secret whose value is `REPLACE_ME`, reference it, and tell the user to set the
   real value in the Monad UI (Settings → Secrets). If the user pastes a
   credential anyway, don't repeat it back, and use a placeholder instead.
2. **Plan before you build.** Show the full build plan and get one explicit
   approval before creating anything.
3. **Fetch before you create or modify.** List existing components first and reuse
   a match instead of creating a duplicate. Never build an update from memory.
4. **Create pipelines disabled.** Pass `enabled: false` explicitly to
   `create_pipeline` unless the user has already chosen otherwise. A pipeline whose
   secrets are still `REPLACE_ME` can't run.
5. **Confirm schemas live.** Before configuring any connector, call
   `get_input_type` / `get_output_type` for it. The module files here describe
   intent and judgment; the live schema is the authority on field names.
6. **Name what you route.** Every edge that carries a condition gets a `name`
   that says where it goes and a `description` that says which records take it
   and why.
7. **Load modules on demand.** Don't read the files under `references/modules/`
   up front. The decision tree says when to open each one.

## How to start

1. Read [references/decision-tree.md](references/decision-tree.md). It is the
   spine of the whole flow: phases, what to ask, and which module to load when.
2. Pick the mode:
   - **Interactive** (default when a person is answering): ask the questions in
     [references/questions.yaml](references/questions.yaml) one at a time, in
     order, skipping any whose `ask_when` is false.
   - **Intake document**: the user (or someone collecting answers for them)
     provides a filled-in intake file ([templates/intake.example.yaml](templates/intake.example.yaml)
     is the template). Validate it first:

     ```bash
     python3 scripts/validate-intake.py path/to/intake.yaml
     ```

     Then ask only about gaps and ambiguities, show the plan, get one approval,
     and build.
3. Both modes fill the same intake object, so the flow is identical once the
   answers are in.

## Organizing the data

Two decisions shape everything the skill builds. Give the user the trade-offs for
each; don't just record an answer.

- **Index layout** in index-based destinations (Splunk, Elasticsearch):
  [references/index-modeling.md](references/index-modeling.md).
- **Pipeline layout**, meaning which pipelines to build and how to route mixed
  streams, such as a syslog collector or a shared bucket that carries several
  data types: [references/data-organization.md](references/data-organization.md).

## Build in small steps

Don't build twenty pipelines and then test them all at once. Get one source
working end to end first (synthetic data, sample, verify), then add the rest in
batches. The loop, with the MCP tools for each step, is in
[references/iterative-build.md](references/iterative-build.md).

## Helper scripts

| Script | What it does |
|---|---|
| [`scripts/validate-intake.py`](scripts/validate-intake.py) | Checks an intake document (YAML or JSON) against the schema and the skill's rules: required answers, known strategies, a data model for index-based outputs, and no credentials in the file. Exit 0 = valid. |
| [`scripts/questionnaire.sh`](scripts/questionnaire.sh) | Prints the onboarding questionnaire as Markdown, generated from `references/questions.yaml`, for collecting answers ahead of time. |

## Layout

```
SKILL.md                         this file
scripts/                         helper scripts (above)
templates/intake.example.yaml    a filled-in intake to copy
references/
  decision-tree.md               the spine: phases, questions, when to load modules
  questions.yaml                 every question the flow always asks
  intake.schema.json             shape of an intake document
  data-source-catalog.md         data categories → common vendors
  index-modeling.md              index layout guidance for index-based outputs
  data-organization.md           pipeline layout and routing patterns
  iterative-build.md             the build → sample → verify loop
  extending.md                   how to add outputs, inputs, and modifiers
  modules/                       loaded on demand
    outputs/   _registry.yaml + one file per output with specific guidance
    inputs/    _registry.yaml + patterns for inputs that need extra handling
    modifiers/ _registry.yaml + cross-cutting add-ons (cold archive, reshape)
```

Anything that varies by the user's choices lives under `references/modules/` and
is listed in a `_registry.yaml`. To add a capability, add a module file and a
registry row; see [references/extending.md](references/extending.md).

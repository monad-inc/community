# Extending the onboarding skill

The skill has a **stable spine** and **pluggable modules**:

- [decision-tree.md](decision-tree.md) is the flow. It never names a specific
  output, input, or modifier; it consults a `_registry.yaml` and loads the
  matching module only when the user's choices call for it.
- Everything that varies by choice lives under `modules/` and is listed in that
  folder's `_registry.yaml`.

That keeps the agent's context small (only the chosen modules are read) and
lets the skill grow without the flow rotting.

## The rule

> Adding a capability = **one module file + one registry row.**
> You should almost never need to edit `decision-tree.md`.

If a new capability seems to need a spine change, first check whether it can be
an output module, an input module, or a modifier.

## Recipes

### Add an output type (for example Microsoft Sentinel or Sumo Logic)

1. Run `get_output_type("<type>")` and note its settings, secrets, and how it
   chooses a destination table or index.
2. Write `modules/outputs/<type>.md` with: what the output does, questions to
   merge into the flow, whether it is index-based and how the index model maps
   onto it, and build directives. Use [modules/outputs/splunk.md](modules/outputs/splunk.md)
   as the model.
3. Add a row to `modules/outputs/_registry.yaml`. Set `index_based` correctly;
   it decides whether Phase 3 runs.

### Add guidance for an input or vendor

Add a file under `modules/inputs/` (or point at an existing reference) and a
row in `modules/inputs/_registry.yaml`. Vendors with several feeds are already
covered by [modules/inputs/multi-feed-vendors.md](modules/inputs/multi-feed-vendors.md).

### Add a cross-cutting behavior

That's a modifier. Write `modules/modifiers/<id>.md` describing how it changes
the Phase 7 plan, and add a row to `modules/modifiers/_registry.yaml` with an
`offer_when`. `cold-storage-archive` and `transform-reshape` are the examples.

### Add a question the flow always asks

Add it to [questions.yaml](questions.yaml) and the matching field to
[intake.schema.json](intake.schema.json), then run `scripts/questionnaire.sh`
to check it renders. Type-specific questions don't go there; they belong in the
module and merge in when it loads.

### Change the intake schema

Additive fields need no version bump. A breaking change bumps the
`schema_version` const and must say how older documents are handled. Keep
`scripts/validate-intake.py` passing on `templates/intake.example.yaml`.

## Rules every module must keep

- Never request real credentials: every secret becomes a `REPLACE_ME`
  placeholder set by the user in the Monad UI.
- Confirm field names with `get_*_type` at build time; describe intent and
  judgment in the module rather than copying a schema that will drift.
- Plan before build, with one approval; fetch before create; pipelines created
  disabled.
- Public sources only: link the Monad docs and vendor docs, not internal
  material.

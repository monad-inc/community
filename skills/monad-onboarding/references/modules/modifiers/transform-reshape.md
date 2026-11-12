# Modifier: transform-reshape

Insert a normalization transform when the source's shape doesn't match what the
destination expects: mapping vendor fields to a common schema (OCSF, ECS, CIM),
flattening nested events, or renaming fields.

## Config (`modifiers[].config`)

- `target_schema` (optional): `ocsf`, `ecs`, `cim`, or `custom`.
- `scope` (optional): `all` (default), or a list of categories or input types.
- `mapping` (optional): explicit field mappings, if the user has them.

## How it changes the build plan (Phase 7)

1. **Look for a ready-made transform first.** `list_community_transforms`
   returns maintained transforms that map common inputs to OCSF, ECS, and CEF
   (source: [monad-inc/community-transformations](https://github.com/monad-inc/community-transformations)).
   Use one when it exists for the input type and target schema.
2. Otherwise build one. Sample real (or synthetic) records first with
   `sample_node_data` on the input node, propose a mapping, and confirm it with
   the user before wiring. To write and validate a new OCSF, ECS, or CEF
   transform properly, use the `ocsf-transform-builder`,
   `ecs-transform-builder`, or `cef-transform-builder` skill from this
   repository.
3. Insert the transform between the input and the output(s) in each in-scope
   pipeline. Reuse one transform per distinct (input type, target schema) pair;
   check for an existing match before creating.
4. If `cold-storage-archive` is also active, the archive edge stays on the input
   node, before this transform, so the archive keeps the raw shape.

## Plan disclosure

List which pipelines get a transform, which are community transforms, and which
mappings are confirmed versus waiting on sampled data.

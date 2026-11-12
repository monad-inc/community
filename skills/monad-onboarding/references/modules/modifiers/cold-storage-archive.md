# Modifier: cold-storage-archive

"Also send everything to cheap object storage, as well as the SIEM."

Keeps a complete, long-term copy at object-storage prices, so the SIEM can keep
shorter retention and data can be replayed or queried later.

## Config (`modifiers[].config`)

- `bucket`, `region`, and `prefix` (default `<env>/cold/`). One shared output
  means records from every source land under the same date paths; if the user
  needs to replay or query one source at a time, offer one archive output per
  source with its own prefix (`<env>/cold/<source>/`) instead, and show the
  extra outputs in the plan.
- `format` (optional): `json` with `gzip` by default; `parquet` if the archive
  will be queried.
- `retention_days` (optional): documentation for the user; applied with an S3
  lifecycle rule outside Monad.
- Access: an IAM role (recommended) or `REPLACE_ME` key secrets, per
  [../outputs/s3.md](../outputs/s3.md).

## How it changes the build plan (Phase 7)

1. Create **one** shared S3 output, `<env>-cold-archive`, using the S3 module's
   directives. Reuse it in every pipeline; don't create one per pipeline.
2. In every pipeline, add an edge to that output with an `always` condition,
   named "Archive everything → cold storage".
3. Put the archive edge on the **input node**, before any transform, so the
   archive keeps the original records. A transform that reshapes or drops fields
   would otherwise change the archived copy. (Every node has one incoming edge,
   so the archive is a branch off the input, alongside the edge into the
   transform.)
4. With an `always` archive edge on the input, a separate "unmatched → archive"
   catch-all edge (see [../../data-organization.md](../../data-organization.md))
   isn't needed: unmatched records are already archived.

## Plan disclosure

State it plainly: "+1 shared S3 output, +1 archive edge on each of N pipelines,
+K placeholder secrets. Archived records are the raw input, before transforms."

# Input pattern: vendors with several feeds

Most vendors don't map to a single Monad input. They map to several input types,
one per feed or API. For example, searching `okta` returns System Audit Logs,
User Directory, Identity Groups, App Inventory, and more; searching
`crowdstrike` returns Event Stream, Device Inventory, Vulnerability Findings,
Falcon Data Replicator, and others. The user must choose which ones they want.

Handle this as a selection step inside Phase 4, after the vendor is known.

## Flow

1. `list_input_types(search: <vendor>)` and group the results:
   - **Event and log feeds** (audit logs, detections, event streams, alerts):
     what a SIEM usually wants.
   - **Inventory and state feeds** (users, groups, devices, apps,
     vulnerabilities): snapshots on a schedule. Useful in a data lake, for
     asset and identity context, or as lookup data for enrichment, and often
     noisy in a SIEM if sent on every run.
   - **Streaming or push variants** (webhooks, event hooks, stream inputs) of a
     feed that also has a polling input: pick one, not both, or the data
     arrives twice.
2. Present the groups with each type's name and a one-line description
   (`list_input_types(search: …, verbose: true)`). Recommend the event feeds
   for the user's destination; don't assume "all".
3. Record the choices in `data_sources[].tools[].input_types`.
4. For each chosen type, `get_input_type` for its settings and secrets. Feeds
   from one vendor usually share credentials: create **one** set of `REPLACE_ME`
   secrets per vendor and reference it from each input, not one set per input.
5. Name each input `<env>-<vendor>-<feed>`, for example
   `acme-poc-okta-systemlog`.
6. Each input normally gets its own pipeline (pattern 1 in
   [../../data-organization.md](../../data-organization.md)). Feeds of the same
   vendor can share outputs.

## Large-volume feeds

Some feeds (raw endpoint telemetry such as CrowdStrike Falcon Data Replicator,
flow logs, DNS) produce far more data than the others. Flag them in the plan,
confirm the user wants them in the SIEM, and consider tiering (pattern 4) or
sending them to object storage instead.

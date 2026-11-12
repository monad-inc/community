# Output module: Splunk

Loaded only when the user chooses Splunk. **Index-based**, so Phase 3 (data
model) runs. Monad docs: <https://app.monad.com/docs/outputs/splunk>.

This module does two jobs: guide the "how should the data be organized"
conversation, and turn the answer into Monad Splunk outputs plus pipeline
routing.

## A. What the Splunk output does (confirm with `get_output_type("splunk")`)

- **One index per output.** `index` is a single setting on the output. To land
  data in N indexes, create **N Splunk outputs**, one per index, and route to
  them with pipeline edges. This is the most important mechanical fact for
  layout.
- **`sourcetype`, `source`, and `host` are also per output.** Each is sent
  exactly as entered on every event; empty means the HEC token's default
  applies. Two sources that share an index but need different sourcetypes need
  two outputs (same index, different `sourcetype`).
- **`timestamp_field`** (a JSON path such as `eventTime`) sends each record's own
  event time, so Splunk indexes it at the time it happened instead of arrival
  time. Set it whenever the source has a reliable event-time field. Prefer an
  ISO 8601 string field (for example Okta's `published`). If the only
  candidate is an epoch number, check in Splunk after real data arrives that
  events carry the right time; a value Monad can't parse is sent without a
  time, so Splunk falls back to arrival time. Synthetic data can hold frozen
  event times, so choose the field by meaning, not by whether the sampled
  value looks current.
- **Monad can create the index** when `to_create` is true and a Splunk admin
  `username` and `password` (a secret) are provided. Otherwise the index must
  already exist.
- **Token scope.** If the HEC token is restricted to specific indexes in Splunk,
  the output's `index` must be one of them, or delivery fails. When Monad creates
  the index, the token must not be restricted.

Settings: `url` and `port` (required), `index`, `sourcetype`, `source`, `host`,
`timestamp_field`, `username`, `to_create`, `allow_insecure`. Secrets: `token`
(required, the HEC token) and `password` (only for index creation). Both secrets
become `REPLACE_ME` placeholders.

### Questions to merge into the flow

Ask these unless the intake answers them (`outputs[].config`):

- HEC URL and port.
- Should Monad create the indexes (needs a Splunk admin username, and a
  password set later in the UI), or will they exist already? Intake key:
  `outputs[].config.to_create`. Default: no; the handoff lists the indexes to
  create in Splunk.
- Sourcetype per source (see section C); if the user has no preference, propose
  them in the plan.
- Which data must not share an index (the driver questions in Phase 3).

## B. The data-organization conversation (Phase 3)

Read [../../index-modeling.md](../../index-modeling.md) first for the shared
strategy options and driver questions. Splunk's own rule summarizes them:

> An index is the unit of access control, retention, and search performance.
> Create a new index when one of those must differ. For anything else (vendor,
> format, log type), use `sourcetype`.
> ([Splunk: Create custom indexes](https://help.splunk.com/en/splunk-enterprise/administer/manage-indexers-and-indexer-clusters/10.0/manage-indexes/create-custom-indexes))

Present all three base layouts (`by_category`, `per_source`, `single`) with
their trade-offs, offer the hybrid (group by category, then split out the one or
two highest-volume or most sensitive sources), and let the user choose.

Splunk specifics for the driver questions:

- **Access:** Splunk role permissions are set per index (allowed indexes), so a
  group that must not see some data needs that data in its own index.
- **Retention:** set per index (`frozenTimePeriodInSecs`). Frozen data is
  **deleted** unless cold-to-frozen archiving is configured.
- **Volume:** a noisy source (firewall, DNS, proxy) in its own index keeps
  searches over smaller data fast.

Guardrails: never target `main`; keep the index count modest; prefer
consolidation over fragmentation.

## C. Naming

Default to Splunk's published convention, explain why, and let the user accept
it, adjust it, or bring their own.

- **Default:** `<company>_<purpose>_<sensitivity>` (use `environment_name` for
  the company segment unless the user gives one), lowercase with underscores,
  where the purpose is generic (`firewall`, `identity`, `web`), not a product or
  team name that will change. Examples: `acme_firewall_prod`, `acme_identity_pci`.
  ([Splunk Lantern: naming conventions](https://lantern.splunk.com/Splunk_Success_Framework/Data_Management/Naming_conventions))
- **Why:** a consistent prefix allows wildcard role permissions (`acme_*`,
  `acme_*_pci`), a generic purpose survives a vendor change, and a sensitivity
  segment lets you secure and retain by data class.
- Honor `data_model.options.index_name_template` when the intake provides one.
- **Sourcetypes:** Monad sends each record as a JSON event. Pick a sourcetype
  whose parsing expects JSON:
  - Vendors whose native format is JSON (Okta System Log, CrowdStrike event
    streams, CloudTrail) can use the vendor's JSON sourcetype, so Splunk
    add-ons apply their field extractions.
  - Vendors whose add-on expects raw text (PAN-OS `pan:*`, `linux_secure`,
    most syslog sourcetypes) won't parse a JSON-wrapped record. **Default to
    Splunk's built-in `_json`**, which extracts the JSON fields with no Splunk
    configuration, and tell the user the vendor add-on's extractions won't
    apply. Offer the alternative in the plan: a transform that sends only the
    original line (for syslog, the `msg` field) with the vendor sourcetype.
  - An intake can set sourcetypes explicitly in
    `outputs[].config.sourcetypes`, a map from source (vendor or input type) to
    sourcetype; those win over these defaults.

## D. Build directives

1. `get_output_type("splunk")` to confirm the current settings and secrets.
2. Work out the **target set** from the layout and driver splits: each distinct
   (index, sourcetype) pair is one Splunk output, named
   `<env>-splunk-<index purpose>[-<source>]`, for example
   `acme-splunk-identity-okta`.
3. Create one `REPLACE_ME` secret for the HEC token, for example
   `<env>-splunk-hec-token`, and reuse it across outputs that share a token. If
   Monad is creating indexes, also create `<env>-splunk-admin-password`.
4. Create each output with `url`, `port`, `index`, `sourcetype`, and (where
   known) `timestamp_field`. Leave `allow_insecure` off.
5. Route each pipeline to the right output with named edges
   ([../../data-organization.md](../../data-organization.md)).
6. Create pipelines with `enabled: false`. Run `test_output_connection` only
   after the real token is set.

## E. Tell the user

- "Each Monad Splunk output writes to one index with one sourcetype, so I'm
  creating one output per index and sourcetype and routing between them."
- "Retention and role permissions are configured in Splunk. I've laid out the
  indexes to match your access, retention, and volume needs; you set the actual
  policies there."
- If they didn't choose index creation: "Create these indexes in Splunk first,
  and make sure the HEC token is allowed to write to them: …"

Further reading: [Securing Splunk indexes (Lantern)](https://lantern.splunk.com/Platform_Data_Management/Protect_Data/Properly_securing_Splunk_indexes),
[Data onboarding best practices](https://www.splunk.com/en_us/blog/platform/clara-fication-data-onboarding-best-practices.html).

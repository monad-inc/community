# Index modeling

Loaded in Phase 3, **only** when a chosen output is index-based (Splunk,
Elasticsearch; see `modules/outputs/_registry.yaml`). Don't just record
`data_model.strategy`: explain the trade-offs and recommend based on what the
user told you.

## The question

"How do you want your data organized in <destination>? There are three common
approaches, with different trade-offs:"

### 1. `single`: one index for everything

- **Pros:** simplest to set up and query; fewest moving parts.
- **Cons:** all data shares one retention period; access control is all or
  nothing; harder to manage cost per data type; slower searches as it grows.
- **Recommend when:** a small proof of concept, low volume, or "I just want to
  see data flowing".

### 2. `per_source`: one index per data source

- **Pros:** clean separation; per-source retention and access control; easy to
  see volume per source; a noisy source can't slow searches over the others.
- **Cons:** index sprawl as sources grow; dashboards must search many indexes.
- **Recommend when:** a handful of high-value sources that need isolation or
  their own retention.

### 3. `by_category`: grouped by data category (identity, network, endpoint, …)

- **Pros:** balances separation and sprawl; matches how analysts search and how
  detection content is organized; retention and access by security domain.
- **Cons:** needs routing so each source lands in its category's index; one
  very high-volume category still shares a single index.
- **Recommend when:** the user collects several categories. This is the usual
  starting point for a production environment.

Most teams end up with a **hybrid**: group by category, then move one or two
high-volume or specially governed sources into their own indexes. Offer that as
a natural refinement rather than a fourth option.

## Driver questions

The layout above is the starting point. Practitioner guidance for both Splunk
and Elastic is to give data its own index only when one of these drivers
applies. Ask them regardless of the base choice; a "yes" carves out a dedicated
index.

1. **Access control** (the strongest driver). Must some group be unable to see
   this data? Access is enforced per index; search-time filters are not a
   security boundary.
2. **Sensitivity or compliance.** Regulated data (PCI, PII) or data-sharing
   limits? Use a dedicated index, often with a sensitivity suffix in the name,
   so the whole index can be secured. Often pairs with longer retention.
3. **Retention.** Does it need a different keep period than its peers (for
   example 1 year instead of 30 days)? Retention is set per index.
4. **Volume.** A noisy, high-volume source (firewall, DNS, proxy) that would
   slow searches over smaller data next to it? Split it out.

If none apply and it's just another vendor or format, **don't** create an index.
Keep it in the existing index and tell the formats apart another way (in Splunk,
with `sourcetype`).

## Guardrails

- Never use the platform's default index (`main` in Splunk) as a real
  destination.
- Keep the index count modest; consolidate rather than fragment.
- Set retention deliberately. On most platforms, aged-out data is **deleted**
  unless archiving is configured. The `cold-storage-archive` modifier is one way
  to keep a long-term copy.

## How the choice drives the build

- `single`: every pipeline writes to one index.
- `per_source`: one index per resolved input type.
- `by_category`: one index per category present in `data_sources`; each
  source's pipeline routes to its category's index. Use
  `data_model.options.index_name_template` if given (for example
  `acme_{category}_prod`).

How an output implements an index (for example, one fixed index per output
versus an index chosen per record) is output-specific and lives in the output
module, such as [modules/outputs/splunk.md](modules/outputs/splunk.md).

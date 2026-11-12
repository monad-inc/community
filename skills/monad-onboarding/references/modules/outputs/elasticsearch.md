# Output module: Elasticsearch

Loaded only when the user chooses Elasticsearch. **Index-based**, so Phase 3
runs. Monad docs: <https://app.monad.com/docs/outputs/elasticsearch>.

## What the output does (confirm with `get_output_type("elasticsearch")`)

- **One index per output**, set in `index`. The index is created automatically
  if it doesn't exist.
- **Date templating:** `index` accepts tokens resolved at write time in UTC:
  `{yyyy}`, `{yy}`, `{mm}`, `{dd}`, `{hh}`, `{mi}`, `{ss}`. For example
  `acme-identity-{yyyy}.{mm}` gives a monthly index, which makes retention by
  deleting old indexes easy.
- **No data streams.** The output writes to a regular index. The name must not
  be a data stream or match a data stream index template such as `logs-*-*`.
- **Connection** (`connection_config`): either `url` (an `endpoint`) or
  `cloud_id` (an Elastic Cloud deployment ID).
- **Authentication** (`auth_config`): either `api_key` or `password`, each
  holding a secret. `username` is a required setting.

## Questions to merge into the flow

- Elastic Cloud (Cloud ID) or a direct URL?
- API key or username and password? Recommend an API key scoped to the target
  indexes.
- Index naming and whether to roll indexes by date.

## Index-model wiring

- `single`: every pipeline writes to one output.
- `per_source`: one output per input type, for example `acme-okta-{yyyy}.{mm}`.
- `by_category`: one output per category; honor
  `data_model.options.index_name_template`.

Elasticsearch index names must be lowercase and can't contain spaces or most
punctuation (`\ / * ? " < > | , #`), and can't start with `-`, `_`, or `+`.
Sanitize generated names.

## Build directives

1. `get_output_type("elasticsearch")` to confirm settings and secrets.
2. Create a `REPLACE_ME` secret for the API key or password, for example
   `<env>-elastic-api-key`, reused across outputs that share credentials.
3. Create one output per target index.
4. Create pipelines with `enabled: false`. Run `test_output_connection` only
   after the real credential is set.

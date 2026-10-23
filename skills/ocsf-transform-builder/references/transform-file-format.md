# community-transformations File Format

Reference: <https://github.com/monad-inc/community-transformations>

The Monad SaaS platform syncs this repository hourly. Files in
`ocsf/v<X.Y.Z>/<vendor>/<vendor>-<datatype>.yaml` become available to all
Monad users as transformation building blocks.

## Path layout

```
ocsf/v<ocsf-version>/<vendor>/<vendor>-<datatype>.yaml
```

For vendors with multiple product lines, an extra subdirectory is allowed:

```
ocsf/v1.1.0/crowdstrike/edr/crowdstrike-device-details.yaml
```

The filename must encode both vendor and datatype, lowercase, hyphen-separated.
It must match the value listed in the `inputs:` array inside the file.

## Top-level fields

| Field           | Type            | Required | Notes                                                                                             |
|-----------------|-----------------|----------|---------------------------------------------------------------------------------------------------|
| `name`          | string          | yes      | Human title. MUST end with ` to OCSF v<X.Y.Z>` matching the target OCSF version, e.g. `"Okta System Audit Logs to OCSF v1.1.0"`. The version suffix prevents per-version transforms for the same input from colliding under one display name in the Monad SaaS UI. |
| `description`   | string          | yes      | One-sentence summary. Should embed the OCSF version, e.g. `"...into OCSF v1.1.0 Schema"`.         |
| `author`        | string          | yes      | GitHub profile URL of the transform's original author. Never changed by later updates. |
| `contributors`  | list[string]    | yes      | GitHub profile URLs. The author is listed first; anyone who updates the transform appends themselves. Append, don't replace. |
| `inputs`        | list[string]    | yes      | The source datatype slug(s) this transform consumes. Matches the filename stem.                   |
| `tags`          | list[string]    | yes      | Must include the OCSF version tag (`v1.1.0`), `ocsf`, the vendor, and class/category tags.        |
| `config`        | object          | yes      | Holds the operations pipeline.                                                                    |
| `config.operations` | list[object] | yes      | Ordered. Output of operation N is input to N+1.                                                   |

## Operation shape

Every operation observed in the repo today uses `operation: "jq"`. Each
operation has:

```yaml
- operation: "jq"
  arguments:
    key: ""           # Reserved; empty string in all current transforms.
    query: |
      # Multi-line jq program. Pipe-style or single-expression both work.
```

The `query` is a normal jq program. It receives one input record at a time as
the implicit `.` and must emit a single JSON object (the OCSF event). Common
patterns:

- Define helpers with `def name($arg): ...;` at the top of the query.
- Build the output as a single `{ ... }` literal at the end.
- Use `// "default"` to handle missing source fields.
- Wrap timestamp parsing in a helper — formats vary widely between vendors.
- Cast strings to numbers explicitly when the OCSF schema expects an integer
  (e.g., `type_uid`).

## Tags conventions

Required tags:

- The OCSF version: `v1.1.0`, `v1.2.0`, etc. Exactly one.
- `ocsf` — marks the output format family.
- Vendor: `okta`, `crowdstrike`, `wiz`, etc.

Recommended tags (used as filters in the Monad UI):

- The OCSF category in lowercase: `audit`, `findings`, `iam`, `discovery`,
  `application activity`, etc.
- The class semantic in lowercase: `authentication`, `vulnerability`,
  `inventory`, `device`, `api activity`.

## Attribution rules (from the repo readme)

- **New transform**: set `author` to your GitHub profile URL and list the same
  URL first in `contributors`.
- **Update existing transform**: never change `author`. Append your GitHub
  profile URL to `contributors` if not already present.

Many existing transforms carry `author: "Monad"`; that is the original author
for those files and stays as-is.

## Common conventions (not part of OCSF spec)

These keys appear at the top level across many transforms; downstream tooling
handles them:

- `raw_data` — the entire input record stringified. Useful for forensic
  replay.
- `unmapped` — an object holding fields from the source that don't map to any
  OCSF attribute.
- `ref_time` — the original ISO-8601 timestamp string before epoch conversion.

The validator's allowlist matches this set; don't add to it without changing
the validator script.

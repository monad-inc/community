# tls-cert-to-syslog-input

`monad-tls-cert-to-pipeline.sh`

## Purpose

Registers device **TLS-certificate SHA-256 fingerprints** on a Monad pipeline's
**Syslog input** so that log sources which **cannot use SNI** can still be routed
to the correct pipeline. Monad's syslog receiver matches the client-certificate
SHA-256 fingerprint of an incoming connection against the `cert_fingerprints`
list configured on each Syslog input and routes accordingly.

For each entry in the input file the script: (1) connects to the device over TLS
with `openssl s_client`, (2) computes the SHA-256 of its leaf certificate
(64-char lowercase hex over the DER encoding), and (3) adds that fingerprint to
the Syslog input's `cert_fingerprints` via the Monad REST API. Precomputed
fingerprints can be bulk-loaded instead of probed.

Monad API surface: `GET /v1/organizations`, `GET /v2/{org}/pipelines/{id}`,
`GET /v1/{org}/inputs/{id}`, `PATCH /v2/{org}/inputs/{id}`.

## Requirements

- `bash` (3.2+, macOS default works), `openssl`, `curl`, `jq`.
- `timeout`/`gtimeout` optional (used to bound per-device probes; degrades
  gracefully if absent).
- Network egress to each device's TLS port and to `app.monad.com`.

## Authentication

Supply an **organization-level Monad API key** with permission to **read
pipelines and update inputs**, via one of:

- `-k, --api-key <key>`
- `MONAD_API_KEY` environment variable
- interactive prompt (if neither is set and a terminal is attached)

The key is passed to `curl` through a mode-`600` config file, so it does not
appear in the process list.

## Usage

```bash
export MONAD_API_KEY='...'
./monad-tls-cert-to-pipeline.sh -f devices.txt -p <pipeline_id>
```

Preview without writing:

```bash
./monad-tls-cert-to-pipeline.sh -f devices.txt -p <pipeline_id> --dry-run
```

Bulk-load precomputed fingerprints (skip the TLS probe):

```bash
./monad-tls-cert-to-pipeline.sh --hashes-file fingerprints.txt -p <pipeline_id>
```

| Flag | Required | Description |
|------|----------|-------------|
| `-f, --file` | one of `-f`/`--hashes-file` | IP list (one `ip`, `host`, or `host:port` per line); each device is probed over TLS |
| `--hashes-file` | one of `-f`/`--hashes-file` | File of precomputed 64-char-hex SHA-256 fingerprints, added as-is |
| `-p, --pipeline-id` | yes (unless `--input-id`) | Destination pipeline whose Syslog input is updated |
| `-k, --api-key` | see Authentication | Monad API key |
| `-o, --organization-id` | no | Org id; auto-resolved when the key has exactly one org |
| `--input-id` | no | Target a Syslog input/component id directly, skipping pipeline lookup |
| `-P, --port` | no | Default device TLS port (default `443`) |
| `-t, --timeout` | no | Per-device connect timeout in seconds (default `10`) |
| `-u, --base-url` | no | Monad API base URL (default `https://app.monad.com/api`) |
| `--replace` | no | Replace `cert_fingerprints` instead of merging with existing |
| `-n, --dry-run` | no | Do all reads, print what would be written, but don't `PATCH` |
| `-h, --help` | no | Show help |

## Inputs / outputs

- **Input:** a text file of devices (`-f`) and/or a text file of 64-hex
  fingerprints (`--hashes-file`). Blank lines and `#` comments are ignored.
- **Effects:** updates `settings.cert_fingerprints` on the target Syslog input
  (merge + de-dupe + lowercase by default). Prints a per-device result line and a
  summary. Exits non-zero if any device failed or the update failed.

## Limitations & caveats

- **The pipeline must already have a Syslog input** (`monad-syslog`). The script
  updates an existing input; it does not create one. If the pipeline has no
  Syslog input, it exits with guidance; if it has several, pass `--input-id`.
- **API-key permissions:** must read pipelines and update inputs at the org level.
- **The fingerprint must match the device's _client_ certificate** as presented to
  Monad's syslog endpoint. The script retrieves the cert the device serves on the
  probed port; routing only works if that is the same cert the device uses for its
  outbound (client) TLS to Monad. Verify for appliances that use separate certs.
- **Random/unreachable IPs yield nothing** — a fingerprint requires a completed
  TLS handshake; unreachable hosts time out and are reported as failures.
- **IPv6 with a port is not parsed** — the `host:port` split is naive. Plain IPv6
  addresses or hostnames are fine.
- **Running as root bypasses the readability check** (`-r`), since root can read
  any file regardless of mode.
- **`--replace` overwrites** the entire `cert_fingerprints` list; the default
  merges with whatever is already configured.

## Safety

- Credentials are never committed and are kept out of `ps` (curl `--config`).
- Use `--dry-run` to preview the exact fingerprint list that would be written
  before committing.

## Related

- Monad Syslog input — SNI / client-cert / fingerprint routing.
- Monad REST API: organizations, pipelines, and inputs endpoints.

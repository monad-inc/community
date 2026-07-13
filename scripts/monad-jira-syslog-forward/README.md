# monad-jira-syslog-forward

`monad-jira-syslog-forward.sh`

## Purpose

Configures **rsyslog** on an on-premises Linux server running **Atlassian Jira**
(Server / Data Center) to tail Jira's application, security, and (optionally)
Tomcat `catalina.out` logs and forward them over TLS to a **Monad Syslog input**
pipeline. It writes a dedicated `/etc/rsyslog.d/10-monad-jira.conf` with
`imfile` inputs, a scoped ruleset, and an `omfwd` action to
`<pipeline-id>.l4.monad.com:6514` (RFC 5424, RFC 6587 octet-counted framing, a
disk-assisted queue with infinite retries), validates it, and restarts rsyslog.

Monad API surface: the **Syslog input connector** only
(`<pipeline-id>.l4.monad.com:6514`, persistent TCP + TLS). The script makes **no
authenticated Monad REST/MCP calls** and handles no Monad API key.

## Requirements

- Interpreter: `bash` (uses `set -euo pipefail`; `--dry-run` runs on macOS for
  previewing the generated config).
- Tools: `rsyslog` with a TLS stream driver (`rsyslog-gnutls` / `gtls` or
  `rsyslog-openssl` / `ossl` — the script installs one if absent), `openssl`
  (for `client-cert` and `fingerprint` modes), and a systemd `rsyslog` service.
- Privileges: **root** to write the config and restart rsyslog (`--dry-run`
  needs no root and no rsyslog installed).
- Platform notes: live-verified on Ubuntu 24.04, Amazon Linux 2023, and
  Amazon Linux 2. See the platform matrix and caveats below.

## Authentication

**None.** A customer-facing forwarder carries no Monad credentials. Where Monad
needs to know about the sending certificate (`fingerprint` mode), the script
computes the SHA-256 locally and prints an **ACTION REQUIRED** block to register
it in the Monad UI (or via Monad Customer Support) — it does not call any Monad
API to do so.

## Usage

```bash
# Typical: modern server, default Jira paths
sudo ./monad-jira-syslog-forward.sh -p <pipeline-uuid>
```

Preview the exact rsyslog config without changing anything (no root, no rsyslog
needed):

```bash
./monad-jira-syslog-forward.sh -p <pipeline-uuid> --dry-run
```

Older rsyslog (no SNI) — generate a self-signed identification certificate, or
use an existing/mandated certificate and register its fingerprint:

```bash
sudo ./monad-jira-syslog-forward.sh -p <pipeline-uuid> --tls-mode client-cert

sudo ./monad-jira-syslog-forward.sh -p <pipeline-uuid> \
  --tls-mode fingerprint --cert /etc/pki/jira.crt --key /etc/pki/jira.key
```

| Flag | Required | Description |
|------|----------|-------------|
| `-p <uuid>` | yes | Monad pipeline ID (UUID) of the pipeline with the Syslog input. Find it in the pipeline page URL in the Monad UI, or via `GET https://app.monad.com/api/v2/<org-id>/pipelines`. |
| `-j <dir>` | no | `JIRA_HOME` (default `/var/atlassian/application-data/jira`); logs read from `<dir>/log/`. |
| `-i <dir>` | no | Jira install dir; also forwards Tomcat `catalina.out` from `<dir>/logs/`. Off by default. |
| `--tls-mode <mode>` | no | `auto` (default), `sni`, `client-cert`, or `fingerprint`. See TLS modes below. |
| `--cert <pem>` | fingerprint mode | Existing PEM certificate. |
| `--key <pem>` | fingerprint mode | Existing PEM private key. |
| `-n, --dry-run` | no | Print what would be done without changing anything. |
| `-h, --help` | no | Show full help with examples. |

Long options also accept `--opt=value` (e.g. `--tls-mode=sni`).

### TLS identification modes

Monad routes an inbound TLS connection to the right pipeline by one of three
mechanisms. `--tls-mode auto` detects and picks the first that fits:

1. **`sni`** — rsyslog ≥ 8.31 with the `gtls` driver sends SNI from the target
   hostname (since 8.31.0, Nov 2017). No certificate needed.
2. **`client-cert`** — older rsyslog: generate a self-signed certificate with
   the pipeline UUID in `Subject.serialNumber` (RSA 2048, for old-GnuTLS
   compatibility). Monad routes on the serialNumber.
3. **`fingerprint`** — self-signed certs not permitted (a mandated appliance
   certificate must be used): present the existing cert (`--cert`/`--key`) and
   register its SHA-256 with Monad.

## Inputs / outputs

- **Input:** command-line flags only. Reads the Jira log files under
  `JIRA_HOME/log/` (and optional `catalina.out`); optionally reads an existing
  cert/key pair in `fingerprint` mode.
- **Output / effects:** writes `/etc/rsyslog.d/10-monad-jira.conf`; in
  `client-cert`/`fingerprint` modes writes cert/key material under
  `/etc/rsyslog.d/monad/`; validates with `rsyslogd -N1` and restarts rsyslog.
  Prints each auto-detection decision, and in `fingerprint` mode an
  **ACTION REQUIRED** block with the SHA-256 to register.

## Verified platforms

| Platform | rsyslog / driver | Auto-selected mode | Result |
|---|---|---|---|
| Ubuntu 24.04 | 8.2312, gtls | `sni` | ✅ events arrived |
| Amazon Linux 2023 | ossl only | `client-cert` (ossl has no client SNI) | ✅ events arrived |
| Amazon Linux 2 | 8.24, gtls (old) | `client-cert` | ✅ events arrived |

All three TLS identification modes were proven end to end against a sandbox
pipeline; the non-SNI modes were verified with `openssl s_client -noservername`
to confirm routing does not depend on SNI.

## Limitations & caveats

- **The pipeline must already have a Syslog input** (`monad-syslog`). The script
  configures the *sender*; it does not create or modify the Monad pipeline.
- **`fingerprint` mode is not self-completing.** Forwarding only starts once the
  printed SHA-256 fingerprint is registered on the Syslog input (Monad UI or via
  Monad Customer Support) — a manual, Monad-side step the script cannot perform.
- **`ossl` (OpenSSL driver) has no client SNI** in any released rsyslog (checked
  through v8.2510). Amazon Linux 2023 packages only `rsyslog-openssl`, so it
  always falls back to `client-cert` even on a new rsyslog.
- **Amazon Linux 2 `imfile` polls every ~10 s** (no inotify in that build), so
  events can take 10 s+ to appear — not a failure; wait before concluding
  nothing arrived.
- **Old GnuTLS (rsyslog 8.24, AL2/CentOS 7) requires a CA file** to load the TLS
  driver at all and **cannot parse EC keys** — hence the system CA bundle is
  always set and generated client certs are RSA 2048.
- **Debian/Ubuntu rsyslog drops privileges** (`PrivDropToUser syslog`) before
  reading cert/key; the script detects the runtime user and chowns the copies it
  places under `/etc/rsyslog.d/monad/` (customer-owned originals are never
  modified).
- **Scoped forwarding only.** A dedicated ruleset forwards only the Jira file
  inputs; the host's general syslog stream (sshd, cron, kernel) is not sent.
- **systemd assumed** for the restart (`systemctl restart rsyslog`).

## Safety

- Carries **no credentials** — nothing secret to commit or leak.
- **Never modifies customer-owned files:** existing certs/keys are copied into
  the script's own directory before ownership is adjusted.
- **Validate-before-apply:** the config is checked with `rsyslogd -N1` before the
  restart; on failure the config file is removed so a typo can never take down
  the server's existing logging.
- **`--dry-run`** prints the exact config (and, in `fingerprint` mode, the
  fingerprint) without writing anything or requiring root.

## Related

- Monad Syslog input — SNI / client-cert / fingerprint routing:
  <https://app.monad.com/docs/inputs/monad/monad-syslog>
- [`tls-cert-to-syslog-input`](../tls-cert-to-syslog-input/) — register device
  TLS-certificate fingerprints on a Syslog input (the Monad-side counterpart to
  this script's `fingerprint` mode).

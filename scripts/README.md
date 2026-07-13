# Scripts

Utility scripts that interact with Monad (its REST API, MCP tools, or
connectors). Each script lives in its own directory with a `README.md` covering
its usage and limitations.

## Catalog

| Script | Purpose | Language | Monad API surface | Category | Docs |
|---|---|---|---|---|---|
| [`tls-cert-to-syslog-input`](tls-cert-to-syslog-input/) | Register device TLS-certificate SHA-256 fingerprints on a pipeline's Syslog input so SNI-less sources route correctly | Bash | `GET /v1/organizations`, `GET /v2/{org}/pipelines/{id}`, `GET /v1/{org}/inputs/{id}`, `PATCH /v2/{org}/inputs/{id}` | Inputs / routing | [README](tls-cert-to-syslog-input/README.md) |
| [`monad-org-export`](monad-org-export/) | Export an entire organization to a Terraform module, then migrate it between instances (SaaS ↔ self-hosted) or back it up to Git | Python / Bash | `GET /v1/{org}/inputs\|outputs\|transforms`, `GET /v3/{org}/enrichments`, `GET /v2/{org}/secrets\|pipelines` | Migration / backup | [README](monad-org-export/README.md) |
| [`monad-jira-syslog-forward`](monad-jira-syslog-forward/) | Configure rsyslog on an on-prem Jira server to forward Jira application/security/Tomcat logs over TLS to a Monad Syslog input (auto SNI / client-cert / fingerprint) | Bash | Syslog input connector (`<pipeline-id>.l4.monad.com:6514`, TLS) | Inputs / forwarding | [README](monad-jira-syslog-forward/README.md) |

## Layout

```
scripts/
├── README.md            # this catalog
├── _template/           # copy this to start a new script
│   ├── README.md        # per-script doc template (fill every section)
│   └── script.sh        # script header/convention stub
└── <slug>/              # one directory per script
    ├── README.md        # required: usage + limitations
    ├── <script>.sh      # the script
    └── examples/        # optional sample inputs/outputs
```

## Adding a script

See [`../CONTRIBUTING.md`](../CONTRIBUTING.md). In short: copy `_template/` to
`scripts/<slug>/`, fill in the README (including **Limitations & caveats**), add
the script, and register a row in the catalog above.

## Conventions (summary)

- Credentials come from env vars / a secrets manager / an interactive prompt —
  **never** committed. Keep API keys out of the process list where practical.
- Note the interpreter and required tools/versions in each script's README.
- Provide a **dry-run** for anything that changes Monad state.
- Document the Monad API surface touched and the API-key permissions required.

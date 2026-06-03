<!--
  Per-script documentation template. Copy this whole directory:
      cp -r scripts/_template scripts/<your-slug>
  Then fill in EVERY section below. Do not leave the Limitations section as a
  placeholder — a script without documented limitations will not be merged.
  Delete this comment block when done.
-->

# <script name>

## Purpose

<One short paragraph: what the script does, and which Monad API surface it
touches (endpoints / MCP tools / connectors).>

## Requirements

- Interpreter: <e.g. `bash` (3.2+), `python` 3.x>
- Tools: <e.g. `curl`, `jq`, `openssl` — and any minimum versions>
- Platform notes: <e.g. macOS/Linux; anything OS-specific>

## Authentication

<How the Monad API key is supplied (env var / secret manager / prompt) and the
permissions it must have. Never hard-code credentials.>

## Usage

```bash
<invocation with the most common flags>
```

| Flag | Required | Description |
|------|----------|-------------|
| `-x, --example` | yes/no | <what it does> |

<Add a dry-run example if the script changes Monad state.>

## Inputs / outputs

- **Input:** <file formats / arguments the script consumes>
- **Output / effects:** <what it prints, writes, or changes in Monad>

## Limitations & caveats

<!-- REQUIRED. Be specific and honest. Cover, as applicable: -->
- <Required API-key permissions / scopes.>
- <Rate limits or throughput ceilings.>
- <Idempotency / merge / overwrite behavior.>
- <What the script explicitly does NOT do.>
- <Environment assumptions (shell version, dependencies) and known edge cases.>
- <Any fire-and-forget / no-confirmation behaviors.>

## Safety

<Destructive-action notes, how secrets are handled, and how to preview changes
(dry-run) before committing them.>

## Related

- <Monad docs / connector references / related scripts.>

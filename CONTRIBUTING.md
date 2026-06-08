# Contributing

Thanks for adding to the Monad Community repo. This guide covers contributing
**scripts** (the `scripts/` directory); for blog assets, just add files under
`blog/`.

## Adding a script

Every script lives in its own directory under `scripts/<slug>/` and ships with a
`README.md` documenting **how to use it and its limitations**. A script without
that documentation will not be merged.

1. **Scaffold from the template:**
   ```bash
   cp -r scripts/_template scripts/<your-slug>
   ```
   Use a short, descriptive `kebab-case` slug (e.g. `tls-cert-to-syslog-input`).

2. **Add your script** to that directory (`.sh`, `.py`, etc.). Keep it
   self-contained; put sample inputs/outputs under an `examples/` subfolder.

3. **Fill in `scripts/<your-slug>/README.md`** — every section of the template,
   especially **Limitations & caveats**. Be honest about what the script does
   *not* do, what permissions it needs, and any edge cases.

4. **Register it** in the catalog table in [`scripts/README.md`](scripts/README.md)
   (one row: script, purpose, language, Monad API surface, category, link).

5. **Open a PR.** See the checklist below.

## Conventions

- **Secrets never get committed.** Read credentials from an environment variable
  (e.g. `MONAD_API_KEY`), a secrets manager, or an interactive prompt — never a
  literal in the script or examples. Keep API keys out of the process list where
  practical (e.g. pass headers to `curl` via `--config`, not the command line).
- **Be portable and dependency-light.** Note the interpreter and required tools
  (and versions) in the README. For Bash, target `bash` 3.2 (macOS default) where
  feasible.
- **Offer a dry run** for anything that writes/changes Monad state, so users can
  preview before committing.
- **Document the Monad API surface** the script touches (endpoints, MCP tools, or
  connectors) and the API-key permissions required.
- **Commits** follow [Conventional Commits](https://www.conventionalcommits.org/):
  `feat(scripts): add <slug>`, `fix(scripts): …`, `docs(scripts): …`. Branch names
  mirror the type: `feat/<slug>`, `fix/<slug>`.

## PR checklist

- [ ] Script lives in `scripts/<slug>/` with a populated `README.md`.
- [ ] **Limitations & caveats** section is filled in (not left as a placeholder).
- [ ] No secrets committed; credentials sourced from env/secret manager/prompt.
- [ ] Usage examples included; a dry-run path exists for state-changing scripts.
- [ ] Added a row to `scripts/README.md`.
- [ ] Conventional Commit message and matching branch name.

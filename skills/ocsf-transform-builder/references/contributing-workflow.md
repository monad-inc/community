# Contributing workflow (shared by the transform builder skills)

This file is identical in `ocsf-transform-builder`, `ecs-transform-builder`, and
`cef-transform-builder`. It covers everything that is the same regardless of
the target schema: the working clone, attribution, input connector IDs, sample
data, and opening the pull request.

## The working clone

All transform work happens in a clone of
[`monad-inc/community-transformations`](https://github.com/monad-inc/community-transformations),
managed by `scripts/community-repo.sh`:

| Command | What it does |
|---|---|
| `scripts/community-repo.sh setup` | Clones the repo (shallow) into `./.community-transformations` under the current directory, or reuses an existing clone. Prints the clone path as its last stdout line. |
| `scripts/community-repo.sh path` | Prints the clone path. |
| `scripts/community-repo.sh status` | Reports uncommitted changes and unpushed commits. |
| `scripts/community-repo.sh teardown` | Deletes the clone, but only if it is clean and fully pushed; otherwise it keeps the directory and lists the unsaved work. |

Run `REPO="$(scripts/community-repo.sh setup)"` at the start of a task and use
`$REPO` as the root for every file path. Set `COMMUNITY_TRANSFORMATIONS_DIR` to
put the clone somewhere else. Nothing removes the clone automatically; run
`teardown` when the pull request is open. If your agent supports end-of-session
hooks, `teardown` is safe to wire to one.

Before editing, read the repo's own `readme.md` in the clone. Where it and these
skills disagree, the repo wins.

## Attribution

Every transform carries `author` and `contributors` (GitHub profile URLs):

- **New transform:** set `author` to the contributor's GitHub profile URL
  (`"https://github.com/<handle>"`) and list the same URL first in
  `contributors`.
- **Updating an existing transform:** never change `author`. Append the
  contributor's GitHub URL to `contributors` if it isn't already there.

Ask the user for their GitHub handle rather than guessing it. If the GitHub CLI
is authenticated, `gh api user --jq .login` returns it.

## Input connector IDs must be real

The `inputs:` slug in a transform must be a real Monad input connector ID, and
the filename stem must match it. Never invent, guess, or abbreviate one; a slug
that doesn't exist means the transform never appears for that connector.

How to verify, in order of preference:

1. **Monad MCP server** (if connected): `list_input_types` lists every connector
   as `(ID: <slug>)`. The slug must appear in it verbatim.
2. **Monad docs** (no MCP): every connector has a page under
   <https://app.monad.com/docs/inputs/index>, and the slug is the last path
   segment, for example `https://app.monad.com/docs/inputs/tenable/tenable-vulnerabilities`
   has slug `tenable-vulnerabilities`. Fetch the page to confirm it exists.

If the slug can't be confirmed either way, stop and tell the user rather than
writing the transform.

## Sample data

A transform is only as good as the records it was tested against. Sources, best
first:

1. **Live records through the Monad MCP server.** Monad hosts a remote MCP
   server at `https://app.monad.com/mcp` (OAuth, no API key; setup for each
   client is at <https://app.monad.com/docs/mcp/index>). With it connected, see
   [Live validation with the Monad MCP server](#live-validation-with-the-monad-mcp-server).
2. **Records the user provides**, pasted or as files. Ask the user to redact
   secrets and personal data first.
3. **Records constructed from the vendor's public API documentation**, when
   neither of the above is available. Say clearly in the pull request that the
   transform was tested against synthetic records only.

Whatever the source, test at least three records derived from it: a success
path, a failure path, and one with optional fields missing. Base these on the
variation actually present in the samples (distinct severity/status values,
null vs. populated nested objects) rather than inventing records from scratch.

## Live validation with the Monad MCP server

Only when the user has connected the Monad MCP server and agreed to create
resources in their Monad organization. Recommend a sandbox or test
organization. Track every resource you create so you can remove it afterwards.

1. **Find the input.** `list_inputs` to reuse an input that already has data
   (best), or `list_input_types` to pick a type. Inputs that support it can run
   with `use_synthetic_data: true` without credentials.
2. **Register the transform under development** with `create_transform` (and
   `update_transform` as you iterate). `list_community_transforms` shows what is
   already published.
3. **Build a test pipeline**: input → transform → a discard output. The discard
   output type is `dev-null`; confirm it with `list_output_types`, then
   `create_output` and `create_pipeline`. Ask the user whether the pipeline
   should start enabled.
4. **Sample the output.** `sample_node_data` on the transform node returns what
   it emits from live records. `get_pipeline_status` and `get_pipeline_logs`
   show errors. Iterate until the output is clean, and still run the skill's
   offline validators on the sampled records.
5. **Clean up.** Delete what you created, in order: `delete_pipeline`, then
   `delete_output`, `delete_transform`, and `delete_input` (only if you created
   the input).

Never ask the user to paste credentials into the conversation. If an input
needs secrets, have the user set them in the Monad UI.

## Opening the pull request

1. Show the user the final YAML and the validation output, and get their
   approval before committing. The user owns all git operations.
2. Create a branch in `$REPO` (for example `feat/<vendor>-<datatype>-<schema>`),
   commit, and push. Contributors without push access to the upstream repo
   should fork it first: `gh repo fork --remote --remote-name fork` inside
   `$REPO`, then push the branch to `fork`.
3. Open a pull request against `monad-inc/community-transformations` `main`
   (`gh pr create`, or through GitHub). Describe the source, the target
   schema/version, how it was tested, and anything left unmapped.
4. Run `scripts/community-repo.sh status` to confirm nothing is left unpushed,
   then `teardown`.

Merged transforms sync to the Monad platform automatically.

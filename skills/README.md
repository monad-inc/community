# Skills

Instructions and helper scripts that let an AI coding agent do a Monad task
well. Each skill is a directory with a `SKILL.md` (YAML frontmatter with `name`
and `description`, then Markdown instructions) plus the scripts, templates, and
reference material it uses. Nothing in a skill is tied to a particular model or
agent product.

## Catalog

| Skill | What it does | Target | Requires |
|---|---|---|---|
| [`ocsf-transform-builder`](ocsf-transform-builder/) | Build, validate, and audit jq transforms that map vendor records to OCSF events | [community-transformations](https://github.com/monad-inc/community-transformations) `ocsf/` | `jq`, `yq` v4, `curl`, `git` |
| [`ecs-transform-builder`](ecs-transform-builder/) | Build and validate jq transforms that map vendor records to Elastic Common Schema (ECS) documents | community-transformations `ecs/` | `jq`, `yq` v4, `curl`, `git` |
| [`cef-transform-builder`](cef-transform-builder/) | Build and validate jq transforms that map vendor records to CEF (ArcSight) messages | community-transformations `cef/` | `jq`, `yq` v4, `git` |

All three can optionally use the [Monad MCP server](https://app.monad.com/docs/mcp/index)
to pull live sample records and test a transform in a real pipeline.

## Using a skill

**Agents that support `SKILL.md` skills natively:** copy (or symlink) the skill's
directory into the location your agent loads skills from, keeping the directory
name. Your agent's documentation says where that is. The agent then picks the
skill up from its `description` when a request matches.

**Any other agent:** keep the skill directory on disk, give the agent the
contents of `SKILL.md` as instructions (a system prompt, rules file, or the
first message), and tell it the directory's path so the relative links to
`scripts/`, `references/`, and `templates/` resolve. The agent needs shell
access to run the scripts.

The scripts also work on their own; each prints usage when run without
arguments.

## Layout

```
skills/
├── README.md                  # this catalog
└── <skill-name>/
    ├── SKILL.md               # required: frontmatter + instructions
    ├── scripts/               # helper scripts the instructions call
    ├── references/            # supporting docs and bundled data
    └── templates/             # starting files the skill copies from
```

Each skill is self-contained so it can be installed on its own. Some content is
deliberately duplicated across the three transform builders and must stay
identical: `scripts/community-repo.sh`, `scripts/run-transform.sh`,
`scripts/jq-helpers.sh`, `references/contributing-workflow.md`,
`references/jq-helper-fixtures.json`, and the **Standard jq helpers** section
of each `SKILL.md` (the source of truth for the shared jq functions). Check with:

```bash
for f in scripts/community-repo.sh scripts/run-transform.sh scripts/jq-helpers.sh \
         references/contributing-workflow.md references/jq-helper-fixtures.json; do
  cmp ocsf-transform-builder/$f ecs-transform-builder/$f && cmp ocsf-transform-builder/$f cef-transform-builder/$f
done
section() { awk '/^## Standard jq helpers/{p=1;print;next} p&&/^## /{p=0} p' "$1/SKILL.md"; }
for s in ecs cef; do
  diff <(section ocsf-transform-builder) <(section $s-transform-builder) >/dev/null || echo "helpers section differs: $s"
done
```

## Adding a skill

See [`../CONTRIBUTING.md`](../CONTRIBUTING.md#adding-a-skill).

# Contributing

## Layout

```
.claude-plugin/marketplace.json   # Marketplace catalog: every plugin and its version
orchestra/                        # The Orchestra plugin
  .claude-plugin/plugin.json      # Plugin name, version, author, repository, license
  skills/orchestrator/            # SKILL.md, scripts/, agents/openai.yaml (Codex metadata)
  skills/player/                  # SKILL.md, scripts/, agents/openai.yaml
  tests/                          # Unit tests (mock tmux) and a real-tmux smoke test
```

Each plugin lives in its own top-level directory and installs on its own. Conventions for
coding agents working here are in [CLAUDE.md](CLAUDE.md).

## Try a change

Load the plugin from your checkout in Claude Code:

```bash
claude --plugin-dir ./orchestra
```

For Codex, install the skills from the checkout, then start a new session. Rerun after
each edit, since the installer copies the files:

```bash
npx skills@latest add . --global --agent codex --skill orchestrator player
```

## Run the tests

From the repository root:

```bash
python3 orchestra/tests/test_port.py
bash orchestra/tests/smoke_tmux.sh
```

Both use temporary Git repositories and fake agent CLIs, so they make no model calls.
The smoke test needs tmux and runs it on an isolated socket. Neither covers live model
sessions, delivery through `codex queue`, or a spawn on a real second machine.

## Versions

Plugins use semver. Claude Code caches an installed plugin by version, so a change reaches
users only when the version changes. When you bump a plugin's version, change it in both
`<plugin>/.claude-plugin/plugin.json` and the plugin's entry in
`.claude-plugin/marketplace.json`, in the same commit.

## A good pull request

- Does one thing. For anything beyond a small fix, open an issue first that states the
  outcome you want, and link it.
- Has a [Conventional Commits](https://www.conventionalcommits.org/) title, such as
  `fix(orchestra): …` or `docs: …`.
- Describes what the code does after the change, grouped by what it adds or changes, with
  pointers to the files involved.
- Adds or updates tests for changed behavior, and updates the README when a command or
  option changes.

# notaharness/plugins

This repo is the `notaharness` Claude Code plugin marketplace. It distributes plugins
through `.claude-plugin/marketplace.json` and, where a plugin supports it, shared
skills to other agents (e.g. Codex) through Vercel's skills CLI.

## Structure

```
.claude-plugin/
  marketplace.json      # Marketplace definition: catalog of plugins and their versions
orchestra/               # Plugin: Orchestra (orchestrator + player skills)
  .claude-plugin/
    plugin.json          # Plugin metadata: name, version, author, repository
  skills/
    orchestrator/        # Shared SKILL.md, scripts/, agents/openai.yaml
    player/               # Shared SKILL.md, scripts/, agents/openai.yaml
  tests/                  # Mock-tmux unit tests and a real-tmux smoke test
conversations/           # Plugin: Conversations (a Claude Code mod)
  .claude-plugin/
    plugin.json          # Plugin metadata, and the $.state contract under "types"
  hooks/register.tsx     # The hooks module
  types/index.d.ts       # $.state contract
  tests/                  # claude plugin test suite
```

Each plugin lives in its own top-level directory with its own `.claude-plugin/plugin.json`.

## Conventions

- Each plugin must be installable standalone: don't add cross-plugin dependencies.
- Version plugins with semver. When bumping a plugin's version, update it in **both**
  `<plugin>/.claude-plugin/plugin.json` and that plugin's entry in
  `.claude-plugin/marketplace.json` in the same change.
- Keep a plugin's `repository` field pointing at `https://github.com/notaharness/plugins`.
- Adding a new plugin:
  1. Create `my-plugin/.claude-plugin/plugin.json` with `name`, `version`, `description`,
     `author`, `repository`, `license`.
  2. Add hooks, commands, skills, or scripts as needed.
  3. Register it in `.claude-plugin/marketplace.json`:
     ```json
     {
       "name": "my-plugin",
       "source": "./my-plugin",
       "description": "What it does",
       "version": "1.0.0",
       "author": { "name": "notaharness" },
       "license": "MIT"
     }
     ```

## Testing a plugin locally

Load a plugin directly for development, without touching the marketplace catalog:

```bash
claude --plugin-dir ./orchestra
```

Or install from this repo as a local marketplace, exercising the same path a real
install would use:

```bash
/plugin marketplace add /home/hermann/Documents/Code/Personal/plugins
/plugin install orchestra@notaharness
```

## Orchestra-specific conventions

- Two cooperating skills: the orchestrator spawns players (one tmux session + git
  worktree + branch each) and the player reports back through
  `skills/player/scripts/report.sh`. Scripts resolve each other relative to their
  real location, including installer symlinks.
- Keep `orchestrator` and `player` as siblings and install them together; the
  orchestrator relies on the player's reporting helpers.
- Maintain one shared `SKILL.md` per skill, with Claude-specific invocation and path
  guidance clearly labeled and Codex metadata in `agents/openai.yaml`. Do not create
  client-specific copies of the instructions.
- Session names are labels (`<repo dir>-<branch>`, with a numeric suffix on collision);
  identity lives in the `@orchestra-*` tmux session options. Those options and the
  worktree location (`.claude/worktrees/`) are shared with n10; do not change them.
- Backends: tmux wherever it is installed, unchanged, and never a probe for n10; only without
  tmux the scripts drive a running n10's sessions through `n10 mux` (`skills/player/scripts/_mux.sh`).
- Tests (no model calls, isolated tmux socket; the last needs `n10` on PATH and no tmux, and CI
  builds it from the commit in `orchestra/tests/n10.sha`; move that pin with n10's mux contract):
  ```bash
  python3 orchestra/tests/test_port.py
  bash orchestra/tests/smoke_tmux.sh
  bash orchestra/tests/mux_e2e.sh
  ```

## Conversations-specific conventions

- A mod: one hooks module of function hooks against the mod API. Use only documented API
  (code.claude.com/docs/en/plugins/mods and the types Claude Code lays in
  `.claude-plugin/types/`, which stay untracked).
- Standalone: no reference to Orchestra or any workflow.
- Checks (no model calls):
  ```bash
  claude plugin validate --strict ./conversations
  claude plugin test ./conversations
  ```

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
       "author": { "name": "notaharness" }
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
- Tests (no model calls, isolated tmux socket):
  ```bash
  python3 orchestra/tests/test_port.py
  bash orchestra/tests/smoke_tmux.sh
  ```

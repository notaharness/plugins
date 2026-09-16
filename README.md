# notaharness/plugins

This is the Claude Code plugin marketplace for [notaharness](https://github.com/notaharness), an org publishing reusable, agent-agnostic tooling for running coding agents: worktrees, tmux sessions, and orchestration across them. The integrated app that builds on this tooling lives at [github.com/notaharness/n10](https://github.com/notaharness/n10) ([n10.is](https://n10.is)). The plugins here are the standalone, agent-agnostic pieces of that work, packaged for Claude Code.

## Install

Add the marketplace once, then install a plugin from it:

```text
/plugin marketplace add notaharness/plugins
/plugin install orchestra@notaharness
```

## Plugins

### Orchestra

Orchestra lets one conversation coordinate several coding agents across your repositories. Each agent, called a **player**, works on its own branch in a git worktree and tmux session, and sends progress, questions, and results back to an **orchestrator** conversation.

- Supports Claude Code and Codex CLI as both orchestrator and player; Gemini, Copilot, and OpenCode can also be launched as players with more limited resume support.
- Provides two skills: `orchestrator` (spawns and supervises players) and `orchestra:player` (works in its worktree and reports back).
- The orchestrator's scripts (`sessions.sh`, `spawn.sh`, `screen.sh`, `send.sh`, `adopt.sh`, `kill.sh`) manage tmux sessions and git worktrees; the player reports through `report.sh`.
- Works across repositories, and can also be installed for Codex and other agents through [Vercel's skills CLI](https://github.com/vercel-labs/skills).

See [`orchestra/README.md`](./orchestra/README.md) for installation details, requirements, and the full command reference.

## Repository layout

```
.claude-plugin/
  marketplace.json    # Marketplace catalog: lists every plugin and its version
orchestra/             # Plugin: Orchestra
  .claude-plugin/
    plugin.json        # Plugin metadata (name, version, author, repository)
  skills/
    orchestrator/       # SKILL.md, scripts/, agents/openai.yaml
    player/              # SKILL.md, scripts/, agents/openai.yaml
  tests/                 # Unit tests (mock tmux) and a real-tmux smoke test
```

Each plugin directory is self-contained and installable on its own. `.claude-plugin/marketplace.json` is the catalog that ties them together for `/plugin marketplace add`.

## License

MIT

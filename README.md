# notaharness plugins

Plugins and agent skills from [notaharness](https://github.com/notaharness), for Claude Code,
Codex and other coding agents.

| Plugin | What it does |
| --- | --- |
| [Orchestra](orchestra/) | One agent hands tasks to other coding agents, each working on its own branch in its own tmux session and git worktree, and receives their progress, questions and results. |

## Install

Orchestra needs tmux, Git and an authenticated `claude` or `codex` CLI; see the
[full requirements](orchestra/README.md#requirements).

### Claude Code

```text
/plugin marketplace add notaharness/plugins
/plugin install orchestra@notaharness
```

### Codex and other agents

Install the skills with [Vercel's skills CLI](https://github.com/vercel-labs/skills) (needs
Node.js):

```bash
npx skills@latest add notaharness/plugins --global --agent codex --skill orchestrator player
```

Leave out `--agent codex` to choose agents from a list.

## Use

In Claude Code:

```text
/orchestra:orchestrator Add search to this repo and open a draft PR.
```

In Codex, start a new session and use `$orchestrator` with the same text. See the
[Orchestra README](orchestra/README.md) for everything else.

The same tooling is built into [n10](https://github.com/notaharness/n10) ([n10.is](https://n10.is)),
a desktop app for running coding agents.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). Report security issues privately as described in
[SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)

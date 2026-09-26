# Security policy

## Supported versions

Only the latest release of each plugin receives security fixes. The current version is
in the plugin's `.claude-plugin/plugin.json`.

## Reporting a vulnerability

Report it privately through
[GitHub private vulnerability reporting](https://github.com/notaharness/plugins/security/advisories/new).
Do not open a public issue.

Include what an attacker can do, the steps to reproduce it, and the plugin version.
For Orchestra, the main concern is anyone other than you getting text into an agent's
session, whether through a player report, `relay.sh`, a paired machine or a tmux socket.

## What happens next

- You get a reply within 7 days confirming the report was received.
- We tell you whether we can reproduce it and keep you updated while it is fixed.
- The fix ships in a new release, followed by a published GitHub security advisory.
  You are credited in the advisory unless you ask not to be.

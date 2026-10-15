# Security policy

The harness runs commands in your repositories and serves a local web app, so we take security reports seriously.

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub's **"Report a vulnerability"** button on this repository's
Security tab. Do not open a public issue.

Include what you found, how to reproduce it, and the impact you expect. We aim to acknowledge reports within a few
working days.

## Scope

Especially interesting:

- a way for model output or repository content to run a command, write outside the run's worktree, or reach the
  network;
- a way for a web page to drive the local app (DNS rebinding, cross-site requests, HTML injection);
- API keys or tokens ending up in logs, records or prompts.

## Supported versions

Only the latest release is supported.

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

## Known advisories

| Advisory | Affects the harness? | Notes |
| --- | --- | --- |
| [ruby2shell](https://verialabs.com/ruby2shell/), GHSA-34m4-m9fh-gqp5 (Ruby heap overflow in case conversion) | **No**, since 0.1.66 | Case is changed only through `Harness::Ascii`, on raw bytes; `test/ascii_test.rb` blocks any other call in `lib/`. Before 0.1.66, the only call that network input could reach was in `harness demo`'s scripted model server, which listens on 127.0.0.1 only, and only on a machine whose locale uses a legacy single-byte encoding; the other calls saw environment variable names and folder paths from the local user. `harness doctor` reports an affected Ruby; upgrade to 3.3.14, 3.4.13, 4.0.10 or newer. |

## Supported versions

Only the latest release is supported.

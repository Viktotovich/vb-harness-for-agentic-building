# Contributing

Thanks for helping. A few rules keep the harness safe and model-agnostic:

- **Zero gems.** Only Ruby's standard library and default gems on the allowlist in `test/support/guard_scan.rb`.
- **Subprocesses** only through `Harness::Exec`, as argv arrays. No backticks, `%x`, `system`, `spawn`, `exec` or
  `IO.popen`.
- **No model names** in `lib/` or `prompts/`. Model details belong in config profiles and probe results.
- **Nothing personal or secret** in any file: no local paths, usernames, hostnames, keys or tokens. Use
  placeholders such as `/path/to/repo` and `http://127.0.0.1:8080/v1`.
- Every Ruby source file starts with the `frozen_string_literal`, SPDX and copyright header lines.
- Value objects use `Data.define`; data from outside goes through one `parse` method that raises a precise error.
- Public methods carry YARD-style `@param` / `@return` / `@raise` comments.
- Commit messages follow Conventional Commits (`feat:`, `fix:`, `docs:`, `chore:`, `test:`, `refactor:`).

## Checks

There is no hosted CI: checks run on your machine and again on a maintainer's before a merge.

1. Run `ruby bin/check`. It needs Ruby >= 3.3 and git, and no model server, network or GPU.
2. Paste its last three lines (`syntax`, `guardrails`, `tests`) into the pull request, with your OS and Ruby
   version. The pull request template has a place for them.
3. A maintainer runs `ruby bin/check` on your branch before merging, on Windows and Linux where they can.

Please don't add GitHub Actions workflows. The guardrail tests in `test/guardrails_test.rb` must never be weakened
or deleted; if one blocks a change you need, open an issue first to discuss it.

By contributing you agree that your contribution is licensed under the Apache License 2.0.

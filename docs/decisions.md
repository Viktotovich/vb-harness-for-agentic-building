# Decisions

Departures from the spec's SHOULD defaults, and choices the spec leaves open. Newest last.

## M0: repository skeleton

- **Version in its own file.** `Harness::VERSION` lives in `lib/harness/version.rb` (required by `lib/harness.rb`)
  so the gemspec can load it without loading the whole library.
- **Minimal `Harness::Exec` already in M0.** `bin/check` must run `ruby -wc` and the tests as subprocesses, and the
  only allowed way to do that is `Harness::Exec`. M0 ships argv-only running, a scrubbed environment, a timeout
  (process-group kill on POSIX, `taskkill /T /F` on Windows) and an output cap. Windows `PATHEXT`/`.cmd`
  resolution and the full test set for timeouts and caps follow in M1.
- **`[cmd, argv0]` form.** `Exec` calls `Open3.popen3(env, [argv[0], argv[0]], *rest, ...)`. With a plain
  one-element argv, Ruby may hand the string to a shell; the pair form never does.
- **Reader threads, not `IO.select`.** `IO.select` does not work on pipes on Windows, so stdout and stderr are
  drained by one thread each.
- **I1 matches at a word start.** The denylist is matched case-insensitively, but not after a letter or digit.
  Otherwise the provider name "ollama" (section 11.2) would count as a model family.
- **I3 scan scope and method.** The scan covers `lib/`, `exe/` and `bin/`. Comments and simple string literals are
  blanked first, so a chat role named "system" is not a hit. The pipe forms of `open`/`IO.read` are matched on the
  raw line.
- **I13 secret patterns need a body.** `sk-` must not follow a letter or digit and needs 16+ key characters, so
  `task-1` or `disk-usage` do not match; `ghp_`, `github_pat_` and `AKIA` likewise need their key body. The file
  set is what git would commit (`git ls-files --cached --others --exclude-standard`), with a directory walk as a
  fallback when git is missing.
- **Scanners live in `test/support/guard_scan.rb`.** The denylist and shell patterns must not appear in `lib/`.
  Every scanner has a positive self-test, so an empty result means "clean", not "scanner broken".
- **No `stringio` in tests.** It is not on the I14 allowlist, so tests use a small `TestSupport::Sink`.
- **CLI.** `harness --version` and `--help` work; every subcommand reports "not implemented yet" with exit code 2
  until its milestone lands.
- **Spec and agent notes stay outside the repository.** The design spec and the agent working rules live one level
  above this checkout and are not committed.

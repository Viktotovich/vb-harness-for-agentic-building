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

## M1: config, Exec, model layer

- **Batch files run directly, not through `cmd.exe /d /s /c`.** Checked on Windows: Ruby quotes each argument,
  so a resolved `.cmd` path with spaces (e.g. a Node install under Program Files) breaks under `cmd /s /c`. Passing
  the resolved `.cmd` path straight to `Open3.popen3` lets Ruby wrap it in `cmd.exe` with the right quoting.
  The safety rule stays: arguments to a `.cmd`/`.bat` that contain `& | < > ^ % "`, CR or LF are refused
  (`UnsafeArgumentError`). `Exec.resolve` follows `PATH` and `PATHEXT` and never picks an extensionless shim.
- **A timed-out process reports `exit_code: nil` on every OS.** `taskkill /F` leaves exit status 1 on Windows.
- **Pure-Ruby SHA-256 fallback.** Some Windows application-control policies block `digest.so` (and
  `openssl.so`). `Harness::Sha256` uses `Digest` when it loads, else a FIPS 180-4 implementation checked against
  the standard vectors. Without OpenSSL, `https` endpoints are unavailable on such machines; local `http` works.
- **Probe order.** Thinking control is probed before structured output, tools and throughput, so those requests
  run with thinking off and stay short. The JSON-schema check asks a question whose natural answer is prose,
  so a server that ignores `response_format` is not mistaken for one that enforces it. A thinking control
  counts only when it cuts the answer length by at least 20%.
- **Thinking-off request fields** (one per control, in `Wire::THINKING_OFF`): `chat_template_kwargs.enable_thinking
  = false`, `reasoning_effort = "none"`, `thinking_budget_tokens = 0`. They are generic request parameters; the
  probe decides which one a server honours.
- **The schema goes into the system prompt in `json_object` mode too,** not only in `prompt` mode: `json_object`
  guarantees JSON syntax but not the shape.
- **`Completion` has one extra field, `tool_calls`,** which the review tool loop (M6) needs.
- **Usage is summed over every request a call made** (first try, shrink, retry). Records hold one file per HTTP
  request with its outcome (`ok`, a `model.*` reason, `busy:429`, `shrink:N`, `overflow`, `unavailable`).
- **"At most N" shrinks once to N** whenever N is below the current `max_tokens`, as the spec says; if the
  server still refuses, it is a context overflow.
- **`complete_each` batches** ask for `{"items": [...]}` with exactly one entry per item and split into single
  calls on `ModelOutputError` or `ContextOverflowError`. Each item's `Completion` shares the batch's text and usage.
- **Config is strict:** unknown keys are errors (keys starting with `_` are comments). Env overrides:
  `HARNESS_<PROFILE>_BASE_URL` and `HARNESS_<PROFILE>_MODEL`, with the profile name upper-cased and other
  characters turned into `_`.
- **Token estimate:** 3 bytes per token plus 4 per message, deliberately pessimistic.

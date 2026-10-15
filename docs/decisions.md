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

## M2: worktree, paths, edits, gates, baseline

- **`.git` is always protected,** whatever `protectedPaths` says. Glob matching adds `File::FNM_SYSCASE`, so on
  Windows `.GIT/config` and `.Env` are caught too, and a pattern ending in `/**` covers every depth below it.
  Path segments containing `:` are refused (drive letters, NTFS alternate data streams).
- **The I2 check runs twice per write:** when an edit is staged and again right before the file is written.
- **Edits apply all or nothing.** If any edit is rejected, nothing is written and every rejection is returned,
  so the caller can give the model one retry for the rejected edits. If a write fails midway, files already
  written are restored. A whole-file rewrite needs the file to be under `wholeFileRewriteMaxBytes` and listed
  in `files.modify`. Replace edits keep the file's own line endings.
- **Reverting a task** runs `git checkout -- .` and `git clean -fd`, then deletes the files the task created by
  name, because `git clean -fd` leaves ignored files alone.
- **`blocked.patch` without staging:** `git diff HEAD` for tracked files plus `git diff --no-index -- /dev/null
  <file>` for each untracked file. The harness never stages until it commits, so a revert stays a plain
  checkout and clean.
- **Git allowlist** (`Repo::Git::ALLOWED`) matches whole command shapes, e.g. `checkout -- .` only and
  `worktree add -b <branch> <dir> HEAD` only, and refuses `--exec`, `--output`, `--upload-pack`,
  `--receive-pack`, `--ext-diff` and `--textconv` anywhere.
- **Gate env adds `COMSPEC`** to the base list (Windows needs it to run `.cmd` files) and sets
  `npm_config_yes=false`. With `CI=1` and no TTY, npx would otherwise install a missing package without asking,
  which I10 forbids. Output saying the tool is missing (`could not determine executable to run`,
  `is not recognized as an internal or external command`, ...) makes the gate `skipped` with that reason.
- **Placeholders:** an empty `{files}` skips the gate ("no files to check"). An empty `{tests}` is dropped so the
  whole suite runs (baseline and integration). A path starting with `-` is passed as `./-name`.
- **The baseline runs every gate that does not need touched files** (scope `project` and `tests`, both phases),
  not only project gates and unit tests, so integration gates have something to be compared with in M3.
- **Baseline comparison:** diagnostics are matched as a multiset by (file, code, message), ignoring line
  numbers. Unparsed output compares by its last 60 lines. Timeouts compare by status. A skipped gate is never
  `ok?` (I6).
- **Parsers in M2:** `tsc` and `astro_check` (both tsc formats), eslint "stylish", and minimal `vitest` and
  `playwright` failure lines. Anything else falls back to the last 60 lines.

## M3: the per-task loop

- **Everything a model wrote is fenced when it goes back to a model,** including the plan's task text and the
  previous reply in an apply retry. The retry is one user message ("your previous reply" fenced, plus the
  fenced rejections), not an assistant turn, so I9 holds without exceptions.
- **The untrusted fence tag is `untrusted-data`** (REVIEWER used `untrusted-pr-data`). Injection patterns
  are ported unchanged.
- **Prompt templates** carry the SPDX header as ERB comments, which render as nothing. The edit rules are
  shared between implement and fix through one partial template.
- **Review is a placeholder until M6:** the loop emits a `skipped` event with subject `review` and moves on.
- **A task's final outcome event uses subject `task`** (done at `task.commit`, blocked at `task.commit`,
  skipped at `task.gather`). The fold uses that subject to set task status, so `skipped` events for other
  things (e.g. review) do not change a task.
- **A gate that is skipped during a task blocks it at once** (`gate.skipped:<gate>`): no fix can install a
  missing tool. A gate named in acceptance but not defined by the stack counts as skipped.
- **When a failing gate has no parsed new diagnostics** (timeout, unparsed output), the fixer gets one
  synthetic diagnostic with the gate's reason, and "the same errors twice" compares those too.
- **A model outage stops the queue:** the current task is blocked with `model.unavailable` and reverted, the
  remaining tasks are skipped, integration does not run, and the exit code is 2, so the run can be resumed
  (M4).
- **Integration runs the `integration` gates and every `tests`-scope gate,** without file arguments (the
  whole suite), and compares them with the baseline. A non-blocking gate never fails the run.
- **Gathering in M3** packs the task text, the full text of `modify` and `create` files (required; otherwise
  `TaskTooLargeError`, recorded as `plan.too_large_for_context`), then `read` files and completed-task
  summaries if they fit. Map signatures and docs come with M5. Protected paths are never read into a prompt.
- **`harness run` needs `--from-plan` until the planner lands (M4).** Runs, logs and the probe cache live next
  to the config file.

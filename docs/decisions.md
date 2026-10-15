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

## M4: planner, plan checks, questions, resume

- **New reason code `plan.unknown_gate`:** an acceptance item that names a gate the stack does not define. It
  would otherwise block every task as "skipped", so the planner is told at once.
- **Outside-the-repo paths in a plan** report as `plan.protected_path` with the message "is outside the
  repository"; the spec lists no separate code for them.
- **A plan given with `--from-plan`, or edited after `--plan-only`,** goes through the same checks but is not
  replanned. Problems stop the run as `plan_rejected` (exit 1) with the messages printed.
- **After `maxReplanRounds` replans the run stops as `plan_rejected` (exit 1),** with the last plan saved and
  every problem printed, as "stop and show the user" asks.
- **The planner's repository view until M5:** the file list (with sizes, skipping dependency, build and binary
  files) plus the full text of files whose path contains a word from the request, packed into two thirds of
  the planner's budget. The context map replaces this in M5.
- **The request itself is not fenced;** it is the user's instruction. Everything else the planner sees (file
  list, files, its previous plan, check messages, and the question and answer pairs) is fenced.
- **Questions:** only blocking questions pause the run (status `waiting`, exit 3). `harness answer RUN_ID`
  takes one answer per blocking question, from `--answers FILE` (a JSON array) or typed on stdin. The answers
  go back to the planner, which plans again, and may ask again.
- **Resume rules per task state:** `pending`, `gathering`, `implementing` and `applying` revert the task's
  partial work and start over. `applied`, `gating`, `fixing`, `reviewing` and `committing` continue at the
  gates with the saved fix rounds and touched files. A task whose commit is already HEAD is done. `done` and
  `blocked` keep their outcome, except `blocked` by `model.unavailable`, which runs again. A task with no saved
  state starts from a clean worktree.
- **The lock lives at `runs/<runId>/harness.lock`,** not in the worktree, where `git add -A` would commit it.
  One run is one worktree, so this is the same "one run per worktree" rule.
- **Run statuses** in `run.json`: `planning`, `waiting`, `planned`, `plan_rejected`, `running`, `done`, `failed`,
  `stopped`.

## M5: context map and packing

- **Files the map leaves out** are the REVIEWER `skipReason` lists (binaries, lockfiles, build output, generated
  and minified files, lines over 1000 bytes), plus `.git/`, `.cache/`, files over 1 MB and every `protectedPaths`
  match. A protected file is never listed, described or summarised.
- **The map cache** is `.cache/map/<sha256>.json`, keyed by the file's language and content hash, so a rescan
  reads every file but parses only changed ones. Summaries are cached next to it by content hash.
- **Import resolution:** relative specifiers, the `~/` and `@/` aliases (both read as `src/`), a `.js` or `.jsx`
  specifier that names a `.ts` or `.tsx` file, and `index` files. Package imports and `tsconfig` paths beyond
  those two aliases are not resolved.
- **A signature** is the file's path, language and size, its route, `getStaticPaths`, resolved imports, export
  names, content collections, the `Props` type text, and each export line as written. Ruby and Python files
  list their `class`, `module` and `def` lines.
- **Content collections** are found where `defineCollection` is assigned (`const blog = defineCollection(...)`).
  The file holding that call is where the schema lives.
- **Packing is strict:** sections go in priority order, and once one does not fit, it and everything after it
  are omitted, so the lowest priorities are always trimmed first. The one fallback is a `files.read` file that
  does not fit in full: its signature is tried in the same place.
- **Diagnostics and the diff in a fix round are counted before every optional section** and never trimmed. The
  loop already caps diagnostics at `maxDiagnostics`, and a fix round without them is useless.
- **Signatures and summaries cover direct imports and importers** of the task's files (`related`, depth 1),
  nearest first. At most 6 summaries are made per bundle. The planner overview uses depth 2 and at most 8.
- **Summaries come from the summarizer role** and are made only when a bundle has room for them. A model failure,
  or a reply that reads like an instruction (I9), means no summary. Large files are cut to the summarizer's
  context first.
- **Docs passages (priority 5) are not packed yet.** They need the REVIEWER docs retrieval, which comes with
  the review port in M6.
- **A task that does not fit at run time is still blocked** (`plan.too_large_for_context`), not sent back to
  the planner. Plan checks already catch this before the run starts, so the run-time case means the files grew
  during the run.

## M6: review port and the section 8 changes

- **Evidence is the local docs checkout only.** Version detection, the BM25 index, the checkout index and the
  retriever are ported. REVIEWER's online docs, network guard and dataset are not: online retrieval needs https,
  and neither is needed for the gate to stay honest, since missing docs make framework claims abstain, never
  accept. The stack's `docs.local` points at a checkout; `docs.siteUrl` (optional) builds links for the report.
- **Framework claims** are recognised with REVIEWER's Astro markers when the stack's framework is Astro. For other
  frameworks only a verdict of `claim_type: framework-api` naming the framework counts.
- **Fetch tools** (`read_file`, at most 120 lines a call, and `find_symbol`, at most 3 files) go through
  `Repo::Paths` (I2) and come back fenced (I9). Everything they return is added to the code the gate checks quotes
  against. `lookup_docs` is offered only when docs are configured. Unknown tools get an error text.
- **Without native tool calls** the model replies `{"lookup": {"tool", "args"}}` or `{"done": true}`.
- **The verifier's schema** adds `depends_on_unseen`, `unseen` and `requires_type_violation`. An accept with
  `depends_on_unseen` abstains (`verify.unseen_code`). `requires_type_violation` rejects
  (`verify.requires_type_violation`) when every type-checking gate (parser `tsc` or `astro_check`) passed for the
  task; with no such gate it has no effect.
- **The challenge** has the same fetch tools and a required `unseen` field. A non-empty `unseen` abstains
  (`verify.unseen_code`) whatever the rest says; only a concrete concession survives.
- **Confirm by test:** the fixer writes one test, named `harness-confirm-<task>-<claim>` next to the project's
  first test file (with its suffix), or under `tests/` with `.test.ts`. It is run with the stack's task-phase
  `scope: tests` gate and compared with the baseline, then deleted. A regression confirms; a pass is
  `confirm.test_passes`; no test gate, no test, or a test that could not run is `confirm.test_not_writable`.
- **Follow-up fix tasks** are `<task>R<n>`, depend on the reviewed task, modify the claim's file, and accept on
  the confirming test plus the parent's gate items. They run right after their parent, are appended to
  `plan.json` (resume knows them), and get their test from `tasks/<id>/confirm-test.json`. A follow-up's own
  review makes no further tasks.
- **Review results** are saved as `tasks/<id>/review.json` and `final_review.json` (findings, questions,
  abstained, rejected, suspicious, failures) for the report in M7. A model outage during review is recorded and
  the commit goes ahead; the next model call stops the run as before.
- **The final review** runs once over `base..HEAD` after integration, with confirmation by test but no follow-up
  tasks. Diffs for review carry 10 lines of context.
- **Limits not in DESIGN.md:** at most 6 diff chunks of up to 1500 lines and 60% of the reviewer's budget, one
  re-evaluation round, verification batches of 3 that split to single claims on failure, 2 passages per support
  check. Discovery gets docs for at most 4 framework APIs, 700 characters each.
- **Task titles are not in review prompts:** they are planner output, so the subject is just the task id (I9).

### Hardening found in review

- **Git never runs hooks.** Every git command runs with `-c core.hooksPath=<.cache>/no-hooks` (an empty
  directory, checked before each call), and commits also pass `--no-verify`. The allowlist only accepts
  `commit --no-verify -m`. Hooks are repository code (or a model's edit to `.husky/`) that would run outside the
  gate allowlist (I3).
- **`.husky` is always protected**, like `.git`, and is in the example stack's `protectedPaths`.
- **Windows path aliases are refused:** a path segment ending in a dot or a space (`.git.`, `.git `) and one that
  looks like a short name (`GIT~1`) are refused before any read or write.
- **Gates cannot install or touch a remote:** a gate whose program is `git` or `gh`, a package manager with an
  install-like subcommand (`install`, `i`, `add`, `ci`, `update`, `upgrade`, `up`, `dlx`), or `npx`/`pnpx`/`bunx`
  with `--yes` is a config error (I4, I10).

## M7: report, init, status and eval

- **The report is built only from the run's files** (run.json, plan.json, task folders, review records, events,
  model records) and rewritten at the end of every run and by `harness report RUN_ID`. Text that came from a
  model is kept on one line, with table pipes and angle brackets escaped, so it cannot add headings, table cells
  or HTML. Integration results are saved as `integration.json` for it.
- **Questions in the report** are the open and answered blocking questions, the planner's non-blocking questions,
  and every review claim that went to confirmation but was not confirmed. Findings list only confirmed claims (I8).
- **`harness status`** prints the progress view of section 11.5 as text, from the event log only. With no RUN_ID it
  shows the newest run; `--watch` redraws every second until the run finishes, waits for answers, or stops after
  planning. "Final review" is a stage in the strip.
- **`harness init`** asks for the server URL, the name of the env var with an API key (never the key, I12), the
  model (listed from `GET /models`, or typed), the context size (`probe` or a number) and an optional docs checkout.
  It validates the result with `Config.parse` before writing. Not ported from the REVIEWER wizard: GitHub owner
  and repos (runs name their repository), cloning the docs (a download), the dataset, and the loopback-only URL
  rule (any OpenAI-compatible endpoint is allowed). Provider detection arrives with onboarding in M8.
- **`dependencyDirs`** (new stack key; `["node_modules"]` in the example astro stack): git-ignored folders that
  are mirrored from the repository into each worktree at intake, as hard links (copies where links fail). Without
  it no Astro gate can run in a worktree, because Node looks for packages only in parent folders. The user's
  folder is only read, and nothing is installed (I10).
- **Eval tasks** point at a prepared local repository through `repo.ref` (a path or `$VAR`, then a commit or
  `HEAD`). Remote URLs are refused, since cloning is a download the harness does not do. `eval/repos/astro-mini`
  is the template; eval/README.md shows how to prepare it with `npm install`.
- **Scoring:** solved means the hidden tests pass with the stack's task test gate (`scope: tests`), run on just the
  hidden files after the run. "Findings confirmed" is confirmed claims / claims sent to confirmation. Regressions
  are integration gates whose verdict is `regressed`. A run that stops waiting for answers is scored unsolved.
  Worktrees are removed after scoring unless `--keep`.
- **Profile mappings** override `roles` and may add `profiles` on top of the base config; with no map, one mapping
  named `config` uses the config as it is.
- **Not verified yet:** the ten hidden tests have not run against a real Astro install here (no Node packages were
  downloaded). They use the container API and may need small fixes on the first manual eval.

## M8: onboarding and the app

- **Fonts:** InterVariable.woff2, InterVariable-Italic.woff2 and OFL.txt from the official Inter 4.1 release
  (github.com/rsms/inter), downloaded with the user's approval. Nothing else is bundled; no CDN.
- **Guardrail changes approved by the user:** the I3 scan skips binary files (the fonts), and still scans every
  text file under `lib/`, `app.js` included (which therefore has no backticks). The I4 call-site test lists four
  places that start processes: the git wrapper, the gate runner, the fixed provider subcommands, and the
  first-start browser opener. A new I4 test pins the provider subcommand list.
- **Server:** one thread per connection, one request per connection, headers up to 16 KB and bodies up to 1 MB.
  Refusals: 421 for a foreign Host, 403 for a missing token or foreign Origin, 400 for a POST without a JSON
  body, 405 for other methods. CSP, nosniff, no-referrer, DENY framing and same-origin policies on every
  response; no CORS headers.
- **The token** is 32 random bytes per start, in a meta tag of the page. GET requests need no token: they change
  nothing.
- **Chat mode** streams through `Model::Stream` (server-sent chunks), with reasoning fields and inline `<think>`
  tags split into a Thinking block. Context fitting keeps the newest messages that fit in the probed context
  minus the output reserve, the system prompt and 600 tokens for the summary; older messages are summarised once
  by the chat's own model and the summary is cached in the chat.
- **Build mode** runs the pipeline in a thread of the app process (no subprocess). The run id is chosen before
  intake so the card appears at once. Events stream by SSE from `after=<seq>`; the page drops events it has seen,
  so reconnects never duplicate. Answers are one per line in the text box.
- **The progress view** folds events in the browser the same way `Events.fold` does; reason texts come from
  `Reasons::TEXT` in each event (`reasonText`).
- **Providers:** LM Studio and Ollama are probed in parallel with 2 s timeouts. CLI actions: `lms server start`,
  `ls --json`, `load <key>`, `ps`; `ollama list`, `pull <name>`, `ps`; model names match
  `/\A[\w.:\/@-]{1,200}\z/`. The first provider set up takes every role; later ones are added as profiles.
  `harness init` runs the same detection and offers what it found.
- **Mirrored dependencies are protected (I11).** Every `dependencyDirs` folder is added to the stack's protected
  paths, and `node_modules` is protected in every stack, so no edit, test or tool result can target them. Every
  file the harness writes in a worktree goes through `Repo::AtomicFile` (a temporary file renamed over the
  target), which replaces a hard link instead of writing through it. Remaining risk: a project tool run by a gate
  could rewrite a mirrored file in place; the gates are the user's own commands.

# vb-harness-for-agentic-building

Get real coding work out of the model on your own machine. The harness plans a feature as small tasks, has your
local model implement them one at a time, proves every change with your project's own type check, lint, build and
tests, and re-reviews what it built with an evidence gate. It is built around the weak spots of local models:
hallucinated APIs and defects, wrong edits, broken JSON, and small context windows.

AstroJS is the first supported stack. Any OpenAI-compatible endpoint works: LM Studio, Ollama, llama.cpp's server,
vLLM, or a hosted API.

**Documentation: [vb-harness.vandbruno.net](https://vb-harness.vandbruno.net)**, with the guides, the cookbook and the design
decisions.

**Status: early development.** Everything below works and is tested, but expect rough edges and changes.

## Fastest path

You need [Ruby 3.3+](#requirements), git, and a model server; [LM Studio](https://lmstudio.ai/) or
[Ollama](https://ollama.com/) is the easiest. Then:

```bash
git clone https://github.com/Viktotovich/vb-harness-for-agentic-building.git
cd vb-harness-for-agentic-building
ruby exe/harness
```

The app opens in your browser. In **Settings · providers**, choose **Use** on a model. Switch to **Build**, pick
your project, describe the feature, and send. Two things stop a run before it starts, each with a message saying
what to do: a project without its dependencies installed (run `npm install` in it first) and uncommitted changes
(commit or stash them).

On the command line instead, `ruby exe/harness init` asks a few questions (Enter accepts each default), and
`ruby exe/harness run --repo ../my-site --request request.md` builds what `request.md` describes.

[![An animated walkthrough of a run: a request, the live progress card, rejected outputs and why, the evidence-gated review, a claim confirmed by a failing test, and the finished Badge component rendered on the pricing page](docs/media/demo-preview.webp)](docs/media/demo.mp4)

*An animated illustration of a run in the app, ending with the component it built, rendered (not a screen recording). Click it for the 1080p, 60 fps video.*

## Contents

- [Fastest path](#fastest-path)
- [How it works](#how-it-works)
- [Requirements](#requirements)
- [Install](#install)
- [Quick start: the app](#quick-start-the-app)
- [Quick start: the command line](#quick-start-the-command-line)
- [Projects and workspaces](#projects-and-workspaces)
- [Understanding a run](#understanding-a-run)
- [Cookbook: an Astro landing page](#cookbook-an-astro-landing-page)
- [Using with Claude](#using-with-claude)
- [Configuration](#configuration)
- [Choosing and checking a model](#choosing-and-checking-a-model)
- [Safety model](#safety-model)
- [Evaluation](#evaluation)
- [Troubleshooting](#troubleshooting)
- [Limitations](#limitations)
- [Why Ruby](#why-ruby)
- [Development](#development)
- [License](#license)

## How it works

![How a run works: a request is planned into small tasks; each task is gathered, implemented as exact edits, applied, checked by your gates with fix rounds, reviewed and committed; then integration gates, a final review and a report. Model steps are purple, steps decided by code are outlined in green.](docs/media/how-it-works.svg)

1. **Intake.** The harness checks your repository is clean, creates a git worktree on a new branch
   `harness/<runId>`, detects the stack, and runs your checks once to record a **baseline**. Anything already
   failing there is compared later, not blamed on the model.
2. **Plan.** A planner model splits the request into small tasks (at most 3 files each, by default), each with
   something that can prove it: a gate (type check, lint, tests) or a test it writes. Plans are checked in code:
   missing files, cycles, tasks that change nothing, tasks too big for the model's context. Problems go back to the
   planner. Questions that block the plan are asked to you.
3. **Each task.** The context is packed to fit the model's window: the task's files first, then signatures and
   summaries of the files they import. The model replies with exact search-and-replace edits; edits that do not
   match the file exactly are rejected with the closest lines, and the model gets one retry.
4. **Gates.** Your own commands decide whether a task is done. New errors go back to the model with the source
   around them, for a few fix rounds. A model saying "done" never marks a task done.
5. **Review.** Two independent review passes propose claims; a verifier checks each against the code it can fetch
   (and, for Astro, version-matched docs); a gate in code rejects or abstains on anything not backed by evidence;
   a challenge argues for the code. A surviving claim becomes a **finding** only if a test the harness writes and
   runs fails because of it, and then it becomes a fix task. Review never blocks a commit on its own.
6. **Report.** Every run ends with `runs/<runId>/report.md`: tasks and commits, gates against the baseline, findings,
   open questions, blocked tasks with their patch, every rejected model output counted by reason, and cost per role.

Your checkout is never changed. The work stays on the `harness/<runId>` branch until you merge it.

## Requirements

- **Ruby 3.3 or newer.** No gems. On Windows, use [RubyInstaller](https://rubyinstaller.org/) (with the Devkit).
- **git.**
- **A model server** with an OpenAI-compatible API, such as `http://127.0.0.1:8080/v1`. A model with at least a
  16K context works; more is better.
- **Your project's own toolchain.** For Astro that is Node.js, with the project's dependencies installed
  (`npm install`) in the repository you build in.

## Install

```bash
git clone https://github.com/Viktotovich/vb-harness-for-agentic-building.git
cd vb-harness-for-agentic-building
ruby exe/harness --version
```

That is all: there is nothing to install with `gem` or `bundle`. To put `harness` on your PATH, either alias
`ruby /path/to/vb-harness-for-agentic-building/exe/harness`, or build and install the gem locally:

```bash
gem build vb-harness.gemspec
gem install ./vb-harness-*.gem
```

The folder that holds `config.json` is the harness's **home**: `chats/`, `runs/`, `logs/`, `.cache/`, `projects/`
and `workspaces/` are created next to it. All of them are git-ignored.

## Quick start: the app

```bash
ruby exe/harness
```

This starts the local app on `http://127.0.0.1:4567/` and, on first start, opens your browser.

1. **Connect a model (Settings · providers).** The app looks for LM Studio and Ollama on this machine. You can
   start LM Studio's server, load a downloaded model, or pull an Ollama model, each with one click. For any other
   server, enter its OpenAI-compatible URL and, if it needs a key, the *name* of the environment variable that holds
   the key (never the key itself). Choose **Use** on a model: the harness probes it and tells you what it found, for
   example "16K context, JSON mode: yes, tools: no, thinking can be turned off". Once a model is set up, the top of
   Settings has **How runs work**: the [mode](#configuration) (Careful, Balanced or Quick), and which model the
   planner, reviewer and verifier use. **Plan & review** on any model makes it that second model, even on the same
   server as the first.

   ![Settings · providers: the app looks for LM Studio and Ollama on this machine; a custom OpenAI-compatible server at 127.0.0.1:8080 has been checked and offers one model to use](docs/media/app-connect-a-model.png)
2. **Chat.** Chat mode is a planning conversation: work out what to build, compare approaches, sketch the steps.
   Ctrl+Enter (⌘+Enter on macOS) sends; Enter adds a line. Replies stream, and thinking text sits in a collapsed
   block. Chat changes no files.

   ![A planning chat: asked about a Badge component for an Astro site, the local model replies with a plan, a sketch of the component and the decisions to make first](docs/media/app-chat.png)
3. **Build.** Switch to Build, pick a project (or **+ Add project**), describe the feature, and send. A live card
   shows where the run is, how many model outputs were thrown away and why. If the planner asks a blocking
   question, the card turns purple: answer in the text box, one answer per line. When the run ends, **Show report**
   opens the report.

   ![Build mode: the request, and a finished run card showing every stage done, task T1 committed, and 9 model outputs produced, 9 accepted and 0 rejected; below, the project picker shows astro-site with its branch, a clean tree and Astro 7.4.0](docs/media/app-build.png)

The app only listens on `127.0.0.1`, refuses other host names, and needs a per-start token for every change.

## Quick start: the command line

```bash
ruby exe/harness init                                   # write config.json, asking a few questions
ruby exe/harness run --repo /path/to/repo --request request.md
ruby exe/harness status                                 # the newest run: tasks, current step, rejections
ruby exe/harness status RUN_ID --watch                  # refresh every second until it stops
ruby exe/harness answer RUN_ID                          # answer the planner's blocking questions
ruby exe/harness resume RUN_ID                          # continue after a stop, a crash or new answers
ruby exe/harness report RUN_ID                          # (re)write runs/RUN_ID/report.md and print its path
```

`request.md` is plain text, as you would write it to a colleague:

```markdown
Add a Badge component at src/components/Badge.astro. It takes a required label and an optional tone,
"info" or "warn" (default "info"), and renders <span class="badge badge--<tone>">. Use it on the pricing page.
```

Useful options:

| Option | Where | What it does |
| --- | --- | --- |
| `--config FILE` | every command | Use another config; runs and caches live next to it. |
| `--json` | every command | Machine-readable output. |
| `--plan-only` | `run` | Stop after planning; edit `runs/<id>/plan.json`, then `resume`. |
| `--dry-run` | `run` | Run intake, the baseline gates and, with `--from-plan`, the plan checks, then stop. No model is called and the worktree is removed. `"dryRun": true` in the config does the same for every `run`. |
| `--require-green-baseline` | `run` | Stop after intake when a blocking gate already fails (see `requireGreenBaseline`). |
| `--review MODE` | `run`, `answer`, `resume` | `full`, `light` or `off` for this run, overriding the config's `review`. |
| `--from-plan FILE` | `run` | Skip the planner and run a plan you wrote (format below). With `--request` too, the request is kept as context for the implementer and reviewers. |
| `--answers FILE` | `answer` | A JSON array of answers instead of typing them. |
| `--port N`, `--[no-]open` | `ui` | The app's port, and whether to open the browser. |

A plan for `--from-plan` is the JSON the planner writes (`runs/<id>/plan.json`), and it is checked the same way:

```json
{
  "tasks": [
    {
      "id": "T1",
      "title": "Add the Badge component",
      "intent": "1-3 sentences: what and why, with every exact value the task needs",
      "files": { "create": ["src/components/Badge.astro"], "modify": [], "read": ["src/styles/global.css"] },
      "dependsOn": [],
      "acceptance": [
        { "kind": "gate", "gate": "typecheck" },
        { "kind": "test", "path": "tests/badge.test.ts", "write": true, "describe": "what the test asserts" },
        { "kind": "assert", "text": "a property the review checks" }
      ]
    }
  ],
  "questions": []
}
```

Each task creates or modifies at most `maxFilesPerTask` files and needs at least one `gate` or `test` item; a
`test` path must be a test file. `read` and `modify` list existing files or files a task in `dependsOn` creates.

Progress lines go to stderr; the result goes to stdout. Exit codes: `0` done, `1` the run failed (planning
failed, a task was blocked, or something regressed), `2` a configuration or environment problem, `3` waiting for
your answers.

## Projects and workspaces

In the app, Build mode works on **projects**:

- **Link an existing folder.** Paste its full path once. The harness checks it is the top folder of a git
  repository and shows its branch, whether it is clean, and the detected stack and version, or exactly what is
  wrong. Linked folders are stored by name in your `config.json`.
- **Clone from a git URL.** A shallow clone of an `https://` URL into `projects/<name>`.
- **New Astro project.** `npm create astro@latest` into `projects/<name>`, then a first commit.

Clone and New Astro project download code, so the app first shows you the exact command and runs it only after you
confirm. The app never lists folders on your disk.

![The Add a project panel: link an existing folder by its full path, clone from a git URL into projects/, or create a new Astro project in projects/; above it, the selected project's status line](docs/media/app-projects.png)

Every run works in its own worktree under `workspaces/<runId>` in the harness's home, on branch `harness/<runId>`.
Folders listed in the stack's `dependencyDirs` (for Astro, `node_modules`) are mirrored into the worktree with hard
links, so your project's tools can run there without reinstalling. The harness never writes to them, and every file it
writes replaces the link instead of writing through it.

To keep the result, merge the branch in your repository:

```bash
git merge harness/RUN_ID
```

## Understanding a run

Everything about a run is in `runs/<runId>/`:

| File | What it holds |
| --- | --- |
| `report.md` | The summary to read first. |
| `events.jsonl` | Every stage and every rejected output, with a reason code. `status` and the app are built from it. |
| `plan.json`, `run.json` | The plan as run, and the run's state. |
| `tasks/<id>/` | Per task: `state.json`, gate results per round, `review.json`, and `blocked.patch` if it was blocked. |
| `records/` | One file per model request: role, profile, model id, tokens, time, outcome, and for a failed request the HTTP status and the server's error text (redacted). Never a key. |
| `final_review.json` | The review of the whole run. |

**Rejections** are the heart of the report: every output the harness threw away is counted by reason, such as
"edit search text not found", "typecheck failed", "depends on code not shown" or "needs a value its type forbids".
Replies that were discarded and retried with thinking off count too. Rejections show where a model struggles, and
they are how you compare models.

![A report in the app: the tasks table with T1 done and its commit, gates compared with the baseline, and empty Findings, Questions and Suspicious text sections](docs/media/app-report.png)

**Findings** in the report are only claims confirmed by a failing test. Everything else the review raised is under
**Questions**, clearly marked as unconfirmed.

## Cookbook: an Astro landing page

[docs/cookbook/astro-landing-page.md](docs/cookbook/astro-landing-page.md) builds a small business landing page
from an empty folder with a local 16K coder model: the new project, the theme, planning in Chat, the Build request
line by line, seven runs (the first two found harness gaps, now fixed; the last four were layout and fixes after
reviewing the page), reviewing the branch and merging it. Every stage has a screenshot.

[![The landing page the cookbook builds](docs/media/cookbook/page-final.png)](docs/cookbook/astro-landing-page.md)

## Using with Claude

Claude Code is good at deciding what to build and at reviewing it; the typing in between is where most of its
tokens go. The harness can take that part. Claude writes the request, starts a run, and reads back a short report
and a diff, while a model on your own machine does the planning, editing, fixing and reviewing in between.

![Claude writes the request (about 740 tokens), the harness and a local model do the work (93,400 tokens), and Claude reads the status, report and diff (about 6,400 tokens)](docs/media/using-with-claude.svg)

**What it saves, measured on the cookbook's third run** (eight tasks, a full landing page):

| | Tokens |
| --- | --- |
| The local model, all of its calls | 93,400 (77,000 in, 16,400 out) |
| Claude: writing the request | ~740 |
| Claude: reading `harness status --json` | ~2,000 |
| Claude: reading the report | ~1,300 |
| Claude: reading the diff (375 lines) | ~3,100 |
| **Claude, in all** | **~7,200** |

About 13 times the model traffic stayed on the local machine. Claude's figures are the sizes of what it would
read and write, estimated the way the harness budgets context (three bytes a token, which errs high); they leave out
Claude's own system prompt and turns. We
have not measured Claude building the same page directly, so this is not a claim about how much that would cost;
it would at least read the files, write the 375 lines and check them, with every turn re-sending the conversation.

The trade is time. A 16K local model one request at a time took a couple of hours for that page. Hand the harness
the work that is clear and self-contained, and keep Claude for the parts that need judgment.

**How to set it up.** Install the harness and connect a local model (see [Install](#install) and
[Choosing and checking a model](#choosing-and-checking-a-model)). Then tell Claude Code how to delegate, in your
project's `CLAUDE.md`:

```markdown
## Delegating to vb-harness

For a self-contained feature (a component, a page, a small refactor), delegate to the local harness instead of
writing the code yourself:

1. Write the request to `.harness/request.md`: exact file paths, exact values (colours, sizes, text), what each
   file imports, and what is out of scope. The harness keeps what the request says and nothing else.
2. Run it in the background: `ruby <harness>/exe/harness run --repo . --request .harness/request.md --json`.
3. Check on it with `ruby <harness>/exe/harness status RUN_ID --json` rather than polling often; runs take
   minutes to hours.
4. Exit code 3 means the planner asked questions: answer with `harness answer RUN_ID --answers answers.json`.
5. When it finishes, read `runs/RUN_ID/report.md` and `git diff main...harness/RUN_ID`. Gates prove the code
   builds, not that it matches the request, so review it. Merge with `git merge harness/RUN_ID`, or send a
   smaller follow-up request.
```

Any command works the same from Claude's side: `--json` on every command gives machine-readable output, progress
goes to stderr, and the exit code says how the run ended (see [Quick start: the command line](#quick-start-the-command-line)).

## Configuration

`harness init` (or the app's Settings) writes `config.json` for you. Start from
[`config.example.json`](config.example.json); every value there is a default or a placeholder.

**Profiles** describe model servers; **roles** say which profile does what:

```jsonc
"profiles": {
  "default": {
    "baseUrl": "http://127.0.0.1:8080/v1",
    "model": "auto",              // "auto" uses the first model the server lists
    "apiKeyEnv": null,            // the NAME of an env var holding a key, or null
    "contextTokens": "probe",     // or a number
    "maxOutputTokens": 4000,
    "thinking": { "control": "probe", "effort": "low", "budgetTokens": null },
    "structuredOutput": "probe",  // json_schema | json_object | prompt
    "toolCalls": "probe",         // native | none
    "timeoutSec": 900
  }
},
"roles": { "planner": "default", "implementer": "default", "fixer": "default",
           "reviewer": "default", "verifier": "default", "summarizer": "default" }
```

Use two profiles to plan and review with a larger model and implement with a faster one. `HARNESS_<PROFILE>_BASE_URL`
and `HARNESS_<PROFILE>_MODEL` override a profile from the environment.

**Stacks** say how to check a project. The Astro stack in the example (each command runs as
`npx --offline --no -- <tool>`, so a tool that is not installed fails at once and npx never downloads one):

| Gate | Command | When | Blocking |
| --- | --- | --- | --- |
| `format` | `prettier --check {files}` | each task, touched files | no |
| `lint` | `eslint {files}` | each task, touched files | yes |
| `typecheck` | `astro check` | each task | yes |
| `unit` | `vitest run {tests}` | tasks with tests | yes |
| `build` | `astro build` | integration | yes |
| `e2e` | `playwright test {tests}` | integration | yes |

Gates are argv arrays, never shell strings. A gate whose tool is missing is reported as **skipped**, never as passed;
it blocks a task only when the task names it in its acceptance.
Gates may not install packages, run `git` or `gh`, or use `npx --yes`. Other stack keys: `detect` (files that
identify the stack), `alwaysGates`, `protectedPaths` (globs the model may never touch; `.git`, `.husky` and
`node_modules` are always protected), `dependencyDirs`, and `docs.local` (a local checkout of the framework's docs,
used by the review; without it, framework claims abstain instead of being confirmed).
Two keys carry what a small model gets wrong about the stack, as plain data: `fixHints` (`{"match": text in a
diagnostic, "hint": what to tell the fixer}`, shown next to a matching diagnostic) and `reviewNotes` (facts and
pitfalls the reviewer and verifier are given). The example's Astro stack has a few, such as "props are
`Astro.props`" and "`{expression}` output is escaped"; add your project's own.

**Limits** (defaults): `maxFilesPerTask` 3, `maxFixRounds` 3, `maxReplanRounds` 2, `maxDiagnostics` 20,
`maxLookups` 6, `maxReviewFixTasks` 2, `wholeFileRewriteMaxBytes` 4096, `maxGateOutputBytes` 204800,
`maxVerifierCalls` 60 (per run), `maxRefutedInARow` 3.

**Review** (`review`, default `full`): `full` reviews every task and the whole run; `light` skips the per-task
review of a small change (80 changed lines or fewer) whose gates passed first time, and keeps the final review;
`off` skips review. In every mode the verifier stops when the run has used `maxVerifierCalls`, or after
`maxRefutedInARow` claims in a row were refuted by the code; the claims left are recorded as unverified
questions, never dropped. Review is the most expensive stage with a small model, so `light` is a good start.

**Modes.** `harness init` asks how careful runs should be, and the app's Settings can change it later; either
writes the matching settings, which you can still edit by hand:

| Mode | `review` | `requireGreenBaseline` | `maxFixRounds` | For |
| --- | --- | --- | --- | --- |
| Careful | `full` | `true` | 3 | Real projects, and weaker models. |
| Balanced (default) | `light` | `false` | 3 | Most work. |
| Quick | `off` | `false` | 2 | Trying things out, small changes. |

It also asks whether to use one model for everything, or a second model (often a larger one) for the planner,
reviewer and verifier, with the implementer and fixer on the first. That writes a `planning` profile and points
those `roles` at it. In the app, **Plan & review** on a model does the same, and Settings picks which configured
model those roles use. A config the app creates starts Balanced, like one from `init`.

**A red baseline.** When a blocking gate already fails before the run, intake says so (an event, and a line at the
top of the report); tasks are still judged only on new problems. Set `requireGreenBaseline` to `true` to stop the
run there instead, before any model call (exit code 2).

**A dry run** (`harness run --dry-run`, or `"dryRun": true` for every `run` on the command line) shows what a run
would start from without calling a model: the stack, each gate's baseline result, the plan's problems when a plan
is given (all but the context-size check, which needs the model), and what would happen next. It exits 0 when
nothing found would stop a real run, 1 for plan problems, 2 for a failing baseline under `requireGreenBaseline`.
The app's Build is never a dry run.

`gateEnvAllow` lists extra environment variables your gates need; everything that looks like a secret is removed
from the gates' environment otherwise.

## Choosing and checking a model

Nothing about specific models is built in. On first use, the harness probes each model: its context size, whether
it can return JSON or call tools, whether its thinking can be turned off, and how fast it is. Values you set in a
profile override the probe. Results are cached in `.cache/probe/`.

Practical advice:

- A coding model with 16K context or more, instruction-tuned, at a quantization that still follows JSON reliably.
- If a reasoning model spends its whole budget thinking, the harness retries once with thinking off. Setting
  `thinking.control` explicitly avoids the retry.
- Compare models with the [evaluation](#evaluation): the same ten tasks, one table per profile mapping.

## Safety model

![Safety model: model output passes six layers before it reaches your repository — fenced untrusted text, exact edits to declared files only, a path guard, your gates deciding done, findings that need a failing test, and a separate worktree and branch with no pushes, no installs and git hooks off. The local app listens on 127.0.0.1 only.](docs/media/safety-model.svg)

The harness assumes the model can be wrong or manipulated, and limits what it can do:

- **Edits stay in the worktree.** Every path is resolved and checked before a read or write: no `..`, no absolute
  paths, no symlinks out, no protected paths, no Windows aliases such as `.git.` or `GIT~1`.
- **No commands from the model.** Only your configured gates and a fixed list of git subcommands run, as argv arrays.
  Git hooks are disabled for every git command the harness runs.
- **No remote writes.** Nothing is pushed, fetched or merged. The only download is a clone you confirm in the app.
- **Scrubbed environment.** Gates run without your tokens and secrets unless you list them in `gateEnvAllow`.
- **Tools decide.** A task is done only when its blocking gates pass or fail exactly as they did at baseline.
- **Untrusted text is fenced.** Repository content, docs, gate output and model output reach a model only inside a
  fenced block marked as data, never as instructions. Instruction-like text in your files ("ignore previous
  instructions", "note to the AI", ...) is also pointed out to the model as data and listed in the report. That
  detection is a pattern match: it catches common phrasings, not every reworded attempt, so it warns and never
  blocks. The fence, the fixed edit format and your gates are what keep a planted instruction from taking effect.
- **Findings need proof.** A review claim is presented as fact only when a test confirmed it.
- **No installs.** The harness never installs your project's dependencies; you do.
- **Your checkout is untouched.** All work happens on a branch in a separate worktree.
- **Keys.** Read only from the environment variable you name; never logged, recorded or shown.
- **The app is local.** It binds to `127.0.0.1` only, refuses foreign hosts, needs a per-start token and its own
  origin for every change, sends a strict Content Security Policy, and renders model output as text, never HTML.

Each of these has a test in [`test/guardrails_test.rb`](test/guardrails_test.rb). See [SECURITY.md](SECURITY.md)
to report a vulnerability.

## Evaluation

`eval/` holds ten Astro tasks of increasing size (a component, a utility, pages, a content collection, API routes,
an island, i18n routes, a blog) with hidden acceptance tests the harness never sees while it works.

```bash
ruby eval/run_eval.rb --config config.json --profile-map eval/profile-map.example.json
```

It prints one table per profile mapping: solved, solved without fix rounds, regressions, findings confirmed, fix
rounds, tokens and time, plus tokens and time per role. Preparing the starting repository is described in
[`eval/README.md`](eval/README.md).

## Troubleshooting

| Symptom | What to do |
| --- | --- |
| "the repository has uncommitted changes" | Commit or stash first. Runs always start from a clean `HEAD`. |
| "node_modules is missing … the project's dependencies are not installed" | Run the install command it names (`npm install`, `pnpm install`, …) in your repository, then start the run again. The harness never installs anything itself. |
| A gate is **skipped**: "tool not installed" | Install the project's dependencies in your repository (`npm install`), and keep `node_modules` in `dependencyDirs`. |
| "model server unavailable" | Check the server is running and `baseUrl` ends in `/v1`. `curl <baseUrl>/models` should list a model. |
| Tasks blocked with "plan too large for context" | Use a model with a larger context, or ask for a smaller change. |
| Many "edit search text not found" | The model is not copying code exactly. A larger or less quantized model usually helps. |
| The planner keeps asking | Answer with `harness answer RUN_ID` (or in the app); the run continues. |
| A run stopped (crash, Ctrl+C, power) | `harness resume RUN_ID` continues from the last saved step. |
| Windows: paths too long | Keep the harness folder short (for example `C:\harness`); worktrees live under it. |
| The model server stays busy after a run | A request the harness gave up on (a timeout, a stop, a crash) is closed on the harness's side; a server that does not notice a closed connection keeps generating until it finishes. Wait, or restart the server. Raise `timeoutSec` if requests time out often. |

## Limitations

- AstroJS is the only stack with a ready-made profile. Others work with your own gates, but without the Astro-aware
  context map and docs.
- Review evidence uses a local docs checkout only; online docs are not fetched.
- Gates run your tools on your machine: a gate is as trustworthy as the command you configure.
- `harness probe`, `cleanup` and `push` are not implemented yet; use `git` directly to push a branch.

## Why Ruby

![Average tokens per Rosetta Code task by language: Ruby is third at about 116, next to Clojure and Julia at 109, and well ahead of JavaScript at 181, Java at 187 and C at 285](docs/media/token-efficiency.svg)

*Chart redrawn from the data in Martin Alderson's
[Which programming languages are most token-efficient?](https://martinalderson.com/posts/which-programming-languages-are-most-token-efficient/)
(values read off the published chart). The study counted tokens for the same Rosetta Code tasks in each language
using a GPT-4 tokenizer. Its author calls it an illustrative comparison, not a rigorous study. TypeScript was left
out for lack of tasks.*

- **Fewer tokens.** Ruby is one of the most token-efficient mainstream languages. In the chart above it needs about
  a third fewer tokens than JavaScript for the same task. A harness built for small context windows benefits twice:
  models read and write less code, and contributors' agents spend less context on the harness itself.
- **Contributing with local models.** Fewer tokens and zero dependencies mean a local model on modest hardware can
  read, change and test this codebase. Contributing doesn't require a large hosted model.
- **Easy to read.** Human contributors can catch up quickly without much effort. TypeScript and its types would have
  been the stronger choice for people alone. This is an agent-first harness, though, so it is written in a language
  that is friendlier to agents and still easy for people.
- **Easy to review.** Ruby is easy to skim when you approve a pull request, read code or leave review comments. That
  matters for a project that expects many outside contributions.
- **A bit of history.** Ruby and Ruby on Rails are what first pulled the author towards AdonisJS and deeper
  TypeScript work. There was never time to learn Ruby properly back then, but its influence stuck. This project is
  the chance to build in it.

## Development

```bash
ruby bin/check   # syntax and warnings, guardrail scans, all tests
ruby bin/test    # tests only (or: ruby bin/test test/path_test.rb)
```

Tests need no model server, network or GPU. There is no hosted CI: run `bin/check` before opening a pull request
and paste its summary, as described in [CONTRIBUTING.md](CONTRIBUTING.md). Design decisions are recorded in
[docs/decisions.md](docs/decisions.md); a manual checklist for the app is in [docs/ui-checklist.md](docs/ui-checklist.md).

## License

Apache-2.0, by [V and Bruno LLC](https://vandbruno.net/). See [LICENSE](LICENSE) and [NOTICE](NOTICE). The bundled
Inter font is under the SIL Open Font License ([OFL.txt](lib/harness/ui/public/fonts/OFL.txt)).

# vb-harness-for-agentic-building

Get the most out of local models for real coding work. This harness plans a feature as small tasks, has your local
model implement them one at a time, proves every change with your project's own type check, lint, build and
tests, and re-reviews what it built with an evidence gate. It is designed around the weak spots of local models:
hallucinated APIs, wrong changes, broken JSON and small context windows.

AstroJS is the first supported stack. Any OpenAI-compatible model works: LM Studio, Ollama or your own endpoint.

**Status: early development (milestone M7: the command line works end to end, with a report per run and an eval suite; the app comes next).**

## Key points

- **Start in a minute.** Run `harness` and the app opens. It finds LM Studio or Ollama, sets them up for you, and
  you are chatting.
- **Chat or build.** Several chats, a model picker, a big text box. Switch a chat to Build mode and it turns your
  message into tested commits on a separate branch.
- **Any model.** Model capabilities (context size, JSON mode, tools, thinking controls) are probed, not hardcoded.
- **Tools decide, models advise.** A task is done when its checks pass, not when the model says so.
- **Small tasks for small contexts.** Every task is sized to fit the model's window.
- **Safe by default.** Works in a git worktree, runs only configured commands, the app only listens on your own
  machine, and nothing is pushed without you.

## Requirements

- Ruby >= 3.3 (on Windows: RubyInstaller). No gems.
- git.
- An OpenAI-compatible model endpoint, e.g. `http://127.0.0.1:8080/v1`.
- The target project's own toolchain (for Astro: Node).

## Command line

```sh
ruby exe/harness init                                   # write config.json, asking a few questions
ruby exe/harness run --repo /path/to/repo --request request.md
ruby exe/harness status [RUN_ID] [--watch]              # tasks, current step, what was rejected and why
ruby exe/harness answer RUN_ID                          # answer the planner's blocking questions
ruby exe/harness resume RUN_ID
ruby exe/harness report RUN_ID                          # (re)write runs/<RUN_ID>/report.md
ruby eval/run_eval.rb --profile-map eval/profile-map.example.json
```

Every command takes `--json` and `--config FILE`. Work happens on the branch `harness/<RUN_ID>` in a separate
worktree; your checkout is never changed. See [eval/README.md](eval/README.md) for the evaluation tasks.

## Development

```sh
ruby bin/check   # syntax and warnings, guardrail scans, all tests
ruby bin/test    # tests only
ruby exe/harness --version
```

Design decisions are recorded in [docs/decisions.md](docs/decisions.md). See [CONTRIBUTING.md](CONTRIBUTING.md)
and [SECURITY.md](SECURITY.md).

## License

Apache-2.0, by [V and Bruno LLC](https://vandbruno.net/). See [LICENSE](LICENSE) and [NOTICE](NOTICE).

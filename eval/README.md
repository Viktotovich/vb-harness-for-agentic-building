# Evaluation

Ten Astro tasks of increasing size, each scored on a fresh run of the whole pipeline. Use them to compare models
and profile mappings. They need a model server and Node, so they run by hand, never in CI.

## Layout

- `tasks/<id>/request.md`: the feature request, as a user would write it.
- `tasks/<id>/repo.ref`: the repository to run on (a local path, or `$VAR` naming an environment variable), then
  the commit (`HEAD` or a sha prefix). Remote URLs are refused: clone them yourself.
- `tasks/<id>/hidden/`: acceptance tests. They are copied into the worktree only after the run has finished and
  run with the stack's test gate. The harness never sees them while it works.
- `repos/astro-mini/`: the small Astro project every task starts from.

## Prepare the repository once

The harness never installs anything (invariant I10), so prepare the starting repository yourself:

```bash
cp -r eval/repos/astro-mini /path/to/astro-mini
cd /path/to/astro-mini
npm install astro @astrojs/check typescript vitest
git init -b main && git add -A && git commit -m "astro-mini"
export HARNESS_EVAL_ASTRO=/path/to/astro-mini
```

`node_modules` is git-ignored there. The astro stack in `config.example.json` lists it in `dependencyDirs`, so each
run's worktree gets it as hard links.

## Run

```bash
ruby eval/run_eval.rb --config config.json --profile-map eval/profile-map.example.json
```

Options: `--tasks 'eval/tasks/0[1-3]*'` picks tasks, `--keep` keeps the worktrees, `--json` prints the scores as
JSON. Runs go to `eval-out/<mapping>/runs/` next to the config; open `report.md` in a run for details.

## Metrics

| Column | Meaning |
| --- | --- |
| Solved | the hidden tests pass |
| Solved without fixes | solved, and no task needed a fix round |
| Regressions | integration gates that got worse than the baseline |
| Findings confirmed | review claims confirmed by a failing test / claims sent to confirmation |
| Fix rounds, Tokens, Time | totals for the run; a second table splits tokens and time per role |

The hidden tests use Astro's container API (`astro/container`) through Vitest, so they need an Astro version that
has it.

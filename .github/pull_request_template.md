## What and why

<!-- One or two sentences. Link the issue if there is one. -->

## Checks

There is no hosted CI. Run `ruby bin/check` and paste its last three lines:

```
syntax:     
guardrails: 
tests:      
```

OS and Ruby version:

- [ ] No guardrail test in `test/guardrails_test.rb` is weakened or deleted.
- [ ] No model names in `lib/` or `prompts/`, no gems, no subprocess outside `Harness::Exec`.
- [ ] Nothing personal or secret in the diff (local paths, usernames, keys, tokens).
- [ ] Any change of approach is recorded in `docs/decisions.md`.

# App checklist (run by a person)

The automated tests cover the server, the API and the I15 rules. These checks need a browser and a person. Run them
before a release, with a model server running, and note the browser and date.

## Start and onboarding

- [ ] With no `config.json`, `ruby exe/harness` prints the URL and opens the browser on `127.0.0.1`.
- [ ] Settings lists LM Studio and Ollama with their state. Nothing runs until a button is clicked.
- [ ] LM Studio with the server stopped: "Start LM Studio's server" starts it; "List downloaded models" lists them;
      "Load" loads one.
- [ ] Ollama: "Pull" with a typed name pulls it (the download size shows in the output).
- [ ] Custom: an OpenAI-compatible URL lists its models; typing a key instead of an env var name is refused.
- [ ] "Use" a model: the summary reads like "16K context, JSON mode: yes, tools: no, thinking can be turned off".
- [ ] With nothing installed, the page shows the LM Studio and Ollama links and the custom form.

## Chat

- [ ] "+ New chat" creates a chat; the first message becomes its title; newest chats are on top.
- [ ] Rename works; Delete asks first and removes the chat.
- [ ] The model picker lists "provider · model id" for every configured provider; switching mid-chat adds a note.
- [ ] Enter adds a newline; Ctrl+Enter (⌘+Enter on macOS) sends. The box shows 6 lines and grows to 40% of the
      window.
- [ ] A draft survives switching chats and reloading the page.
- [ ] Replies stream with a pulsing cursor; Stop ends them; thinking text sits in a collapsed "Thinking" block.
- [ ] Markdown: headings, lists, emphasis and code blocks render; Copy copies a code block; links show as text.
- [ ] A reply containing `<img src=x onerror=alert(1)>` or `<script>` shows the text literally and runs nothing.
- [ ] A long chat keeps working past the model's context (older messages are summarised).

## Build

- [ ] Build mode shows the repo box; Send starts a run and a card appears.
- [ ] The card shows the stage strip, task rows with ✓ ● ○ ✕ ↷ marks, sub-stages of the active task, and the
      counters. Marks are readable without colour.
- [ ] "details" shows the reasons table; clicking a reason lists its items as plain text.
- [ ] A blocking question turns the card's border purple; answering in the text box continues the run.
- [ ] A blocked task shows its reason and patch path.
- [ ] Reloading the page during a run replays the card without gaps or duplicates.
- [ ] A finished run collapses to one line and expands on click; "Show report" renders the report.

## Look

- [ ] Inter is used everywhere (DevTools: computed font); code uses the monospace stack at 13.5px.
- [ ] Colours match DESIGN.md 11.4; body text is readable (WCAG AA); the focus ring is visible on every control.
- [ ] With "reduce motion" on, nothing pulses.
- [ ] DevTools console: no CSP violations, no errors.

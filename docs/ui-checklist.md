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

- [ ] "New chat" creates a chat; the first message becomes its title (the top bar updates too); newest chats are on top, grouped Today and Earlier.
- [ ] The ⋯ menu renames (in the app's own dialog) and deletes (asks first, in the app's own dialog).
- [ ] The model picker lists "provider · model id" for every configured provider; switching mid-chat adds a note.
- [ ] Enter adds a newline; Ctrl+Enter (⌘+Enter on macOS) sends. The box shows 6 lines and grows to 40% of the
      window.
- [ ] A draft survives switching chats and reloading the page.
- [ ] Replies stream with a pulsing cursor; Stop ends them. A thinking model shows "Thinking… Ns" with its latest line
  of thought while it works, then folds to "Thought for Ns"; opening it shows the whole thought process, scrolling
  inside its own panel. Reopening the chat still says how long it thought.
- [ ] Markdown: headings, lists, emphasis and code blocks render; Copy copies a code block; links show as text.
- [ ] A reply containing `<img src=x onerror=alert(1)>` or `<script>` shows the text literally and runs nothing.
- [ ] A long chat keeps working past the model's context (older messages are summarised).

## Build

- [ ] Build mode shows the repo box; Send starts a run and a card appears.
- [ ] The card shows the progress bar, the Now line ("updated … ago"), task rows with ✓ ● ○ ✕ ↷ marks, the steps of the active task, and the
      counters. Marks are readable without colour.
- [ ] "Why?" shows the reasons; clicking a reason lists its items as plain text.
- [ ] A blocking question turns the card amber and asks it in the card, one field per question; "Answer and continue" continues the run.
- [ ] A blocked task shows its reason and patch path.
- [ ] Reloading the page during a run replays the card without gaps or duplicates.
- [ ] A finished run shows a summary, the branch with "Copy branch", "View report" (the report opens beside the chat, tables as tables) and "Show details". A stopped or failed run has "Resume".

## Look

- [ ] Inter is used everywhere (DevTools: computed font); code uses the monospace stack at 13.5px.
- [ ] Colours match docs/decisions.md ("A calmer app"); body text is readable (WCAG AA); the focus ring is visible on every control.
- [ ] With "reduce motion" on, nothing pulses.
- [ ] DevTools console: no CSP violations, no errors.

## Appearance and phones

- [ ] Settings → Appearance: System follows the computer's setting; Dark and Light stick after a reload, with no flash
      of the other look on load.
- [ ] A preset or a colour picker changes the page at once and is saved as you go: it is still there after leaving
      Settings and after a reload. The dark look's colours never show in the light look.
- [ ] Text that is hard to read (below 4.5:1) is flagged under the colour pickers.
- [ ] The browser tab reads "VB Harness" with the VB icon, on the app and on the pairing page.
- [ ] Each chat in the sidebar has a delete button (on hover, or always on a touch screen); a chat whose build is
      still going is not deleted. The Settings tabs show no scrollbar.
- [ ] The sidebar shows Building, Needs you, Failed, Stopped or ✓ for a chat's latest build, and the top bar stops
      saying "working" when a run ends.
- [ ] At phone width (375px): the menu button opens the chat list over the page and choosing a chat closes it; no
      sideways scrolling anywhere; the build card, Settings and the dialogs fit; typing does not zoom the page.

## Setup fixes, Preview and LAN mode

- [ ] A project without `node_modules` says so under the text box with a Fix button; Fix shows the exact command,
      runs it only after "Run it", shows its output, and the project becomes ready (a fresh project stays clean).
- [ ] A build that stops at intake keeps its reason after a reload, with the fixes it can offer and Build again.
- [ ] Closing the app mid-build, then opening it again, shows that build as Stopped with Resume, not Building.
- [ ] Preview starts the project's dev server, shows Open preview when it answers, and Stop preview ends it; the
      project's checkout has no new files afterwards.
- [ ] `harness ui --lan`: the banner shows the address and code; a phone pairs with the code and can chat and
      build; Settings, Add project, Fix and Preview are not offered there; Stop sharing signs the phone out.

Add a counter island at `src/components/Counter.astro`, without a UI framework.

- Prop `start` (number, default `0`).
- It renders a custom element `<counter-button data-start="<start>">` containing a `<button>` whose text is
  the current count, and a client `<script>` that defines `counter-button` so each click adds one.
- Use it on the home page with `start={3}`.

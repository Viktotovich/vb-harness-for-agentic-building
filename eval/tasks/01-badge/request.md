Add a Badge component at `src/components/Badge.astro`.

- It takes a required `label` prop (string) and renders it inside `<span class="badge">`.
- It takes an optional `tone` prop, `"info"` or `"warn"`, defaulting to `"info"`, and adds the class
  `badge--<tone>` to the span.

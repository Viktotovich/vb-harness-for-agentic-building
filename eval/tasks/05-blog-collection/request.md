Add a `blog` content collection.

- Define it in `src/content.config.ts` with the `glob` loader over `src/content/blog/*.md`.
- Its schema: `title` (string), `date` (a date; coerce strings), `draft` (boolean, default `false`).
- Add two posts, `src/content/blog/hello.md` and `src/content/blog/second.md`, with valid frontmatter.

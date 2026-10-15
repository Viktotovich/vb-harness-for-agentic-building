Add `src/lib/slug.ts` exporting `slugify(text: string): string`.

It lowercases the text, turns every run of characters other than a-z and 0-9 into a single `-`, and trims
`-` from both ends. For example `"  Hello, World!  "` becomes `"hello-world"` and `"Astro 5 -- Tips"` becomes
`"astro-5-tips"`.

Add a blog: a content collection and its pages.

- A `blog` collection in `src/content.config.ts` (glob loader over `src/content/blog/*.md`; schema `title`
  string, `date` coerced date, `draft` boolean default `false`), with two posts.
- `src/lib/posts.ts` exports `sortPosts(posts)`, which drops drafts and sorts by date, newest first. Posts are
  objects with `data: { title, date, draft }`.
- `src/pages/blog/index.astro` lists the published posts (newest first) as links to `/blog/<id>/`.
- `src/pages/blog/[id].astro` renders one post with `getStaticPaths` over the published posts.

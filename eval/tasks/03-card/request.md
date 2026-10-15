Add a Card component at `src/components/Card.astro`.

- Props: `title` (string, required) and `href` (string, optional).
- It renders `<article class="card">` with the title in an `<h2>`. When `href` is given, the title is a link
  to it.
- The component's default slot goes after the heading, inside the article.

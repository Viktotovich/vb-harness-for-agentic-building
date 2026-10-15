Add English and French home pages at `/en/` and `/fr/`.

- `src/i18n/ui.ts` exports `languages` (`["en", "fr"]`) and `t(lang, key)`, with the keys `home.title`
  (`"Welcome"` / `"Bienvenue"`) and `home.intro` (`"Small, fast websites."` / `"Des sites petits et rapides."`).
  An unknown key returns the key itself.
- `src/pages/[lang]/index.astro` uses `getStaticPaths` over `languages`, the `Base` layout titled with
  `home.title`, and shows `home.title` in an `<h1>` and `home.intro` in a paragraph.

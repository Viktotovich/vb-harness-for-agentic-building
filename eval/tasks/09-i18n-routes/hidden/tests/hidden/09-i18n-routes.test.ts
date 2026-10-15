import { expect, it } from "vitest";
import { experimental_AstroContainer as AstroContainer } from "astro/container";
import { languages, t } from "../../src/i18n/ui";
import * as Page from "../../src/pages/[lang]/index.astro";

it("translates and falls back to the key", () => {
  expect(languages).toEqual(["en", "fr"]);
  expect(t("fr", "home.title")).toBe("Bienvenue");
  expect(t("en", "home.intro")).toBe("Small, fast websites.");
  expect(t("en", "missing.key")).toBe("missing.key");
});

it("builds one page per language", async () => {
  const paths = await (Page as any).getStaticPaths();
  expect(paths.map((p: any) => p.params.lang).sort()).toEqual(["en", "fr"]);
  const container = await AstroContainer.create();
  const html = await container.renderToString(Page.default, { params: { lang: "fr" } });
  expect(html).toMatch(/<h1[^>]*>\s*Bienvenue\s*<\/h1>/);
  expect(html).toContain("Des sites petits et rapides.");
});

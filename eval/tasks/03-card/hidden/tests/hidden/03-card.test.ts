import { expect, it } from "vitest";
import { experimental_AstroContainer as AstroContainer } from "astro/container";
import Card from "../../src/components/Card.astro";

it("renders a title and its slot", async () => {
  const container = await AstroContainer.create();
  const html = await container.renderToString(Card, { props: { title: "Plans" }, slots: { default: "<p>Body text</p>" } });
  expect(html).toMatch(/<article[^>]*class="[^"]*\bcard\b/);
  expect(html).toMatch(/<h2[^>]*>\s*Plans\s*<\/h2>/);
  expect(html.indexOf("Body text")).toBeGreaterThan(html.indexOf("Plans"));
  expect(html).not.toContain("<a");
});

it("links the title when href is given", async () => {
  const container = await AstroContainer.create();
  const html = await container.renderToString(Card, { props: { title: "Plans", href: "/plans" } });
  expect(html).toMatch(/<a[^>]*href="\/plans"[^>]*>\s*Plans\s*<\/a>/);
});

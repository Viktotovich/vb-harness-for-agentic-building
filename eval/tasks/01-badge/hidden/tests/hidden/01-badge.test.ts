import { expect, it } from "vitest";
import { experimental_AstroContainer as AstroContainer } from "astro/container";
import Badge from "../../src/components/Badge.astro";

it("renders the label with the default tone", async () => {
  const container = await AstroContainer.create();
  const html = await container.renderToString(Badge, { props: { label: "New" } });
  expect(html).toMatch(/<span[^>]*class="[^"]*\bbadge\b[^"]*\bbadge--info\b[^"]*"[^>]*>\s*New\s*<\/span>/);
});

it("uses the tone it is given", async () => {
  const container = await AstroContainer.create();
  const html = await container.renderToString(Badge, { props: { label: "Careful", tone: "warn" } });
  expect(html).toContain("badge--warn");
  expect(html).not.toContain("badge--info");
});

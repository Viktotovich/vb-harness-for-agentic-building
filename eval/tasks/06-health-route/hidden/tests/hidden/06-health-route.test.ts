import { expect, it } from "vitest";
import * as route from "../../src/pages/api/health.json";

it("answers ok", async () => {
  const res: Response = await (route.GET as any)({ request: new Request("http://localhost/api/health.json") });
  expect(res.headers.get("content-type")).toContain("application/json");
  expect(await res.json()).toEqual({ status: "ok" });
  expect((route as any).prerender).toBe(false);
});

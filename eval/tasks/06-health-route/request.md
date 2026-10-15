Add an API route at `/api/health.json` (`src/pages/api/health.json.ts`).

Its `GET` handler returns a JSON response `{"status": "ok"}` with the header
`Content-Type: application/json`. The route is not prerendered.

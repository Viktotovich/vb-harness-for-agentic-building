Add an API route at `/api/add` (`src/pages/api/add.ts`), not prerendered.

`GET /api/add?a=1&b=2` returns JSON `{"sum": 3}`. If `a` or `b` is missing or is not a finite number, it
returns status 400 with JSON `{"error": "a and b must be numbers"}`.

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 V and Bruno LLC
//
// LAN mode's pairing page: sends the code typed here; on success the server sets the session cookie and the app
// loads. Text from the server goes into the page with textContent only.
"use strict";

(() => {
  const form = document.getElementById("pair-form");
  const code = document.getElementById("code");
  const msg = document.getElementById("msg");
  form.addEventListener("submit", async (ev) => {
    ev.preventDefault();
    msg.textContent = "Pairing…";
    try {
      const res = await fetch("/api/lan/pair", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ code: code.value.trim() }),
      });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.error || "HTTP " + res.status);
      msg.textContent = "Paired. Opening the app…";
      window.location.replace("/");
    } catch (e) {
      msg.textContent = e.message;
      code.select();
    }
  });
  code.focus();
})();

// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 V and Bruno LLC
//
// The harness app (DESIGN.md 11.3-11.5). Plain browser JavaScript, no build step. Model output is never inserted
// as HTML: every text goes into the page through textContent, and the Markdown renderer builds DOM nodes.
"use strict";

(() => {
  const TOKEN = document.querySelector('meta[name="harness-token"]').content;
  const $ = (id) => document.getElementById(id);
  const MARK = { done: "✓", active: "●", pending: "○", blocked: "✕", skipped: "↷" };
  const TASK_STEPS = [["gather", "task.gather"], ["implement", "task.implement"], ["apply", "task.apply"], ["gates", "task.gates"], ["fix", "task.fix"]];
  const REVIEW_STEPS = [["discover", "review.discover"], ["verify", "review.verify"], ["judge", "review.judge"],
    ["support", "review.support"], ["challenge", "review.challenge"], ["confirm-test", "review.confirm_test"]];
  const FINISHED = ["done", "failed", "stopped", "plan_rejected"];

  const app = { state: null, chat: null, mode: "chat", stream: null, streamId: null, builds: new Map(), waiting: null };

  // ---------------------------------------------------------------- DOM helpers (text only)

  function el(tag, attrs, ...children) {
    const node = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
      if (k === "class") node.className = v;
      else if (k === "text") node.textContent = v;
      else if (k.startsWith("on")) node.addEventListener(k.slice(2), v);
      else node.setAttribute(k, v);
    }
    for (const c of children) if (c !== null && c !== undefined) node.append(c);
    return node;
  }

  function clear(node) {
    while (node.firstChild) node.removeChild(node.firstChild);
  }

  // ---------------------------------------------------------------- server calls

  async function get(path) {
    const res = await fetch(path, { headers: { Accept: "application/json" } });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || "HTTP " + (res.status));
    return data;
  }

  async function post(path, body) {
    const res = await fetch(path, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Harness-Token": TOKEN },
      body: JSON.stringify(body || {}),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || "HTTP " + (res.status));
    return data;
  }

  function status(text, kind) {
    $("status-text").textContent = text;
    $("status-dot").className = "dot " + (kind || "");
  }

  // ---------------------------------------------------------------- safe Markdown

  // Inline: code spans, **strong**, *em* / _em_, [text](url) shown as text plus the URL in brackets.
  function inline(text) {
    const frag = document.createDocumentFragment();
    const re = /(\x60[^\x60\n]+\x60)|(\*\*[^*\n]+\*\*)|(\*[^*\n]+\*|_[^_\n]+_)|(\[[^\]\n]+\]\([^)\s]+\))/g;
    let last = 0;
    let m;
    while ((m = re.exec(text)) !== null) {
      if (m.index > last) frag.append(document.createTextNode(text.slice(last, m.index)));
      const t = m[0];
      if (m[1]) frag.append(el("code", { text: t.slice(1, -1) }));
      else if (m[2]) frag.append(el("strong", { text: t.slice(2, -2) }));
      else if (m[3]) frag.append(el("em", { text: t.slice(1, -1) }));
      else {
        const label = t.slice(1, t.indexOf("]("));
        const url = t.slice(t.indexOf("](") + 2, -1);
        frag.append(el("span", { class: "link-text", text: "" + (label) + " (" + (url) + ")" }));
      }
      last = m.index + t.length;
    }
    if (last < text.length) frag.append(document.createTextNode(text.slice(last)));
    return frag;
  }

  function codeBlock(code, lang) {
    const copy = el("button", { class: "btn small copy", type: "button", text: "Copy" });
    copy.addEventListener("click", () => {
      navigator.clipboard.writeText(code).then(() => { copy.textContent = "Copied"; setTimeout(() => { copy.textContent = "Copy"; }, 1200); });
    });
    const pre = el("pre", {}, el("code", { text: code }));
    if (lang) pre.setAttribute("data-lang", lang);
    return el("div", { class: "codeblock" }, pre, copy);
  }

  function markdown(text) {
    const root = document.createDocumentFragment();
    const lines = String(text || "").replace(/\r\n/g, "\n").split("\n");
    let i = 0;
    let para = [];
    const flush = () => {
      if (para.length) root.append(el("p", {}, inline(para.join(" "))));
      para = [];
    };
    while (i < lines.length) {
      const line = lines[i];
      const fence = line.match(/^\s*(\x60{3,}|~{3,})\s*([\w+-]*)\s*$/);
      if (fence) {
        flush();
        const body = [];
        i += 1;
        while (i < lines.length && !lines[i].trim().startsWith(fence[1])) body.push(lines[i++]);
        i += 1;
        root.append(codeBlock(body.join("\n"), fence[2]));
        continue;
      }
      const h = line.match(/^(#{1,6})\s+(.*)$/);
      if (h) {
        flush();
        root.append(el("h" + (Math.min(h[1].length + 1, 4)), {}, inline(h[2])));
        i += 1;
        continue;
      }
      const item = line.match(/^\s*([-*+]|\d+[.)])\s+(.*)$/);
      if (item) {
        flush();
        const ordered = /\d/.test(item[1]);
        const list = el(ordered ? "ol" : "ul");
        while (i < lines.length) {
          const m = lines[i].match(/^\s*([-*+]|\d+[.)])\s+(.*)$/);
          if (!m || /\d/.test(m[1]) !== ordered) break;
          list.append(el("li", {}, inline(m[2])));
          i += 1;
        }
        root.append(list);
        continue;
      }
      if (line.trim() === "") flush();
      else para.push(line.trim());
      i += 1;
    }
    flush();
    return root;
  }

  // ---------------------------------------------------------------- sidebar, picker, transcript

  async function loadState() {
    app.state = await get("/api/state");
    renderChats();
    renderPicker();
    if (!app.state.configured) {
      status("no model set up", "bad");
      openSettings();
    } else {
      status("ready", "ok");
    }
  }

  function renderChats() {
    const list = $("chat-list");
    clear(list);
    for (const c of app.state.chats) {
      const b = el("button", { class: "chat-item" + (app.chat && app.chat.id === c.id ? " active" : ""), type: "button", text: c.title, title: c.title });
      b.addEventListener("click", () => openChat(c.id));
      list.append(b);
    }
  }

  function renderPicker() {
    const pick = $("model-picker");
    clear(pick);
    if (!app.state.models.length) pick.append(el("option", { value: "", text: "no models (open Settings)" }));
    app.state.models.forEach((m, i) => {
      const o = el("option", { value: String(i), text: m.error ? "" + (m.label) + " (unreachable)" : m.label });
      if (app.chat && app.chat.model && app.chat.model.profile === m.profile && app.chat.model.model === m.model) o.selected = true;
      pick.append(o);
    });
  }

  async function refreshChats() {
    app.state.chats = await get("/api/chats");
    renderChats();
  }

  async function openChat(id) {
    saveDraft();
    closeSettings();
    app.chat = await get("/api/chats/" + (encodeURIComponent(id)));
    renderChats();
    renderPicker();
    renderTranscript();
    $("input").value = loadDraft();
  }

  function renderTranscript() {
    const t = $("transcript");
    clear(t);
    for (const m of app.chat.messages) t.append(messageNode(m));
    t.scrollTop = t.scrollHeight;
  }

  function messageNode(m) {
    if (m.role === "user") return el("div", { class: "msg user", text: m.content });
    if (m.role === "note") return el("div", { class: "msg note", text: m.content });
    if (m.role === "build") return buildCard(m.runId, m.repo).node;
    const node = el("div", { class: "msg assistant" });
    if (m.thinking) node.append(thinkingBlock(m.thinking));
    node.append(markdown(m.content));
    if (m.model) node.append(el("div", { class: "meta", text: "" + (m.model) + (m.finish && m.finish !== "stop" ? (" · " + (m.finish)) : "") }));
    return node;
  }

  function thinkingBlock(text) {
    const body = el("div", { text });
    return el("details", { class: "thinking" }, el("summary", { text: "Thinking" }), body);
  }

  // ---------------------------------------------------------------- sending

  async function ensureChat() {
    if (app.chat) return app.chat;
    const chosen = app.state.models[Number($("model-picker").value)];
    app.chat = await post("/api/chats", { model: chosen ? { profile: chosen.profile, model: chosen.model } : null });
    await refreshChats();
    renderTranscript();
    return app.chat;
  }

  async function send() {
    const input = $("input");
    const text = input.value;
    if (!text.trim() || app.stream) return;
    try {
      if (app.waiting) {
        const answers = text.split("\n").map((s) => s.trim()).filter(Boolean);
        await post("/api/runs/" + (app.waiting.runId) + "/answer", { answers });
        input.value = "";
        saveDraft();
        app.waiting.card.resume();
        setWaiting(null);
        return;
      }
      const chat = await ensureChat();
      if (app.mode === "build") {
        const repo = $("repo").value.trim();
        localStorage.setItem("harness.repo", repo);
        const out = await post("/api/chats/" + (chat.id) + "/send", { text, mode: "build", repo });
        input.value = "";
        saveDraft();
        app.chat = await get("/api/chats/" + (chat.id));
        renderTranscript();
        status("building " + (out.run), "busy");
      } else {
        const out = await post("/api/chats/" + (chat.id) + "/send", { text, mode: "chat" });
        input.value = "";
        saveDraft();
        $("transcript").append(el("div", { class: "msg user", text }));
        streamReply(out.stream);
      }
      await refreshChats();
    } catch (e) {
      $("transcript").append(el("div", { class: "msg assistant error", text: e.message }));
    }
  }

  function streamReply(id) {
    const t = $("transcript");
    const node = el("div", { class: "msg assistant" });
    const thinking = el("div");
    const details = el("details", { class: "thinking", hidden: "" }, el("summary", { text: "Thinking" }), thinking);
    const body = el("div");
    const cursor = el("span", { class: "cursor" });
    node.append(details, body, cursor);
    t.append(node);
    let text = "";
    let pending = false;
    const paint = () => {
      pending = false;
      clear(body);
      body.append(markdown(text));
      t.scrollTop = t.scrollHeight;
    };
    const es = new EventSource("/api/streams/" + (id));
    app.stream = es;
    app.streamId = id;
    $("stop").hidden = false;
    status("answering", "busy");
    const end = () => {
      es.close();
      cursor.remove();
      app.stream = null;
      app.streamId = null;
      $("stop").hidden = true;
      status("ready", "ok");
    };
    es.addEventListener("text", (ev) => {
      text += JSON.parse(ev.data).text;
      if (!pending) { pending = true; setTimeout(paint, 60); }
    });
    es.addEventListener("thinking", (ev) => {
      details.hidden = false;
      thinking.textContent += JSON.parse(ev.data).text;
    });
    es.addEventListener("done", () => { paint(); end(); });
    es.addEventListener("error", (ev) => {
      const msg = ev.data ? JSON.parse(ev.data).error : "the connection closed";
      node.classList.add("error");
      body.append(el("div", { class: "meta", text: msg }));
      end();
    });
  }

  async function stop() {
    if (app.streamId) await post("/api/streams/" + (app.streamId) + "/stop", {}).catch(() => {});
  }

  // ---------------------------------------------------------------- build cards (progress view)

  function buildCard(runId, repo) {
    if (app.builds.has(runId)) return app.builds.get(runId);
    const node = el("div", { class: "build" });
    const card = { node, runId, events: [], seq: 0, run: {}, tasks: [], open: false, expanded: null, es: null, timer: null };
    card.render = () => renderBuild(card, repo);
    card.resume = () => connect(card);
    app.builds.set(runId, card);
    connect(card);
    card.render();
    return card;
  }

  function connect(card) {
    if (card.es) card.es.close();
    const es = new EventSource("/api/runs/" + (card.runId) + "/events?after=" + (card.seq));
    card.es = es;
    const later = () => {
      if (!card.timer) card.timer = setTimeout(() => { card.timer = null; card.render(); }, 250);
    };
    es.addEventListener("event", (ev) => {
      const e = JSON.parse(ev.data);
      if (e.seq <= card.seq) return;
      card.seq = e.seq;
      card.events.push(e);
      later();
    });
    es.addEventListener("run", (ev) => {
      const r = JSON.parse(ev.data);
      card.run = r;
      if (r.tasks) card.tasks = r.tasks;
      later();
    });
    es.addEventListener("failed", (ev) => {
      card.run = { status: "error", error: JSON.parse(ev.data).error };
      later();
    });
    es.addEventListener("end", () => {
      es.close();
      card.es = null;
      later();
    });
  }

  function fold(card) {
    const tasks = {};
    const reasons = new Map();
    let produced = 0, accepted = 0, rejected = 0;
    const runStages = {};
    for (const e of card.events) {
      if (e.kind === "accepted" || e.kind === "rejected") {
        produced += 1;
        if (e.kind === "accepted") accepted += 1; else rejected += 1;
      }
      if (e.kind === "rejected" && e.reason) {
        const r = reasons.get(e.reason) || { code: e.reason, text: e.reasonText || e.reason, stage: e.stage, items: [] };
        r.items.push(e);
        reasons.set(e.reason, r);
      }
      if (e.task) {
        const t = tasks[e.task] || (tasks[e.task] = { stage: null, status: "running", attempt: 1, seen: new Set(), reason: null });
        t.stage = e.stage;
        t.seen.add(e.stage);
        t.attempt = Math.max(t.attempt, e.attempt || 1);
        if (["done", "blocked", "skipped"].includes(e.kind) && e.subject === "task") {
          t.status = e.kind;
          t.reason = e.reasonText || e.detail || null;
          t.commit = e.kind === "done" ? e.detail : null;
        }
      } else if (e.kind === "stage_started" || e.kind === "stage_finished") {
        runStages[e.stage] = e.kind === "stage_finished" ? "done" : "active";
      }
    }
    const first = card.events[0], last = card.events[card.events.length - 1];
    const elapsed = first && last ? (Date.parse(last.at) - Date.parse(first.at)) / 1000 : 0;
    const tokens = card.events.reduce((n, e) => n + (e.tokens ? (e.tokens.in || 0) + (e.tokens.out || 0) : 0), 0);
    return { tasks, reasons: [...reasons.values()].sort((a, b) => b.items.length - a.items.length), produced, accepted, rejected, runStages, elapsed, tokens };
  }

  function duration(s) {
    s = Math.round(s);
    return s < 60 ? "" + (s) + "s" : "" + (Math.floor(s / 60)) + "m " + (s % 60) + "s";
  }

  function markSpan(kind) {
    return el("span", { class: "mark-" + (kind), text: MARK[kind] });
  }

  function renderBuild(card, repo) {
    const f = fold(card);
    const node = card.node;
    clear(node);
    const st = card.run.status || "starting";
    const waiting = st === "waiting" && (card.run.questions || []).length;
    node.className = "build" + (waiting ? " waiting" : "");
    const total = card.tasks.length;
    const finished = Object.values(f.tasks).filter((t) => ["done", "blocked", "skipped"].includes(t.status)).length;
    const tok = f.tokens >= 1000 ? "" + ((f.tokens / 1000).toFixed(1)) + "K" : String(f.tokens);
    node.append(el("div", { class: "build-head" },
      el("span", { text: "Build · " + (card.runId) }),
      el("span", { class: "muted", text: "" + (st) + " · " + (duration(f.elapsed)) + " · " + (tok) + " tok" })));
    if (repo) node.append(el("div", { class: "muted", text: "repo " + (repo) }));

    if (FINISHED.includes(st) && !card.open) {
      const line = el("button", { class: "btn ghost small", type: "button",
        text: "" + (finished) + "/" + (total) + " tasks · " + (f.rejected) + " rejected · show details" });
      line.addEventListener("click", () => { card.open = true; card.render(); });
      node.append(line, reportLink(card));
      if (card.run.error) node.append(el("div", { class: "mark-blocked", text: card.run.error }));
      return;
    }
    const stage = (name, key) => {
      const s = f.runStages[key];
      return "" + (name) + " " + (MARK[s === "done" ? "done" : s === "active" ? "active" : "pending"]);
    };
    const planMark = st === "planning" || st === "waiting" ? MARK.active : total ? MARK.done : MARK.pending;
    node.append(el("div", { class: "strip", text:
      "Plan " + (planMark) + " ── Tasks " + (finished) + "/" + (total) + " ── " + (stage("Integration", "integration")) + " ── " + (stage("Final review", "final_review")) + " ── " + (stage("Report", "report")) }));

    for (const task of card.tasks) {
      const t = f.tasks[task.id];
      const row = el("div", { class: "task-row" }, el("span", { text: task.id }), el("span", { class: "title", text: task.title, title: task.title }));
      let detail;
      if (!t) {
        const wait = (task.dependsOn || []).filter((d) => !(f.tasks[d] && f.tasks[d].status === "done"));
        detail = el("span", {}, markSpan("pending"), document.createTextNode(wait.length ? " waiting on " + (wait.join(", ")) : ""));
      } else if (t.status === "done") {
        detail = el("span", {}, markSpan("done"), document.createTextNode(" committed " + (t.commit || "")));
      } else if (t.status === "blocked") {
        detail = el("span", {}, markSpan("blocked"), document.createTextNode(" blocked: " + (t.reason || "") + " (tasks/" + (task.id) + "/blocked.patch)"));
      } else if (t.status === "skipped") {
        detail = el("span", {}, markSpan("skipped"), document.createTextNode(" skipped: " + (t.reason || "")));
      } else {
        detail = el("span", {}, markSpan("active"), document.createTextNode(" " + ((t.stage || "").replace(".", " › ")) + "   (attempt " + (t.attempt) + ")"));
      }
      row.append(detail);
      node.append(row);
      if (t && t.status === "running") {
        const mk = (pairs) => pairs.map(([name, key]) => "" + (name) + " " + (key === t.stage ? MARK.active : t.seen.has(key) ? MARK.done : MARK.pending)).join(" ");
        node.append(el("div", { class: "substeps", text: "" + (mk(TASK_STEPS)) + "  review: " + (mk(REVIEW_STEPS)) }));
      }
    }

    const pct = f.produced ? Math.round((100 * f.rejected) / f.produced) : 0;
    const toggle = el("button", { class: "btn ghost small", type: "button", text: card.expanded ? "details ▴" : "details ▾" });
    toggle.addEventListener("click", () => { card.expanded = card.expanded ? null : "all"; card.render(); });
    node.append(el("div", { class: "counters" },
      el("span", { text: "Outputs " + (f.produced) + " produced · " + (f.accepted) + " accepted · " + (f.rejected) + " rejected (" + (pct) + "%)" }), toggle));
    if (card.expanded) node.append(reasonsTable(card, f));

    if (waiting) {
      const q = el("div", { class: "question" }, el("strong", { text: "The planner asks:" }));
      const ol = el("ol");
      for (const text of card.run.questions) ol.append(el("li", { text }));
      q.append(ol, el("div", { class: "muted", text: "Answer in the text box, one answer per line, then Send." }));
      node.append(q);
      setWaiting({ runId: card.runId, card, count: card.run.questions.length });
    }
    if (card.run.error) node.append(el("div", { class: "mark-blocked", text: card.run.error }));
    if (FINISHED.includes(st)) node.append(reportLink(card));
    if (FINISHED.includes(st) || st === "error") status("ready", "ok");
  }

  function reasonsTable(card, f) {
    const table = el("table", { class: "reasons" });
    for (const r of f.reasons) {
      const row = el("tr", { class: "reason" }, el("td", { text: String(r.items.length) }), el("td", { text: r.text }), el("td", { class: "muted", text: r.stage }));
      row.addEventListener("click", () => { card.expanded = card.expanded === r.code ? "all" : r.code; card.render(); });
      table.append(row);
      if (card.expanded === r.code) {
        for (const e of r.items) {
          table.append(el("tr", { class: "reason-items" }, el("td", { colspan: "3",
            text: "" + (e.subject || "") + (e.task ? (" · " + (e.task)) : "") + (e.attempt ? (" · attempt " + (e.attempt)) : "") + "\n" + (e.detail || "") })));
        }
      }
    }
    if (!f.reasons.length) table.append(el("tr", {}, el("td", { colspan: "3", class: "muted", text: "Nothing rejected yet." })));
    return table;
  }

  function reportLink(card) {
    const holder = el("div");
    const b = el("button", { class: "btn small", type: "button", text: "Show report" });
    b.addEventListener("click", async () => {
      try {
        const res = await fetch("/api/runs/" + (card.runId) + "/report");
        const text = await res.text();
        clear(holder);
        holder.append(el("div", { class: "report msg assistant" }, markdown(text)));
      } catch (e) {
        holder.append(el("div", { class: "muted", text: e.message }));
      }
    });
    holder.append(b);
    return holder;
  }

  function setWaiting(w) {
    app.waiting = w;
    const box = $("answering");
    box.hidden = !w;
    box.textContent = w ? "Answering " + (w.count) + " question" + (w.count > 1 ? "s" : "") + " of build " + (w.runId) + ": one answer per line." : "";
  }

  // ---------------------------------------------------------------- settings (providers)

  function openSettings() {
    $("transcript").hidden = true;
    $("settings").hidden = false;
    renderSettings();
  }

  function closeSettings() {
    $("settings").hidden = true;
    $("transcript").hidden = false;
  }

  async function renderSettings() {
    const s = $("settings");
    clear(s);
    s.append(el("h2", { text: "Model providers" }),
      el("div", { class: "muted", text: "Looking for LM Studio and Ollama on this machine…" }));
    let found = [];
    try { found = await get("/api/providers"); } catch (e) { s.append(el("div", { class: "mark-blocked", text: e.message })); }
    clear(s);
    const back = el("button", { class: "btn ghost small", type: "button", text: "← Back to chats" });
    back.addEventListener("click", closeSettings);
    s.append(back, el("h2", { text: "Model providers" }));
    for (const p of found) s.append(providerCard(p));
    if (!found.some((p) => p.up || p.cli)) {
      s.append(el("div", { class: "provider" },
        el("strong", { text: "Nothing found on this machine" }),
        el("div", { class: "muted", text: "Install one of these, start it, then reopen Settings:" }),
        el("a", { href: "https://lmstudio.ai/", target: "_blank", rel: "noopener noreferrer", text: "LM Studio (lmstudio.ai)" }),
        el("a", { href: "https://ollama.com/download", target: "_blank", rel: "noopener noreferrer", text: "Ollama (ollama.com)" })));
    }
    s.append(customCard());
  }

  function output(card, text) {
    let pre = card.querySelector("pre");
    if (!pre) { pre = el("pre"); card.append(pre); }
    pre.textContent = text;
  }

  function useButton(kind, model, card, extra) {
    const b = el("button", { class: "btn small primary", type: "button", text: "Use " + (model) });
    b.addEventListener("click", async () => {
      b.disabled = true;
      output(card, "Checking what this model can do…");
      try {
        const r = await post("/api/providers/use", Object.assign({ kind, model }, extra || {}));
        output(card, "Ready: " + (r.profile) + " · " + (r.model) + "\n" + (r.summary));
        await loadState();
        status("ready", "ok");
      } catch (e) { output(card, e.message); }
      b.disabled = false;
    });
    return b;
  }

  function actionButton(p, action, label, card, model, after) {
    const b = el("button", { class: "btn small", type: "button", text: label });
    b.addEventListener("click", async () => {
      b.disabled = true;
      output(card, "" + (label) + "…");
      try {
        const r = await post("/api/providers/action", { kind: p.kind, action, model });
        output(card, "" + (r.ok ? "Done" : "Failed") + "\n" + (r.output));
        if (after) after(r);
      } catch (e) { output(card, e.message); }
      b.disabled = false;
    });
    return b;
  }

  function providerCard(p) {
    const card = el("div", { class: "provider" });
    const state = p.up ? (p.models.length ? "" + (p.models.length) + " model(s)" : p.error) : (p.cli ? "server not running" : "not found");
    card.append(el("div", { class: "row" }, el("strong", { text: p.label }), el("span", { class: "muted", text: "" + (p.baseUrl) + " · " + (state) })));
    const row = el("div", { class: "row" });
    for (const m of p.models) row.append(useButton(p.kind, m, card));
    card.append(row);
    if (p.kind === "lmstudio" && p.cli) {
      const tools = el("div", { class: "row" });
      if (!p.up) tools.append(actionButton(p, "server_start", "Start LM Studio's server", card, null, () => renderSettings()));
      tools.append(actionButton(p, "ls", "List downloaded models", card, null, (r) => {
        const loads = el("div", { class: "row" });
        for (const key of r.models || []) loads.append(actionButton(p, "load", "Load " + (key), card, key, () => renderSettings()));
        card.append(loads);
      }));
      card.append(tools);
    }
    if (p.kind === "ollama" && p.cli) {
      const name = el("input", { type: "text", placeholder: "model to pull, e.g. name:tag", spellcheck: "false" });
      const pull = el("button", { class: "btn small", type: "button", text: "Pull" });
      pull.addEventListener("click", async () => {
        pull.disabled = true;
        output(card, "Pulling " + (name.value) + "… this can take a while.");
        try {
          const r = await post("/api/providers/action", { kind: "ollama", action: "pull", model: name.value.trim() });
          output(card, "" + (r.ok ? "Done" : "Failed") + "\n" + (r.output));
          renderSettings();
        } catch (e) { output(card, e.message); }
        pull.disabled = false;
      });
      card.append(el("div", { class: "row" }, name, pull));
    }
    return card;
  }

  function customCard() {
    const card = el("div", { class: "provider" }, el("strong", { text: "Custom (OpenAI-compatible)" }));
    const url = el("input", { type: "text", placeholder: "http://127.0.0.1:8080/v1", spellcheck: "false" });
    const key = el("input", { type: "text", placeholder: "env var with the API key (optional)", spellcheck: "false" });
    const probe = el("button", { class: "btn small", type: "button", text: "Check" });
    const models = el("div", { class: "row" });
    probe.addEventListener("click", async () => {
      clear(models);
      output(card, "Asking the server for its models…");
      try {
        const p = await post("/api/providers/custom", { baseUrl: url.value.trim(), keyEnv: key.value.trim() });
        output(card, p.up ? "" + (p.models.length) + " model(s) found" : p.error);
        for (const m of p.models) models.append(useButton("custom", m, card, { baseUrl: url.value.trim(), keyEnv: key.value.trim() }));
      } catch (e) { output(card, e.message); }
    });
    card.append(el("div", { class: "row" }, url, key, probe), models,
      el("div", { class: "muted", text: "Type the name of the environment variable that holds the key, never the key itself." }));
    return card;
  }

  // ---------------------------------------------------------------- drafts, modes, wiring

  const draftKey = () => "harness.draft." + (app.chat ? app.chat.id : "new");
  function saveDraft() {
    try { localStorage.setItem(draftKey(), $("input").value); } catch (e) { /* storage may be off */ }
  }
  function loadDraft() {
    try { return localStorage.getItem(draftKey()) || ""; } catch (e) { return ""; }
  }

  function setMode(mode) {
    app.mode = mode;
    for (const b of document.querySelectorAll(".mode button")) {
      const on = b.dataset.mode === mode;
      b.classList.toggle("active", on);
      b.setAttribute("aria-checked", String(on));
    }
    $("repo").parentElement.hidden = mode !== "build";
  }

  function wire() {
    $("new-chat").addEventListener("click", async () => {
      saveDraft();
      const chosen = app.state.models[Number($("model-picker").value)];
      app.chat = await post("/api/chats", { model: chosen ? { profile: chosen.profile, model: chosen.model } : null });
      closeSettings();
      await refreshChats();
      renderTranscript();
      $("input").value = "";
      $("input").focus();
    });
    $("open-settings").addEventListener("click", openSettings);
    $("send").addEventListener("click", send);
    $("stop").addEventListener("click", stop);
    $("input").addEventListener("keydown", (ev) => {
      if (ev.key === "Enter" && (ev.ctrlKey || ev.metaKey)) {
        ev.preventDefault();
        send();
      }
    });
    $("input").addEventListener("input", saveDraft);
    for (const b of document.querySelectorAll(".mode button")) b.addEventListener("click", () => setMode(b.dataset.mode));
    $("model-picker").addEventListener("change", async () => {
      const m = app.state.models[Number($("model-picker").value)];
      if (!m || !app.chat) return;
      app.chat = await post("/api/chats/" + (app.chat.id) + "/model", { profile: m.profile, model: m.model });
      renderTranscript();
    });
    $("rename-chat").addEventListener("click", async () => {
      if (!app.chat) return;
      const title = window.prompt("Rename chat", app.chat.title);
      if (!title) return;
      app.chat = await post("/api/chats/" + (app.chat.id) + "/rename", { title });
      await refreshChats();
    });
    $("delete-chat").addEventListener("click", async () => {
      if (!app.chat || !window.confirm("Delete \"" + (app.chat.title) + "\"? This cannot be undone.")) return;
      await post("/api/chats/" + (app.chat.id) + "/delete", {});
      app.chat = null;
      clear($("transcript"));
      await refreshChats();
    });
    try { $("repo").value = localStorage.getItem("harness.repo") || ""; } catch (e) { /* storage may be off */ }
    setMode("chat");
  }

  wire();
  loadState()
    .then(() => { if (app.state.chats.length) return openChat(app.state.chats[0].id); return null; })
    .catch((e) => status(e.message, "bad"));
})();

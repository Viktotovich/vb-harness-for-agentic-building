// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 V and Bruno LLC
//
// The harness app (DESIGN.md 11.3-11.5). Plain browser JavaScript, no build step. Model output is never inserted
// as HTML: every text goes into the page through textContent, and the Markdown renderer builds DOM nodes. Icons
// are SVG elements built from fixed path data below.
"use strict";

(() => {
  const TOKEN = document.querySelector('meta[name="harness-token"]').content;
  const $ = (id) => document.getElementById(id);
  const SVG = "http://www.w3.org/2000/svg";
  const MARK = { done: "✓", cur: "●", wait: "", blocked: "✕", skipped: "↷" };
  const FINISHED = ["done", "failed", "stopped", "plan_rejected"];
  const RUNNING = ["running", "planning", "starting"];
  const SUB_STEPS = [["Read", "task.gather"], ["Write", "task.implement"], ["Apply", "task.apply"], ["Check", "task.gates"],
    ["Fix", "task.fix"], ["Review", "review"], ["Commit", "task.commit"]];
  const STAGE_WORDS = {
    intake: "Making a separate copy of your project and running its checks once",
    map: "Reading the project", plan: "Planning the tasks", "plan.check": "Checking the plan",
    "task.gather": "Reading files", "task.implement": "Writing changes", "task.apply": "Applying edits",
    "task.gates": "Running your checks", "task.fix": "Fixing what the checks found", "task.commit": "Committing",
    integration: "Running the final checks", final_review: "Reviewing the whole change", report: "Writing the report",
  };

  // A phone in LAN mode: models, projects and settings stay on the computer running the harness.
  const REMOTE = !["127.0.0.1", "localhost", "[::1]"].includes(location.hostname);

  const app = {
    remote: REMOTE,
    state: null, chat: null, mode: "chat", view: "home", stream: null, streamId: null, builds: new Map(),
    projects: [], settingsTab: "models", appearance: { mode: "system", dark: {}, light: {} }, preview: null, chatsTimer: null,
  };

  // ---------------------------------------------------------------- icons (fixed path data, built as SVG nodes)

  const ICONS = {
    chat: [["p", "M4 6.5A2.5 2.5 0 0 1 6.5 4h11A2.5 2.5 0 0 1 20 6.5v7a2.5 2.5 0 0 1-2.5 2.5H11l-4.5 3.5V16h0A2.5 2.5 0 0 1 4 13.5z"]],
    build: [["p", "M12 3 3 7.8l9 4.8 9-4.8z"], ["p", "m3 12.2 9 4.8 9-4.8"], ["p", "m3 16.4 9 4.6 9-4.6"]],
    plus: [["p", "M12 5v14M5 12h14"]],
    sliders: [["p", "M4 6h9M17 6h3M4 12h3M11 12h9M4 18h11M19 18h1"], ["c", 15, 6, 2], ["c", 9, 12, 2], ["c", 17, 18, 2]],
    folder: [["p", "M3.5 7.5a2 2 0 0 1 2-2h3.8l2 2h7.2a2 2 0 0 1 2 2v7.5a2 2 0 0 1-2 2h-13a2 2 0 0 1-2-2z"]],
    check: [["p", "m5 12.5 4.5 4.5L19 7.5"]],
    branch: [["c", 7, 5.5, 2], ["c", 7, 18.5, 2], ["c", 17, 7.5, 2], ["p", "M7 7.5v9"], ["p", "M17 9.5c0 4-4 5-9.2 7.6"]],
    more: [["c", 6, 12, 1.2], ["c", 12, 12, 1.2], ["c", 18, 12, 1.2]],
    up: [["p", "M12 19V6M6.5 11.5 12 6l5.5 5.5"]],
    copy: [["r", 8.5, 8.5, 11, 11, 2.2], ["p", "M15.5 8.5V6.7a2.2 2.2 0 0 0-2.2-2.2H6.7a2.2 2.2 0 0 0-2.2 2.2v6.6a2.2 2.2 0 0 0 2.2 2.2h1.8"]],
    doc: [["p", "M7 3.5h6.5l5 5V19a1.5 1.5 0 0 1-1.5 1.5H7A1.5 1.5 0 0 1 5.5 19V5A1.5 1.5 0 0 1 7 3.5z"], ["p", "M13.5 3.5V8.5h5M9 13h6M9 16.5h6"]],
    clock: [["c", 12, 12, 8.5], ["p", "M12 7.5V12l3 2"]],
    down: [["p", "m6.5 9.5 5.5 5.5 5.5-5.5"]],
    right: [["p", "m9.5 6.5 5.5 5.5-5.5 5.5"]],
    x: [["p", "M6.5 6.5l11 11M17.5 6.5l-11 11"]],
    q: [["c", 12, 12, 8.5], ["p", "M9.7 9.6a2.4 2.4 0 1 1 3.3 2.2c-.6.3-1 .8-1 1.4v.6M12 16.6h.01"]],
    stop: [["r", 7, 7, 10, 10, 2]],
    server: [["r", 4, 4.5, 16, 6, 1.8], ["r", 4, 13.5, 16, 6, 1.8], ["p", "M8 7.5h.01M8 16.5h.01"]],
    shield: [["p", "M12 3.5 5.5 6v5.6c0 4 2.8 7.2 6.5 8.9 3.7-1.7 6.5-4.9 6.5-8.9V6z"], ["p", "m9.2 12 2 2 3.8-3.8"]],
    play: [["p", "M8 5.8v12.4L18 12z"]],
    link: [["p", "M10.5 13.5a3.8 3.8 0 0 0 5.4 0l2.7-2.7a3.8 3.8 0 0 0-5.4-5.4l-.9.9"], ["p", "M13.5 10.5a3.8 3.8 0 0 0-5.4 0l-2.7 2.7a3.8 3.8 0 0 0 5.4 5.4l.9-.9"]],
    download: [["p", "M12 4.5v10.5M7.5 10.5 12 15l4.5-4.5M5 19.5h14"]],
    spark: [["p", "M12 4v4M12 16v4M4 12h4M16 12h4M6.6 6.6l2.2 2.2M15.2 15.2l2.2 2.2M6.6 17.4l2.2-2.2M15.2 8.8l2.2-2.2"]],
    note: [["p", "M5 19.5h4L19 9.5l-4-4-10 10z"], ["p", "m13.5 7 4 4"]],
    pause: [["p", "M9 6.5v11M15 6.5v11"]],
    sun: [["c", 12, 12, 3.8], ["p", "M12 3v2M12 19v2M3 12h2M19 12h2M5.6 5.6 7 7M17 17l1.4 1.4M5.6 18.4 7 17M17 7l1.4-1.4"]],
    moon: [["p", "M19.5 14.5A7.5 7.5 0 0 1 9.5 4.5a7.5 7.5 0 1 0 10 10z"]],
    monitor: [["r", 3.5, 4.5, 17, 11.5, 2], ["p", "M8.5 20h7M12 16v4"]],
    palette: [["p", "M12 3.5a8.5 8.5 0 1 0 0 17c1.2 0 1.8-.8 1.8-1.7 0-1.2-1-1.6-1-2.6 0-.9.7-1.6 1.6-1.6h2.1a4 4 0 0 0 4-4C20.5 6.6 16.7 3.5 12 3.5z"],
      ["c", 7.8, 11.5, 1], ["c", 10, 7.6, 1], ["c", 14.6, 7.6, 1]],
    resume: [["p", "M6 5.5v13"], ["p", "M10 5.8v12.4L19 12z"]],
    menu: [["p", "M4 7h16M4 12h16M4 17h16"]],
  };

  function icon(name, cls) {
    const svg = document.createElementNS(SVG, "svg");
    svg.setAttribute("class", "i" + (cls ? " " + cls : ""));
    svg.setAttribute("viewBox", "0 0 24 24");
    svg.setAttribute("aria-hidden", "true");
    for (const [kind, ...a] of ICONS[name] || []) {
      let shape;
      if (kind === "p") { shape = document.createElementNS(SVG, "path"); shape.setAttribute("d", a[0]); }
      else if (kind === "c") { shape = document.createElementNS(SVG, "circle"); ["cx", "cy", "r"].forEach((k, i) => shape.setAttribute(k, a[i])); }
      else { shape = document.createElementNS(SVG, "rect"); ["x", "y", "width", "height", "rx"].forEach((k, i) => shape.setAttribute(k, a[i])); }
      svg.append(shape);
    }
    return svg;
  }

  // <span data-icon="name"> in index.html becomes its icon.
  function hydrateIcons(root) {
    for (const span of root.querySelectorAll("span[data-icon]")) span.replaceWith(icon(span.dataset.icon, "sm"));
  }

  // ---------------------------------------------------------------- DOM helpers (text only)

  function el(tag, attrs, ...children) {
    const node = document.createElement(tag);
    for (const [k, v] of Object.entries(attrs || {})) {
      if (v === null || v === undefined || v === false) continue;
      if (k === "class") node.className = v;
      else if (k === "text") node.textContent = v;
      else if (k.startsWith("on")) node.addEventListener(k.slice(2), v);
      else node.setAttribute(k, v === true ? "" : v);
    }
    for (const c of children) if (c !== null && c !== undefined && c !== false) node.append(c);
    return node;
  }

  function clear(node) {
    while (node.firstChild) node.removeChild(node.firstChild);
  }

  function button(label, attrs, iconName) {
    const b = el("button", Object.assign({ type: "button", class: "btn" }, attrs || {}));
    if (iconName) b.append(icon(iconName, "sm"));
    if (label) b.append(document.createTextNode(label));
    return b;
  }

  function copyText(text, b) {
    navigator.clipboard.writeText(text).then(() => {
      const old = b.lastChild.textContent;
      b.lastChild.textContent = "Copied";
      setTimeout(() => { b.lastChild.textContent = old; }, 1200);
    }).catch(() => {});
  }

  // ---------------------------------------------------------------- server calls

  async function get(path) {
    const res = await fetch(path, { headers: { Accept: "application/json" } });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || "HTTP " + res.status);
    return data;
  }

  async function post(path, body) {
    const res = await fetch(path, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Harness-Token": TOKEN },
      body: JSON.stringify(body || {}),
    });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || "HTTP " + res.status);
    return data;
  }

  // A POST that may answer 409 with {"confirm": {...}}: what it would run, for the user to agree to first.
  async function postConfirmable(path, body) {
    const res = await fetch(path, {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-Harness-Token": TOKEN },
      body: JSON.stringify(body || {}),
    });
    const data = await res.json().catch(() => ({}));
    if (res.status === 409 && data.confirm) return { confirm: data.confirm };
    if (!res.ok) throw new Error(data.error || "HTTP " + res.status);
    return { done: data };
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
        frag.append(el("span", { class: "link-text", text: label + " (" + url + ")" }));
      }
      last = m.index + t.length;
    }
    if (last < text.length) frag.append(document.createTextNode(text.slice(last)));
    return frag;
  }

  function codeBlock(code, lang) {
    const copy = button("Copy", { class: "btn ghost sm" }, "copy");
    copy.addEventListener("click", () => copyText(code, copy));
    const pre = el("pre", {}, el("code", { text: code }));
    if (lang) pre.setAttribute("data-lang", lang);
    return el("div", { class: "codeblock" }, el("div", { class: "code-head" }, el("span", { text: lang || "code" }), copy), pre);
  }

  // A table's second line: | --- | :---: | ...
  const TABLE_RULE = /^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$/;

  // The cells of one table row; "\|" is a literal pipe inside a cell.
  function cells(row) {
    const parts = row.trim().replace(/^\|/, "").replace(/(^|[^\\])\|$/, "$1").split(/(?<!\\)\|/);
    return parts.map((c) => c.trim().replace(/\\\|/g, "|"));
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
        root.append(el("h" + Math.min(h[1].length + 1, 4), {}, inline(h[2])));
        i += 1;
        continue;
      }
      if (/^\s*\|/.test(line) && i + 1 < lines.length && TABLE_RULE.test(lines[i + 1])) {
        flush();
        const head = cells(line);
        const table = el("table", {}, el("thead", {}, el("tr", {}, ...head.map((c) => el("th", {}, inline(c))))));
        const tbody = el("tbody");
        i += 2;
        while (i < lines.length && /^\s*\|/.test(lines[i])) {
          tbody.append(el("tr", {}, ...cells(lines[i]).map((c) => el("td", {}, inline(c)))));
          i += 1;
        }
        table.append(tbody);
        root.append(el("div", { class: "table-wrap" }, table));
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

  // ---------------------------------------------------------------- state, sidebar, top bar

  async function loadState() {
    app.state = await get("/api/state");
    if (app.state.appearance) app.appearance = app.state.appearance;
    renderChats();
    renderPicker();
    syncStatus();
    syncComposer();
  }

  function renderChats() {
    const list = $("chat-list");
    clear(list);
    const chats = app.state ? app.state.chats : [];
    if (!chats.length) {
      list.append(el("div", { class: "side-label", text: "No chats yet" }));
      return;
    }
    const today = new Date().toDateString();
    let group = null;
    for (const c of chats) {
      const label = new Date(c.updated).toDateString() === today ? "Today" : "Earlier";
      if (label !== group) { list.append(el("div", { class: "side-label", text: label })); group = label; }
      const on = app.view === "chat" && app.chat && app.chat.id === c.id;
      const b = el("button", { class: "chat-item" + (on ? " on" : ""), type: "button", title: c.title, "aria-current": on ? "page" : null },
        el("span", { class: "ic" }, icon(c.run ? "build" : "chat", "sm")), el("span", { class: "t", text: c.title }), chatBadge(c.runStatus));
      b.addEventListener("click", () => openChat(c.id));
      list.append(b);
    }
  }

  function chatBadge(st) {
    if (!st) return null;
    if (RUNNING.includes(st)) return el("span", { class: "badge run", text: "Building" });
    if (st === "waiting") return el("span", { class: "badge warn", text: "Needs you" });
    if (st === "failed" || st === "plan_rejected") return el("span", { class: "badge bad", text: "Failed" });
    if (st === "stopped") return el("span", { class: "badge plain", text: "Stopped" });
    if (st === "done") return el("span", { class: "faint", text: "✓", title: "Done" });
    return null;
  }

  // The chat list again, at most every second (build cards ask for it when a run's status changes).
  function refreshChatsSoon() {
    if (app.chatsTimer) return;
    app.chatsTimer = setTimeout(async () => {
      app.chatsTimer = null;
      try { app.state.chats = await get("/api/chats"); renderChats(); } catch (e) { /* the next change retries */ }
    }, 1000);
  }

  async function refreshChats() {
    app.state.chats = await get("/api/chats");
    renderChats();
  }

  function renderPicker() {
    const pick = $("model-picker");
    clear(pick);
    const models = app.state ? app.state.models : [];
    $("model-box").hidden = !models.length || app.view === "settings";
    models.forEach((m, i) => {
      const o = el("option", { value: String(i), text: m.error ? m.label + " (unreachable)" : m.label });
      if (app.chat && app.chat.model && app.chat.model.profile === m.profile && app.chat.model.model === m.model) o.selected = true;
      pick.append(o);
    });
    const chosen = models[Number(pick.value)];
    $("chip-dot").className = "dot " + (chosen && chosen.error ? "bad" : "ok");
  }

  function currentModel() {
    const models = app.state ? app.state.models : [];
    return models[Number($("model-picker").value)] || models[0] || null;
  }

  // The model line at the foot of the sidebar: set up or not, and whether anything is working right now.
  function syncStatus() {
    const configured = app.state && app.state.configured;
    const m = currentModel();
    const busy = !!app.stream || [...app.builds.values()].some((c) => c.es && RUNNING.includes(c.run.status || "starting"));
    $("status-name").textContent = configured ? (m ? m.model : "model") : "No model set up";
    $("status-text").textContent = !configured ? "" : m && m.error ? "unreachable" : app.stream ? "answering" : busy ? "working" : "ready";
    $("status-dot").className = "dot " + (!configured || (m && m.error) ? "bad" : busy ? "busy" : "ok");
  }

  function syncTop() {
    const title = $("view-title");
    const sub = $("view-sub");
    const chatOpen = app.view === "chat" && app.chat;
    if (app.view === "settings") { title.textContent = "Settings"; sub.textContent = ""; }
    else if (chatOpen) {
      title.textContent = app.chat.title;
      const built = app.chat.messages.filter((m) => m.role === "build").pop();
      sub.textContent = app.mode === "build" ? "Build · " + ($("project-picker").value || "no project")
        : built ? "Build · " + (built.project || "project") : "Chat · changes no files";
    } else { title.textContent = "Welcome"; sub.textContent = ""; }
    $("chat-menu").hidden = !chatOpen;
    $("model-box").hidden = app.view === "settings" || !(app.state && app.state.models.length);
    $("open-settings").classList.toggle("on", app.view === "settings");
    closeMenu();
  }

  function closeMenu() {
    $("chat-menu-list").hidden = true;
    $("chat-menu").setAttribute("aria-expanded", "false");
  }

  // ---------------------------------------------------------------- views

  // Phones: the sidebar slides in over the page and closes when something in it is chosen.
  function setSide(open) {
    $("app").classList.toggle("side-open", open);
    $("side-toggle").setAttribute("aria-expanded", String(open));
  }

  function showView(view) {
    if (app.view === "settings" && view !== "settings") discardPreview();
    setSide(false);
    app.view = view;
    $("settings").hidden = view !== "settings";
    $("transcript").hidden = view === "settings";
    $("composer-wrap").hidden = view === "settings";
    if (view === "settings") renderSettings();
    else if (view === "home") renderHome();
    syncTop();
    renderChats();
    syncComposer();
  }

  async function openChat(id) {
    saveDraft();
    app.chat = await get("/api/chats/" + encodeURIComponent(id));
    app.view = "chat";
    showView("chat");
    renderPicker();
    renderTranscript();
    $("input").value = loadDraft();
    autosize();
  }

  // Home: the first-run steps, which stay as a start page once everything is set up.
  async function renderHome() {
    app.chat = null;
    const t = $("transcript");
    clear(t);
    const configured = app.state && app.state.configured;
    const hasProject = app.projects.length > 0;
    const found = el("div", { class: "found" }, el("span", { class: "badge plain", text: "Looking on this computer…" }));
    const model = currentModel();
    const step = (n, state, title, desc, extra, action) => el("div", { class: "card wstep " + state },
      el("span", { class: "num", text: state === "done" ? "✓" : String(n) }),
      el("div", {}, el("div", { class: "h", text: title }), el("div", { class: "d", text: desc }), extra), action || el("span"));
    const connect = button(configured ? "Models" : "Connect", { class: "btn" + (configured ? "" : " primary") }, configured ? "server" : "right");
    connect.addEventListener("click", () => openSettings("models"));
    const add = button("Add project", { class: "btn" + (configured && !hasProject ? " primary" : ""), disabled: !configured }, "plus");
    add.addEventListener("click", () => addProjectModal("link"));
    const start = button("New chat", { class: "btn" + (configured && hasProject ? " primary" : ""), disabled: !configured }, "chat");
    start.addEventListener("click", newChat);
    const demo = button("Try the demo", {}, "play");
    demo.addEventListener("click", () => runDemo(demo));
    t.append(el("div", { class: "welcome" },
      el("div", {}, el("h2", { text: configured ? "What shall we build?" : "Let's build something with your local model" }),
        el("p", { class: "lead", text: "The harness plans your feature as small tasks, has your model write each one, and keeps only changes that pass your project's own checks." })),
      el("div", { class: "steps" },
        step(1, configured ? "done" : "cur", "Connect a model",
          configured ? "Using " + (model ? model.label : "your model") + "." : "Found on this computer:", configured ? null : found, connect),
        step(2, !configured ? "later" : hasProject ? "done" : "cur", "Add a project",
          hasProject ? app.projects.map((p) => p.name).join(", ") : "Link a git folder on this computer, clone one, or start a new Astro site.", null, add),
        step(3, configured && hasProject ? "cur" : "later", "Describe what to build",
          "Chat to plan it first, or switch to Build, pick the project and send the request.", null, start)),
      el("div", { class: "card demo-card" }, el("div", { class: "b-icon" }, icon("play")),
        el("div", { class: "grow" }, el("div", { class: "h", text: "Watch a 20-second demo build" }),
          el("div", { class: "muted", text: "A scripted model plans two tasks on a sample project, fails a check, fixes it and gets reviewed. Nothing is installed and your projects are not touched." })),
        demo)));
    if (!configured) {
      try {
        const providers = await get("/api/providers");
        clear(found);
        for (const p of providers) found.append(el("span", { class: "badge plain", text: p.label + " · " + providerState(p).text.toLowerCase() }));
      } catch (e) { found.textContent = e.message; }
    }
  }

  function renderTranscript() {
    const t = $("transcript");
    clear(t);
    const col = el("div", { class: "col" });
    t.append(col);
    if (!app.chat.messages.length) col.append(emptyChat());
    let request = "";
    for (const m of app.chat.messages) {
      if (m.role === "user") request = m.content;
      if (m.role === "build") m.request = request;
      col.append(messageNode(m));
    }
    t.scrollTop = t.scrollHeight;
    syncComposer();
  }

  function emptyChat() {
    const card = (name, title, text) => el("div", { class: "card mode-card" }, el("div", { class: "h" }, icon(name, "sm"), document.createTextNode(title)), el("div", { class: "d", text }));
    return el("div", { class: "empty" }, el("h2", { text: "What are we making?" }),
      el("div", { class: "muted", text: "Type below. Choose Chat or Build under the text box." }),
      el("div", { class: "modes" },
        card("chat", "Chat", "Plan with the model: goals, approaches, trade-offs, small steps. It never changes files."),
        card("build", "Build", "Describe a feature and pick a project. The harness plans it, builds it task by task on a new branch, and checks every change.")));
  }

  function messageNode(m) {
    if (m.role === "user") return el("div", { class: "msg user", text: m.content });
    if (m.role === "note") return el("div", { class: "msg note", text: m.content });
    if (m.role === "build") return buildCard(m.runId, m.project, m.request).node;
    const node = el("div", { class: "msg assistant" });
    node.append(el("div", { class: "who" }, el("span", { class: "avatar", text: "AI" }), el("span", { text: m.model || "model" })));
    if (m.thinking) node.append(thinkingBlock(m.thinking));
    if (m.retried) node.append(el("div", { class: "meta", text: "Ran out of room while thinking; answered with thinking off." }));
    node.append(markdown(m.content));
    if (m.finish && m.finish !== "stop") node.append(el("div", { class: "meta", text: "ended: " + m.finish }));
    if (m.content) node.append(suggestRow(m.content));
    return node;
  }

  function thinkingBlock(text) {
    return el("details", { class: "thinking" }, el("summary", { text: "Thinking" }), el("div", { text }));
  }

  // "Use as build request": copies the reply into the text box in Build mode. It only fills the box; the user still
  // edits it, picks a project and sends (a model's words never start anything).
  function suggestRow(text) {
    const b = button("Use as build request", { class: "btn soft sm" }, "build");
    b.addEventListener("click", () => useAsRequest(text));
    return el("div", { class: "suggest" }, el("span", { class: "grow", text: "Ready to build it? This reply can become a Build request: you edit it before anything starts." }), b);
  }

  function useAsRequest(text) {
    setMode("build");
    $("input").value = text;
    saveDraft();
    autosize();
    $("input").focus();
    note("Edit the request, check the project, then Start build.", "build");
  }

  // ---------------------------------------------------------------- composer

  function note(text, iconName, bad) {
    const n = $("composer-note");
    clear(n);
    n.className = "composer-note" + (bad ? " bad" : "");
    if (iconName) n.append(icon(iconName, "sm"));
    n.append(document.createTextNode(text));
  }

  function project() {
    return app.projects.find((p) => p.name === $("project-picker").value) || null;
  }

  // Placeholder, send button, project state and the line under the box, from the mode and what is going on.
  function syncComposer() {
    const configured = app.state && app.state.configured;
    const build = app.mode === "build";
    const input = $("input");
    input.disabled = !configured;
    input.placeholder = !configured ? "Set up a model first, or try the demo"
      : build ? "Describe the feature to build…" : "Ask anything: plan a feature, compare approaches…";
    $("project-box").hidden = !build;
    const send = $("send");
    clear(send);
    send.append(icon(build ? "play" : "up", "sm"));
    if (build) send.append(document.createTextNode("Start build"));
    send.className = "send" + (build ? " label" : "");
    send.setAttribute("aria-label", build ? "Start build" : "Send");
    const p = project();
    const state = $("project-state");
    state.className = "pstate";
    state.textContent = "";
    if (p && p.error) { state.className = "pstate bad"; state.textContent = "✕ problem"; }
    else if (p && !p.clean) { state.className = "pstate bad"; state.textContent = "✕ uncommitted changes"; }
    else if (p) { state.className = "pstate ok"; state.textContent = "✓ " + (p.branch || "") + " · clean"; }
    send.disabled = !configured || !!app.stream || (build && (!p || !!p.error || !p.clean));
    $("project-preview").hidden = app.remote || !p || !p.preview;
    $("project-add").hidden = app.remote;
    syncStop();
    const running = runningBuild();
    if (!configured) note("Connect a model in Settings to start. The demo needs none.", "server");
    else if (running && !build) note("A build is running in this chat. You can keep chatting, or send the agent a note in its card.", "clock");
    else if (build && !app.projects.length) note("Add a project to build in: + Add project.", "folder");
    else if (build && p && p.error) {
      note((p.display || p.name) + ": " + p.error, "x", true);
      for (const fx of app.remote ? [] : (p.fixes || [])) {
        const b = button(fx.label, { class: "btn soft sm", title: fx.command }, "check");
        b.addEventListener("click", () => runFix("/api/projects/fix", { name: p.name, fix: fx.id }, () => loadProjects()));
        $("composer-note").append(b);
      }
    }
    else if (build && p && !p.clean) note(p.name + " has uncommitted changes. Commit or stash them, then build.", "x", true);
    else if (build) note("Works on a new branch in a separate copy" + (p && p.stack ? " (" + p.stack + (p.version ? " " + p.version : "") + ")" : "") + ". Your checkout is never touched.", "branch");
    else note("Chat plans with you and never changes files. Switch to Build when you're ready.", "chat");
    if (app.view === "chat" && app.chat) syncTop();
  }

  function autosize() {
    const t = $("input");
    t.style.height = "auto";
    t.style.height = Math.min(t.scrollHeight + 2, window.innerHeight * 0.4) + "px";
  }

  function setMode(mode) {
    app.mode = mode;
    for (const b of document.querySelectorAll(".seg button")) {
      const on = b.dataset.mode === mode;
      b.classList.toggle("on", on);
      b.setAttribute("aria-checked", String(on));
    }
    if (mode === "build") loadProjects();
    syncComposer();
  }

  // ---------------------------------------------------------------- sending

  async function ensureChat() {
    if (app.chat) return app.chat;
    const chosen = currentModel();
    app.chat = await post("/api/chats", { model: chosen ? { profile: chosen.profile, model: chosen.model } : null });
    app.view = "chat";
    await refreshChats();
    showView("chat");
    renderTranscript();
    return app.chat;
  }

  async function newChat() {
    saveDraft();
    app.chat = null;
    await ensureChat();
    $("input").value = loadDraft();
    autosize();
    $("input").focus();
  }

  async function send() {
    const input = $("input");
    const text = input.value;
    if (!text.trim() || app.stream || $("send").disabled) return;
    try {
      const chat = await ensureChat();
      if (app.mode === "build") {
        const p = project();
        if (!p) throw new Error("Choose a project first, or add one.");
        await post("/api/chats/" + chat.id + "/send", { text, mode: "build", project: p.name });
        input.value = "";
        saveDraft();
        autosize();
        app.chat = await get("/api/chats/" + chat.id);
        renderTranscript();
      } else {
        const out = await post("/api/chats/" + chat.id + "/send", { text, mode: "chat" });
        input.value = "";
        saveDraft();
        autosize();
        const col = $("transcript").querySelector(".col");
        const empty = col.querySelector(".empty");
        if (empty) empty.remove();
        col.append(el("div", { class: "msg user", text }));
        streamReply(out.stream);
      }
      await refreshChats();
      const listed = app.state.chats.find((c) => app.chat && c.id === app.chat.id);
      if (listed) { app.chat.title = listed.title; syncTop(); }
    } catch (e) {
      const col = $("transcript").querySelector(".col");
      if (col) col.append(el("div", { class: "msg error", text: e.message }));
    }
    syncStatus();
  }

  function streamReply(id) {
    const t = $("transcript");
    const col = t.querySelector(".col");
    const model = currentModel();
    const node = el("div", { class: "msg assistant" }, el("div", { class: "who" }, el("span", { class: "avatar", text: "AI" }), el("span", { text: model ? model.model : "model" })));
    const thinking = el("div");
    const details = el("details", { class: "thinking", hidden: true }, el("summary", { text: "Thinking" }), thinking);
    const body = el("div");
    const cursor = el("span", { class: "cursor" });
    node.append(details, body, cursor);
    col.append(node);
    let text = "";
    let pending = false;
    const paint = () => {
      pending = false;
      clear(body);
      body.append(markdown(text));
      t.scrollTop = t.scrollHeight;
    };
    const es = new EventSource("/api/streams/" + id);
    app.stream = es;
    app.streamId = id;
    syncStatus();
    syncComposer();
    const end = () => {
      es.close();
      cursor.remove();
      app.stream = null;
      app.streamId = null;
      syncStatus();
      syncComposer();
    };
    es.addEventListener("text", (ev) => {
      text += JSON.parse(ev.data).text;
      if (!pending) { pending = true; setTimeout(paint, 60); }
    });
    es.addEventListener("thinking", (ev) => {
      details.hidden = false;
      thinking.textContent += JSON.parse(ev.data).text;
    });
    es.addEventListener("notice", (ev) => {
      node.insertBefore(el("div", { class: "meta", text: JSON.parse(ev.data).text }), body);
    });
    es.addEventListener("done", () => {
      paint();
      if (text.trim()) node.append(suggestRow(text));
      end();
    });
    es.addEventListener("error", (ev) => {
      const msg = ev.data ? JSON.parse(ev.data).error : "the connection closed";
      node.append(el("div", { class: "msg error", text: msg }));
      end();
    });
  }

  // A chat reply stops at once; a build stops before its next task, keeping what it committed.
  async function stop() {
    if (app.streamId) {
      await post("/api/streams/" + app.streamId + "/stop", {}).catch(() => {});
      return;
    }
    const card = runningBuild();
    if (card) await stopRun(card);
  }

  async function stopRun(card) {
    card.stopping = true;
    card.render();
    try {
      await post("/api/runs/" + card.runId + "/stop", {});
    } catch (e) {
      card.stopping = false;
      card.error = e.message;
      card.render();
    }
  }

  // The build of the open chat that is still going, if any.
  function runningBuild() {
    if (!app.chat) return null;
    for (const m of app.chat.messages) {
      const card = m.role === "build" && app.builds.get(m.runId);
      if (card && card.es && RUNNING.includes(card.run.status || "starting")) return card;
    }
    return null;
  }

  function syncStop() {
    const card = !app.streamId && runningBuild();
    const b = $("stop");
    b.hidden = !app.streamId && !card;
    b.disabled = !!(card && card.stopping);
    b.lastChild.textContent = card && card.stopping ? "Stopping…" : app.streamId ? "Stop" : "Stop build";
  }

  // ---------------------------------------------------------------- build cards (progress view, DESIGN.md 11.5)

  function buildCard(runId, projectName, request) {
    if (app.builds.has(runId)) {
      const known = app.builds.get(runId);
      if (request && !known.request) { known.request = request; known.render(); }
      return known;
    }
    const node = el("section", { class: "card build", "aria-label": "Build" });
    const card = {
      node, runId, project: projectName, request, events: [], seq: 0, run: {}, tasks: [], open: false, why: false, whyCode: null,
      activity: false, es: null, timer: null, stopping: false, error: null, status: null,
      noteInput: el("input", { class: "input", type: "text", "data-keep": "1", "aria-label": "Note to the agent" }),
      answers: [], answersKey: "",
    };
    card.render = () => renderBuild(card);
    card.resume = () => connect(card);
    app.builds.set(runId, card);
    connect(card);
    card.render();
    return card;
  }

  function connect(card) {
    if (card.es) card.es.close();
    const es = new EventSource("/api/runs/" + card.runId + "/events?after=" + card.seq);
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
      card.stopping = !!r.stopping && !idle(r.status);
      if (r.tasks) card.tasks = r.tasks;
      if (r.status !== card.status) { card.status = r.status; refreshChatsSoon(); }
      later();
    });
    es.addEventListener("failed", (ev) => {
      card.run = Object.assign({}, card.run, { status: "failed", error: JSON.parse(ev.data).error });
      refreshChatsSoon();
      later();
    });
    es.addEventListener("end", () => {
      es.close();
      card.es = null;
      card.stopping = false;
      refreshChatsSoon();
      later();
    });
  }

  function idle(st) {
    return FINISHED.includes(st) || ["waiting", "planned", "error"].includes(st);
  }

  function fold(card) {
    const tasks = {};
    const reasons = new Map();
    let produced = 0, accepted = 0, rejected = 0;
    const runStages = {};
    let runStage = null, runSubject = null, lastTaskEvent = null;
    for (const e of card.events) {
      // Intake's notes (a check skipped before the run) are not model answers.
      if (e.stage === "intake" && (e.kind === "accepted" || e.kind === "rejected")) continue;
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
        t.seen.add(e.stage.startsWith("review.") ? "review" : e.stage);
        t.attempt = Math.max(t.attempt, e.attempt || 1);
        if (["done", "blocked", "skipped"].includes(e.kind) && e.subject === "task") {
          t.status = e.kind;
          t.reason = e.reasonText || e.detail || null;
          t.commit = e.kind === "done" ? e.detail : null;
        }
        lastTaskEvent = e;
      } else {
        if (e.kind === "stage_started" || e.kind === "stage_finished") runStages[e.stage] = e.kind === "stage_finished" ? "done" : "active";
        runStage = e.stage;
        runSubject = e.subject || null;
      }
    }
    const first = card.events[0], last = card.events[card.events.length - 1];
    const tokens = card.events.reduce((n, e) => n + (e.tokens ? (e.tokens.in || 0) + (e.tokens.out || 0) : 0), 0);
    return { tasks, reasons: [...reasons.values()].sort((a, b) => b.items.length - a.items.length), produced, accepted, rejected,
      runStages, runStage, runSubject, lastTaskEvent, first, last, tokens };
  }

  function stageWords(stage) {
    if (!stage) return "Starting";
    if (stage.startsWith("review.")) return "Reviewing (" + stage.slice(7).replace(/_/g, " ") + ")";
    return STAGE_WORDS[stage] || stage;
  }

  function duration(s) {
    s = Math.max(0, Math.round(s));
    if (s < 60) return s + "s";
    if (s < 3600) return Math.floor(s / 60) + "m " + (s % 60) + "s";
    return Math.floor(s / 3600) + "h " + Math.floor((s % 3600) / 60) + "m";
  }

  function clockTime(iso) {
    const d = new Date(iso);
    return isNaN(d) ? "" : d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit" });
  }

  function tokensText(n) {
    return n >= 1000 ? (n / 1000).toFixed(n >= 100000 ? 0 : 1) + "K tokens" : n + " tokens";
  }

  function statusBadge(st, f, blocked) {
    if (RUNNING.includes(st)) return el("span", { class: "badge run", text: "Building" });
    if (st === "waiting") return el("span", { class: "badge warn", text: "Waiting for you" });
    if (st === "done") return blocked ? el("span", { class: "badge warn", text: "Done, with blocked tasks" }) : el("span", { class: "badge ok", text: "Done" });
    if (st === "stopped") return el("span", { class: "badge plain", text: "Stopped" });
    if (st === "planned") return el("span", { class: "badge plain", text: "Planned" });
    if (st === "plan_rejected") return el("span", { class: "badge bad", text: "Plan rejected" });
    return el("span", { class: "badge bad", text: "Failed" });
  }

  function renderBuild(card) {
    const f = fold(card);
    const node = card.node;
    // Inputs inside the card survive the re-render (same elements), and keep focus and caret.
    const active = document.activeElement;
    const keep = active && node.contains(active) && active.dataset && active.dataset.keep ? active : null;
    const caret = keep && typeof keep.selectionStart === "number" ? [keep.selectionStart, keep.selectionEnd] : null;
    clear(node);
    const st = card.run.status || "starting";
    const questions = card.run.questions || [];
    const waiting = st === "waiting" && questions.length > 0;
    const finished = FINISHED.includes(st) || st === "error";
    const running = RUNNING.includes(st);
    const total = card.tasks.length;
    const states = card.tasks.map((t) => (f.tasks[t.id] || {}).status);
    const doneCount = states.filter((s) => s === "done").length;
    const blocked = states.filter((s) => s === "blocked").length;
    const skipped = states.filter((s) => s === "skipped").length;
    const finishedTasks = doneCount + blocked + skipped;
    node.className = "card build" + (waiting ? " needs" : "");

    // head
    const iconName = waiting ? "q" : st === "done" ? "check" : st === "stopped" ? "pause" : finished ? "x" : "build";
    const iconCls = waiting ? "warn" : st === "done" ? "ok" : finished && st !== "stopped" ? "bad" : "";
    const title = (card.request || "").split("\n").find((l) => l.trim()) || "Build " + card.runId;
    const sub = el("div", { class: "sub" }, icon("folder", "sm"), el("span", { text: card.project || "project" }));
    if (card.run.branch) sub.append(el("span", { text: "·" }), icon("branch", "sm"), el("span", { class: "mono", text: card.run.branch }));
    if (card.run.mode) sub.append(el("span", { text: "· " + (card.run.mode === "agent" ? "Agent mode" : "Pipeline mode") }));
    const elapsed = f.first ? ((finished || !card.es ? Date.parse(f.last.at) : Date.now()) - Date.parse(f.first.at)) / 1000 : 0;
    const when = f.first ? duration(elapsed) + (finished ? " · finished " + clockTime(f.last.at) : " · started " + clockTime(f.first.at)) : "starting…";
    const head = el("div", { class: "b-head" }, el("div", { class: "b-icon " + iconCls }, icon(iconName)),
      el("div", { class: "b-title" }, el("h3", { text: title.length > 160 ? title.slice(0, 160) + "…" : title, title }), sub),
      el("div", { class: "b-status" }, statusBadge(st, f, blocked), el("span", { class: "time", text: when })));
    node.append(head);

    const summary = () => {
      const chips = el("div", { class: "done-sum" });
      if (total) chips.append(el("span", { class: "cap" + (doneCount === total ? " ok" : ""), text: doneCount + " of " + total + " tasks committed" }));
      if (blocked) chips.append(el("span", { class: "cap bad", text: blocked + " blocked" }));
      if (skipped) chips.append(el("span", { class: "cap", text: skipped + " skipped" }));
      if (f.rejected) chips.append(el("span", { class: "cap", text: f.rejected + " model answers caught by the checks" }));
      if (f.tokens) chips.append(el("span", { class: "cap", text: tokensText(f.tokens) }));
      return chips;
    };
    const nextRow = () => {
      if (st === "done" && card.run.branch) {
        const copy = button("Copy branch", { class: "btn sm" }, "copy");
        copy.addEventListener("click", () => copyText(card.run.branch, copy));
        return el("div", { class: "next" }, icon("branch", "sm"), el("div", { class: "grow" }, document.createTextNode("Your work is on branch "),
          el("code", { text: card.run.branch }), document.createTextNode(". Your checkout is unchanged: merge the branch when you're happy.")), copy);
      }
      if (st === "stopped") {
        const again = button("Resume", { class: "btn sm primary" }, "resume");
        again.addEventListener("click", () => resumeRun(card, again));
        return el("div", { class: "next" }, icon("pause", "sm"), el("div", { class: "grow", text: "Stopped. Committed tasks are kept; Resume continues where it left off." }), again);
      }
      if (st === "failed" || st === "error") return failRow(card);
      if (st === "plan_rejected") return el("div", { class: "next bad" }, icon("x", "sm"), el("div", { class: "grow", text: "The plan did not pass its checks after the allowed rounds. See the report for why; try a smaller or clearer request." }));
      return null;
    };
    const actions = () => {
      const row = el("div", { class: "b-actions" });
      const report = button("View report", { class: "btn primary" }, "doc");
      report.addEventListener("click", () => openReport(card));
      const more = button(card.open ? "Hide details" : "Show details", {}, card.open ? "down" : "right");
      more.addEventListener("click", () => { card.open = !card.open; card.render(); });
      row.append(report, more);
      if (card.run.canPreview && !app.remote) {
        const prev = button("Preview", {}, "play");
        prev.addEventListener("click", () => openPreview({ run: card.runId }, "what build " + card.runId + " made"));
        row.append(prev);
      }
      return row;
    };

    if (finished && !card.open) {
      node.append(summary(), nextRow() || el("span"), actions());
      if (card.error) node.append(el("div", { class: "b-actions error-text", text: card.error }));
      afterRender(card, keep, caret);
      return;
    }

    // stepper
    const planState = waiting ? "ask" : st === "plan_rejected" ? "bad" : total ? "done" : running ? "cur" : "";
    const tasksState = !total ? "" : finishedTasks === total ? "done" : running ? "cur" : "";
    const runStep = (key) => f.runStages[key] === "done" || (st === "done" && key !== "integration" ? true : f.runStages[key] === "done") ? "done" : f.runStages[key] === "active" ? "cur" : "";
    const steps = [["Plan", planState], ["Tasks", tasksState, total ? finishedTasks + " of " + total : ""],
      ["Final checks", st === "done" ? "done" : runStep("integration")], ["Review", st === "done" ? "done" : runStep("final_review")],
      ["Report", st === "done" ? "done" : runStep("report")]];
    const stepper = el("div", { class: "stepper", "aria-label": "Progress" });
    steps.forEach(([name, s, extra], i) => {
      const mark = s === "done" ? "✓" : s === "cur" ? "●" : s === "ask" ? "?" : s === "bad" ? "✕" : String(i + 1);
      stepper.append(el("div", { class: "step " + s }, el("span", { class: "c", text: mark }), el("span", { class: "lbl", text: name }), extra ? el("span", { class: "faint", text: " " + extra }) : null));
      if (i < steps.length - 1) stepper.append(el("div", { class: "line" + (s === "done" ? " done" : "") }));
    });
    node.append(stepper);

    // now
    if (running) {
      const activeTask = card.tasks.find((t) => f.tasks[t.id] && f.tasks[t.id].status === "running");
      let what;
      if (activeTask) what = [el("span", { text: activeTask.id + " " + activeTask.title + ": " }), el("strong", { text: stageWords(f.tasks[activeTask.id].stage).toLowerCase() })];
      else what = [el("strong", { text: stageWords(f.runStage) }), f.runSubject && f.runStage === "map" ? el("span", { class: "faint", text: " · " + f.runSubject.slice(0, 80) }) : null];
      const ago = f.last ? (Date.now() - Date.parse(f.last.at)) / 1000 : 0;
      const small = f.last ? "updated " + duration(ago) + " ago" : "starting…";
      node.append(el("div", { class: "nowbar" }, el("span", { class: "pulse" }), el("span", { class: "lbl", text: "Now" }),
        el("span", { class: "grow" }, ...what), el("span", { class: "small", text: small })));
      if (ago > 120) node.append(el("div", { class: "help nowhelp" }, document.createTextNode("Quiet for a while: the model is still writing. Long answers on a local model can take several minutes.")));
    }

    // questions
    if (waiting) node.append(askBox(card, questions));

    // tasks
    if (total) {
      const list = el("div", { class: "tasks" });
      for (const task of card.tasks) {
        const t = f.tasks[task.id];
        let mark = "wait", right;
        if (!t) {
          const wait = (task.dependsOn || []).filter((d) => !(f.tasks[d] && f.tasks[d].status === "done"));
          right = el("span", { text: wait.length ? "waits for " + wait.join(", ") : finished ? "not started" : "waiting" });
        } else if (t.status === "done") {
          mark = "done";
          right = el("span", { class: "row" }, t.commit ? el("span", { class: "sha", text: t.commit.slice(0, 7) }) : null, el("span", { text: t.attempt > 1 ? "attempt " + t.attempt : "committed" }));
        } else if (t.status === "blocked") { mark = "blocked"; right = el("span", { text: "blocked" }); }
        else if (t.status === "skipped") { mark = "skipped"; right = el("span", { text: "skipped" }); }
        else if (!running) { mark = "wait"; right = el("span", { text: "stopped at: " + stageWords(t.stage).toLowerCase() }); }
        else { mark = "cur"; right = el("span", { class: "row" }, el("span", { class: "now-word", text: stageWords(t.stage) }), el("span", { text: "· attempt " + t.attempt })); }
        list.append(el("div", { class: "task" }, el("span", { class: "m " + mark, text: MARK[mark] }), el("span", { class: "id", text: task.id }),
          el("span", { class: "tt", text: task.title, title: task.title }), el("span", { class: "r" }, right)));
        if (t && t.status === "blocked") list.append(el("div", { class: "task-note", text: (t.reason || "blocked") + " · patch: runs/" + card.runId + "/tasks/" + task.id + "/blocked.patch" }));
        if (t && t.status === "skipped" && t.reason) list.append(el("div", { class: "task-note plain", text: t.reason }));
        if (t && t.status === "running" && running) {
          const cur = t.stage && t.stage.startsWith("review.") ? "review" : t.stage;
          list.append(el("div", { class: "sub-steps" }, ...SUB_STEPS.map(([name, key]) =>
            el("span", { class: "ss " + (key === cur ? "cur" : t.seen.has(key) ? "done" : "pend"), text: name }))));
        }
      }
      node.append(list);
    }

    // foot: kept / caught, why, agent activity, steering
    const foot = el("div", { class: "b-foot" });
    const meter = el("div", { class: "meter", "aria-hidden": "true" });
    if (f.produced) {
      const k = el("span", { class: "k" });
      k.style.width = (100 * f.accepted) / f.produced + "%";
      const d = el("span", { class: "d" });
      d.style.width = (100 * f.rejected) / f.produced + "%";
      meter.append(k, d);
    }
    const whyBtn = el("button", { class: "linkish", type: "button", "aria-expanded": String(card.why) }, document.createTextNode(card.why ? "Hide" : "Why?"), icon(card.why ? "down" : "right", "sm"));
    whyBtn.addEventListener("click", () => { card.why = !card.why; card.render(); });
    foot.append(el("div", { class: "meter-row" }, meter,
      el("span", { class: "grow" }, f.produced ? el("strong", { text: String(f.accepted) }) : null,
        document.createTextNode(f.produced ? " model answers kept · " : "No model answers yet"),
        f.produced ? el("span", { class: "muted", text: f.rejected + " caught by the harness's checks" }) : null),
      f.produced ? whyBtn : null));
    if (card.why) foot.append(whyPanel(card, f));
    if (card.run.mode === "agent") {
      const steps = agentEvents(card);
      if (steps.length) {
        const tog = el("button", { class: "linkish", type: "button", "aria-expanded": String(card.activity) }, icon(card.activity ? "down" : "right", "sm"),
          document.createTextNode("Agent activity (" + steps.length + " steps)"));
        tog.addEventListener("click", () => { card.activity = !card.activity; card.render(); });
        foot.append(el("div", {}, tog));
        if (card.activity) foot.append(agentSteps(steps));
      }
    }
    if (running && card.run.mode === "agent") foot.append(steerBox(card));
    if (running) {
      if (card.stopping) foot.append(el("div", { class: "help", text: "Stopping after the current task…" }));
      else {
        const stopBtn = button("Stop after this task", { class: "btn ghost sm" }, "pause");
        stopBtn.addEventListener("click", () => stopRun(card));
        foot.append(el("div", { class: "row" }, stopBtn, el("span", { class: "help", text: "Committed tasks are kept, and Resume continues later." })));
      }
    }
    node.append(foot);
    if (finished) node.append(summary(), nextRow() || el("span"), actions());
    if (card.error) node.append(el("div", { class: "b-actions error-text", text: card.error }));
    afterRender(card, keep, caret);
  }

  // Every render ends here, finished or not, so the model line, the Stop button and the note under the text box
  // never go on saying "building" after a run ends.
  function afterRender(card, keep, caret) {
    restore(keep, caret);
    if (app.chat && app.chat.messages.some((m) => m.role === "build" && m.runId === card.runId)) syncComposer();
    syncStatus();
  }

  // A failed build: the reason in full, the one-click fixes for its project, and the next step. A run that failed
  // before its tasks started (setup, a red baseline) is built again; one that failed later is resumed.
  function failRow(card) {
    const row = el("div", { class: "next bad fail" }, icon("x", "sm"),
      el("div", { class: "grow fail-text", text: card.run.error || "The run stopped on an error." }));
    const acts = el("div", { class: "row fail-actions" });
    if (!app.remote) {
      for (const fx of card.run.setupFixes || []) {
        const b = button(fx.label, { class: "btn sm primary", title: fx.command }, "check");
        b.addEventListener("click", () => runFix("/api/runs/" + card.runId + "/fix", { fix: fx.id }, () => card.resume()));
        acts.append(b);
      }
    }
    if (card.tasks.length) {
      const again = button("Resume", { class: "btn sm" }, "resume");
      again.addEventListener("click", () => resumeRun(card, again));
      acts.append(again);
    } else if (card.request && app.chat && !/scripted/.test(card.project || "")) {
      const again = button("Build again", { class: "btn sm" }, "play");
      again.addEventListener("click", () => buildAgain(card, again));
      acts.append(again);
      if (/requireGreenBaseline/.test(card.run.error || "") && !app.remote) {
        const anyway = button("Build anyway (Balanced)", { class: "btn sm", title: "Switch to Balanced, which builds on a red baseline and judges tasks only on new problems" }, "play");
        anyway.addEventListener("click", async () => {
          anyway.disabled = true;
          try { await post("/api/settings", { mode: "balanced" }); await buildAgain(card, anyway); } catch (e) { card.error = e.message; card.render(); }
        });
        acts.append(anyway);
      }
    }
    if (!app.remote) {
      const check = button("Check setup", { class: "btn sm ghost" }, "shield");
      check.addEventListener("click", () => openSettings("check"));
      acts.append(check);
    }
    row.append(acts);
    return row;
  }

  // The same request, in the same chat and project, as a new build.
  async function buildAgain(card, b) {
    if (b) b.disabled = true;
    try {
      await post("/api/chats/" + app.chat.id + "/send", { text: card.request, mode: "build", project: card.project });
      app.chat = await get("/api/chats/" + app.chat.id);
      renderTranscript();
      refreshChatsSoon();
    } catch (e) { card.error = e.message; card.render(); }
  }

  // One-click setup: the server first answers with the exact command; it runs only after "Run it".
  async function runFix(path, body, after) {
    let r;
    try { r = await postConfirmable(path, body); } catch (e) { openModal("Could not fix this", el("p", { class: "error-text", text: e.message }), [], true); return; }
    if (!r.confirm) { if (after) after(r.done); return; }
    const plan = r.confirm;
    const msg = el("div", { class: "validate" });
    const out = el("pre", { class: "fix-output" });
    const go = button("Run it", { class: "btn primary" }, "play");
    const cancel = button("Cancel");
    const m = openModal(plan.action, el("div", { class: "steps" },
      el("div", { class: "cmd" }, el("div", { class: "help", text: "In " + plan.target + " this runs:" }), el("div", { class: "mono", text: plan.command }),
        el("div", { class: "help", text: (/ (install|ci|add)\b/.test(plan.command) ? "It may download packages (install scripts stay off). " : "") + "Nothing runs until you choose Run it." })), msg, out), [cancel, go]);
    cancel.addEventListener("click", m.close);
    go.addEventListener("click", async () => {
      go.disabled = true;
      cancel.disabled = true;
      msg.className = "validate";
      msg.textContent = "Running… this can take a few minutes.";
      try {
        const res = await post(path, Object.assign({}, body, { confirm: true }));
        out.textContent = res.output || "";
        msg.className = "validate " + (res.ok ? "ok" : "bad");
        msg.textContent = res.ok ? "✓ Done." : "✕ It did not finish: the end of its output is below.";
        clear(m.foot);
        const close = button("Close", { class: "btn primary" });
        close.addEventListener("click", m.close);
        m.foot.append(close);
        if (after) after(res);
      } catch (e) { msg.className = "validate bad"; msg.textContent = e.message; go.disabled = false; cancel.disabled = false; }
    });
  }

  // Preview: the project's dev server on this computer. It keeps running after the dialog closes; Stop ends it.
  async function openPreview(body, label) {
    const status = el("div", { class: "validate", text: "Starting the dev server…" });
    const out = el("pre", { class: "fix-output" });
    const open = el("a", { class: "btn primary", target: "_blank", rel: "noopener noreferrer", hidden: true }, icon("play", "sm"), document.createTextNode("Open preview"));
    const stopB = button("Stop preview", {}, "stop");
    const close = button("Close");
    const m = openModal("Preview " + label, el("div", { class: "steps" },
      el("div", { class: "help", text: "The project's own dev server, on this computer only. It keeps running when you close this; Stop preview ends it." }), status, out), [stopB, close, open]);
    let key = null;
    const poll = async () => {
      if (!document.contains(status)) return;
      try {
        const p = (await get("/api/previews")).find((x) => x.key === key);
        if (!p) { status.textContent = "Stopped."; return; }
        out.textContent = p.output || "";
        if (p.ready) { status.className = "validate ok"; status.textContent = "✓ Running at " + p.url; open.href = p.url; open.hidden = false; }
        else if (!p.alive) { status.className = "validate bad"; status.textContent = "✕ The dev server stopped: the end of its output is below."; return; }
      } catch (e) { /* the next poll tries again */ }
      setTimeout(poll, 1000);
    };
    close.addEventListener("click", m.close);
    stopB.addEventListener("click", async () => { if (key) await post("/api/previews/stop", { key }).catch(() => {}); m.close(); });
    try { key = (await post("/api/previews/start", body)).key; poll(); }
    catch (e) { status.className = "validate bad"; status.textContent = e.message; }
  }

  function restore(keep, caret) {
    if (!keep || !document.contains(keep)) return;
    keep.focus();
    if (caret) keep.setSelectionRange(caret[0], caret[1]);
  }

  function whyPanel(card, f) {
    const box = el("div", { class: "why" });
    for (const r of f.reasons) {
      const open = card.whyCode === r.code;
      const row = el("button", { class: "reason", type: "button", "aria-expanded": String(open) },
        el("span", { class: "n", text: String(r.items.length) }), el("span", { text: r.text }), el("span", { class: "st", text: stageWords(r.stage) }));
      row.addEventListener("click", () => { card.whyCode = open ? null : r.code; card.render(); });
      box.append(row);
      if (open) {
        const items = el("div", { class: "items" });
        for (const e of r.items.slice(-20)) {
          items.append(el("div", { class: "item", text: (e.subject || "") + (e.task ? " · " + e.task : "") + (e.attempt ? " · attempt " + e.attempt : "") + (e.detail ? "\n" + e.detail : "") }));
        }
        if (r.items.length > 20) items.append(el("div", { class: "help", text: "… " + (r.items.length - 20) + " earlier ones in runs/" + card.runId + "/events.jsonl" }));
        box.append(items);
      }
    }
    box.append(el("div", { class: "note", text: f.reasons.length
      ? "Catching bad output is the harness doing its job: none of these reached your code."
      : "Nothing caught yet." }));
    return box;
  }

  // Agent mode: what the agents did, per task (and the investigation before planning), newest last. Tool output is
  // shown as text only.
  const AGENT_TOOL = /^(read_file|list_dir|search|find_symbol|edit_file|write_file|append_file|view_diff|run_gate|run_command|ask_user|finish)\b|^note from the user|^agent question/;
  function agentEvents(card) {
    return card.events.filter((e) => {
      const subject = e.subject || "";
      return AGENT_TOOL.test(subject) || (e.stage === "map" && subject && subject !== "investigation");
    });
  }

  function agentSteps(events) {
    const box = el("div", { class: "activity" });
    const groups = new Map();
    for (const e of events) {
      const key = e.task || "investigation";
      if (!groups.has(key)) groups.set(key, []);
      groups.get(key).push(e);
    }
    for (const [key, items] of groups) {
      box.append(el("div", { class: "head", text: key === "investigation" ? "Reading the project" : "Task " + key + " · " + items.length + " steps" }));
      for (const e of items.slice(-12)) {
        const bad = e.kind === "rejected";
        const ask = e.kind === "question";
        const text = bad ? (e.subject || "") + ": " + (e.detail || e.reasonText || "") : (e.subject || "") + (e.detail && /note|question/.test(e.subject || "") ? ": " + e.detail : "");
        box.append(el("div", { class: "act" }, el("span", { class: bad ? "no" : ask ? "q" : "ok", text: bad ? "✕" : ask ? "?" : "✓" }), el("span", { text })));
      }
      if (items.length > 12) box.append(el("div", { class: "help", text: "… " + (items.length - 12) + " earlier steps" }));
    }
    return box;
  }

  // Agent mode: a note to the running agent, or the answer to its question.
  function steerBox(card) {
    const q = card.run.agentQuestion;
    const input = card.noteInput;
    input.placeholder = q ? "Your answer" : "Send the agent a note, e.g. reuse the existing Button component";
    const send = button(q ? "Answer" : "Send note", { class: "btn sm" + (q ? " primary" : "") }, q ? "check" : "note");
    const msg = el("span", { class: "help", text: card.noteMsg || "" });
    const go = async () => {
      if (!input.value.trim()) return;
      send.disabled = true;
      try {
        await post("/api/runs/" + card.runId + "/note", { text: input.value });
        input.value = "";
        card.noteMsg = q ? "Answer sent." : "Note sent: the agent reads it before its next step.";
      } catch (e) { card.noteMsg = e.message; }
      card.render();
    };
    send.addEventListener("click", go);
    input.onkeydown = (ev) => { if (ev.key === "Enter") { ev.preventDefault(); go(); } };
    const box = el("div", { class: "steer" });
    if (q) box.append(el("div", { class: "agent-q grow" }, el("strong", { text: "The agent asks (" + q.task + "):" }), el("span", { text: q.text })));
    box.append(icon("note", "sm"), input, send, msg);
    return box;
  }

  // Blocking questions from the planner: one field per question, answered here.
  function askBox(card, questions) {
    const key = questions.join("\n");
    if (card.answersKey !== key) {
      card.answersKey = key;
      card.answers = questions.map((q, i) => el("input", { class: "input", type: "text", "data-keep": "1", "aria-label": "Answer " + (i + 1) }));
    }
    const box = el("div", { class: "askbox" },
      el("div", { class: "h" }, icon("q"), el("span", { text: "The planner has " + (questions.length === 1 ? "a question" : questions.length + " questions") + " before it can plan the tasks" })));
    questions.forEach((q, i) => box.append(el("label", { class: "q" }, el("span", { text: (i + 1) + ". " + q }), card.answers[i])));
    const go = button("Answer and continue", { class: "btn primary" });
    const msg = el("span", { class: "help", text: card.answerMsg || "The build is paused until you answer. Nothing has changed in your project yet." });
    go.addEventListener("click", async () => {
      const answers = card.answers.map((a) => a.value.trim());
      if (answers.some((a) => !a)) { card.answerMsg = "Answer every question (a short answer is fine)."; card.render(); return; }
      go.disabled = true;
      try {
        await post("/api/runs/" + card.runId + "/answer", { answers });
        card.answerMsg = null;
        card.answersKey = "";
        card.run = Object.assign({}, card.run, { status: "planning", questions: [] });
        card.resume();
        refreshChatsSoon();
      } catch (e) { card.answerMsg = e.message; }
      card.render();
    });
    box.append(el("div", { class: "row" }, go, msg));
    return box;
  }

  async function resumeRun(card, b) {
    b.disabled = true;
    try {
      await post("/api/runs/" + card.runId + "/resume", {});
      card.open = false;
      card.error = null;
      card.run = Object.assign({}, card.run, { status: "running", error: null });
      card.resume();
      refreshChatsSoon();
    } catch (e) { card.error = e.message; }
    card.render();
  }

  // ---------------------------------------------------------------- report drawer

  async function openReport(card) {
    const d = $("drawer");
    clear(d);
    const body = el("div", { class: "db msg", text: "Loading the report…" });
    const copy = button("Copy as Markdown", { class: "btn ghost sm" }, "copy");
    const close = el("button", { class: "btn ghost icon-only", type: "button", "aria-label": "Close the report" }, icon("x"));
    close.addEventListener("click", closeDrawer);
    d.append(el("div", { class: "dh" }, icon("doc"), el("span", { class: "grow", text: "Report" }), copy, close), body);
    d.hidden = false;
    try {
      const res = await fetch("/api/runs/" + card.runId + "/report");
      const text = await res.text();
      if (!res.ok) throw new Error("no report yet");
      clear(body);
      body.append(markdown(text));
      copy.addEventListener("click", () => copyText(text, copy));
    } catch (e) {
      body.textContent = e.message;
    }
    close.focus();
  }

  function closeDrawer() {
    $("drawer").hidden = true;
  }

  // ---------------------------------------------------------------- modals

  function openModal(title, content, actions, small) {
    const root = $("modal-root");
    const prev = document.activeElement;
    const x = el("button", { class: "btn ghost icon-only", type: "button", "aria-label": "Close" }, icon("x"));
    const box = el("div", { class: "card modal" + (small ? " small" : ""), role: "dialog", "aria-modal": "true", "aria-label": title },
      el("div", { class: "mh" }, el("h3", { text: title }), x), el("div", { class: "mb" }, content));
    const foot = el("div", { class: "mf" }, ...actions);
    box.append(foot);
    const scrim = el("div", { class: "scrim" }, box);
    const close = () => { scrim.remove(); document.removeEventListener("keydown", onKey); if (prev && prev.focus) prev.focus(); };
    const onKey = (ev) => { if (ev.key === "Escape") close(); };
    x.addEventListener("click", close);
    scrim.addEventListener("mousedown", (ev) => { if (ev.target === scrim) close(); });
    document.addEventListener("keydown", onKey);
    root.append(scrim);
    const first = box.querySelector("input, textarea, select") || foot.lastChild;
    if (first) first.focus();
    return { close, box, foot };
  }

  function confirmModal(title, text, ok, danger) {
    return new Promise((resolve) => {
      const yes = button(ok, { class: "btn " + (danger ? "danger" : "primary") });
      const no = button("Cancel");
      const m = openModal(title, el("p", { class: "muted", text }), [no, yes], true);
      no.addEventListener("click", () => { m.close(); resolve(false); });
      yes.addEventListener("click", () => { m.close(); resolve(true); });
    });
  }

  function promptModal(title, label, value) {
    return new Promise((resolve) => {
      const input = el("input", { class: "input", type: "text", value: value || "", "aria-label": label });
      const yes = button("Save", { class: "btn primary" });
      const no = button("Cancel");
      const m = openModal(title, el("label", { class: "q" }, el("span", { class: "help", text: label }), input), [no, yes], true);
      input.select();
      const done = () => { m.close(); resolve(input.value.trim() || null); };
      input.addEventListener("keydown", (ev) => { if (ev.key === "Enter") done(); });
      no.addEventListener("click", () => { m.close(); resolve(null); });
      yes.addEventListener("click", done);
    });
  }

  // Add a project: link a folder, clone, or create an Astro site. Clone and create first show the exact command the
  // server would run; it runs only after "Clone project" / "Create project".
  function addProjectModal(kind) {
    const optsBox = el("div", { class: "opts", role: "radiogroup", "aria-label": "How to add it" });
    const form = el("div", { class: "field-row" });
    const extra = el("div");
    const msg = el("div", { class: "validate" });
    const go = button("", { class: "btn primary" });
    const cancel = button("Cancel");
    const m = openModal("Add a project", el("div", { class: "steps" }, optsBox, form, extra, msg), [cancel, go]);
    cancel.addEventListener("click", m.close);
    const OPTS = [["link", "folder", "Link a folder", "A git repository already on this computer."],
      ["clone", "download", "Clone from Git", "Copy a repository from a URL into projects/."],
      ["create", "spark", "New Astro site", "Start fresh with the official template, in projects/."]];
    let plan = null;
    let timer = null;
    const show = (k) => {
      kind = k;
      plan = null;
      clear(optsBox); clear(form); clear(extra);
      msg.textContent = "";
      msg.className = "validate";
      for (const [id, ic, h, d] of OPTS) {
        const b = el("button", { class: "opt" + (id === k ? " on" : ""), type: "button", role: "radio", "aria-checked": String(id === k) },
          el("span", { class: "oi" }, icon(ic)), el("span", { class: "h", text: h }), el("span", { class: "d", text: d }));
        b.addEventListener("click", () => show(id));
        optsBox.append(b);
      }
      clear(go);
      if (k === "link") {
        const path = el("input", { class: "input mono", type: "text", placeholder: "paste the folder's full path", spellcheck: "false", "aria-label": "Folder path" });
        form.append(path);
        go.append(icon("link", "sm"), document.createTextNode("Link folder"));
        path.addEventListener("input", () => {
          clearTimeout(timer);
          timer = setTimeout(async () => {
            if (!path.value.trim()) { msg.textContent = ""; return; }
            try {
              const s = await post("/api/projects/validate", { path: path.value.trim() });
              msg.className = "validate " + (s.error ? "bad" : "ok");
              msg.textContent = s.error ? "✕ " + s.error : "✓ " + projectLine(s);
            } catch (e) { msg.className = "validate bad"; msg.textContent = e.message; }
          }, 300);
        });
        go.onclick = async () => {
          try { const p = await post("/api/projects/link", { path: path.value.trim() }); await chooseProject(p.name); m.close(); }
          catch (e) { msg.className = "validate bad"; msg.textContent = e.message; }
        };
        path.focus();
      } else {
        const url = k === "clone" ? el("input", { class: "input mono", type: "text", placeholder: "https://github.com/owner/repo.git", spellcheck: "false", "aria-label": "Git URL" }) : null;
        const name = el("input", { class: "input", type: "text", placeholder: k === "clone" ? "name (optional)" : "project name, e.g. my-site", spellcheck: "false", "aria-label": "Project name" });
        if (url) form.append(url);
        form.append(name);
        go.append(icon(k === "clone" ? "download" : "spark", "sm"), document.createTextNode("Continue"));
        const reset = () => { if (plan) { plan = null; clear(extra); clear(go); go.append(icon(k === "clone" ? "download" : "spark", "sm"), document.createTextNode("Continue")); } };
        (url || name).addEventListener("input", reset);
        name.addEventListener("input", reset);
        go.onclick = async () => {
          const body = k === "clone" ? { url: url.value.trim(), name: name.value.trim() } : { name: name.value.trim() };
          const path = "/api/projects/" + k;
          try {
            if (!plan) {
              const r = await postConfirmable(path, body);
              if (r.done) { await chooseProject(r.done.name); m.close(); return; }
              plan = r.confirm;
              clear(extra);
              extra.append(el("div", { class: "cmd" }, el("div", { class: "help", text: "Before anything runs, this is exactly what will happen:" }),
                el("div", { class: "mono", text: plan.command }), el("div", { class: "help", text: "Into " + plan.target + ". It downloads code from the internet" + (k === "clone" ? "; install the project's dependencies (npm install) yourself before the first build." : " and installs the template's dependencies.") })));
              clear(go);
              go.append(icon(k === "clone" ? "download" : "spark", "sm"), document.createTextNode(k === "clone" ? "Clone project" : "Create project"));
              return;
            }
            go.disabled = true;
            msg.className = "validate";
            msg.textContent = "Working… this can take a few minutes.";
            const p = await post(path, Object.assign({}, body, { confirm: true }));
            await chooseProject(p.name);
            m.close();
          } catch (e) { msg.className = "validate bad"; msg.textContent = e.message; go.disabled = false; }
        };
        (url || name).focus();
      }
    };
    show(kind || "link");
  }

  // ---------------------------------------------------------------- projects (Build mode)

  function projectLine(s) {
    const parts = [s.display, "branch " + s.branch, s.clean ? "clean" : "uncommitted changes"];
    parts.push(s.stack ? s.stack + (s.version ? " " + s.version : "") : "no known stack");
    return parts.join(" · ");
  }

  async function loadProjects() {
    try { app.projects = (app.state && app.state.configured) ? await get("/api/projects") : []; } catch (e) { app.projects = []; }
    const pick = $("project-picker");
    const want = pick.value || (function () { try { return localStorage.getItem("harness.project") || ""; } catch (e) { return ""; } })();
    clear(pick);
    if (!app.projects.length) pick.append(el("option", { value: "", text: "no projects yet" }));
    for (const p of app.projects) {
      const o = el("option", { value: p.name, text: p.name, title: p.error ? p.error : projectLine(p) });
      if (p.name === want) o.selected = true;
      pick.append(o);
    }
    syncComposer();
  }

  async function chooseProject(name) {
    try { localStorage.setItem("harness.project", name); } catch (e) { /* storage may be off */ }
    $("project-picker").value = "";
    await loadProjects();
    $("project-picker").value = name;
    if (app.mode !== "build") setMode("build");
    syncComposer();
    if (app.view === "home") renderHome();
  }

  // ---------------------------------------------------------------- LAN mode (the computer's banner)

  async function syncLan() {
    if (app.remote) return;
    let s;
    try { s = await get("/api/lan"); } catch (e) { return; }
    const b = $("lan-banner");
    clear(b);
    b.hidden = !s.on;
    if (!s.on) return;
    const left = s.locked ? "locked after wrong codes: make a new one" : s.codeSecondsLeft > 0 ? Math.ceil(s.codeSecondsLeft / 60) + " min left" : "expired: make a new one";
    const newCode = button("New code", { class: "btn sm" });
    newCode.addEventListener("click", async () => { await post("/api/lan/code", {}).catch(() => {}); syncLan(); });
    const stopIt = button("Stop sharing", { class: "btn sm danger" }, "stop");
    stopIt.addEventListener("click", async () => { await post("/api/lan/stop", {}).catch(() => {}); syncLan(); });
    b.append(icon("link", "sm"), el("strong", { text: "LAN mode is on." }), el("span", { text: "On a phone on this network open" }),
      el("span", { class: "mono", text: s.url }), el("span", { text: "and type" }), el("span", { class: "code", text: s.locked ? "——————" : s.code }),
      el("span", { class: "faint", text: "(" + left + ") · " + s.devices + " paired · trusted networks only" }), el("span", { class: "grow" }), newCode, stopIt);
  }

  // ---------------------------------------------------------------- settings

  function openSettings(tab) {
    if (tab) app.settingsTab = tab;
    showView("settings");
  }

  const TABS = [["models", "server", "Models"], ["runs", "sliders", "How runs work"], ["check", "shield", "Check setup"],
    ["appearance", "palette", "Appearance"], ["demo", "play", "Demo"]];

  function renderSettings() {
    const s = $("settings");
    clear(s);
    if (app.remote) {
      s.append(el("div", { class: "settings" }, el("div", { class: "card prov" }, el("div", { class: "head" }, el("div", { class: "b-icon" }, icon("sliders")),
        el("div", { class: "grow" }, el("div", { class: "name", text: "Settings live on the computer" }),
          el("div", { class: "url", text: "Models, projects, how runs work and the look are changed on the computer running the harness. From here you can chat, build, answer, steer, stop and resume." }))))));
      return;
    }
    const page = el("div", { class: "settings" });
    const tabs = el("div", { class: "tabs", role: "tablist" });
    for (const [id, ic, label] of TABS) {
      const b = el("button", { class: "tab" + (app.settingsTab === id ? " on" : ""), type: "button", role: "tab", "aria-selected": String(app.settingsTab === id) }, icon(ic, "sm"), document.createTextNode(label));
      b.addEventListener("click", () => { discardPreview(); app.settingsTab = id; renderSettings(); });
      tabs.append(b);
    }
    const body = el("div", { class: "steps" });
    page.append(tabs, body);
    s.append(page);
    const render = { models: modelsTab, runs: runsTab, check: checkTab, appearance: appearanceTab, demo: demoTab }[app.settingsTab] || modelsTab;
    render(body);
  }

  function output(card, text) {
    let pre = card.querySelector("pre");
    if (!pre) { pre = el("pre"); card.append(pre); }
    pre.textContent = text;
  }

  function providerState(p) {
    if (p.up && p.models.length) return { text: "Running · " + p.models.length + " model" + (p.models.length === 1 ? "" : "s"), cls: "ok" };
    if (p.up) return { text: p.error || "Running, no model", cls: "plain" };
    if (p.cli) return { text: "Server stopped", cls: "plain" };
    return { text: "Not installed", cls: "plain" };
  }

  async function modelsTab(body) {
    body.append(el("div", { class: "help", text: "Looking for model servers on this computer…" }));
    let found = [], s = { configured: false };
    try { [found, s] = await Promise.all([get("/api/providers"), get("/api/settings")]); }
    catch (e) { clear(body); body.append(el("div", { class: "error-text", text: e.message })); return; }
    clear(body);
    body.append(el("div", { class: "sec-title", text: "In use" }));
    if (s.configured) {
      const first = s.profiles.find((p) => p.profile === s.first) || s.profiles[0];
      const card = el("div", { class: "card prov" }, el("div", { class: "head" }, el("div", { class: "b-icon ok" }, icon("check")),
        el("div", { class: "grow" }, el("div", { class: "name", text: first ? first.model : "model" }),
          el("div", { class: "url", text: (first ? first.profile + " · " + first.baseUrl : "") + (s.second ? " · writes the code" : " · used for every step") })),
        el("span", { class: "badge ok", text: "Set up" })));
      if (app.probed) {
        // "16K context, JSON mode: yes, tools: no, thinking can be turned off" as chips
        card.append(el("div", { class: "help", text: (app.probed.second ? "Planning and review now use " : "Checked ") + app.probed.model + ":" }),
          el("div", { class: "row" }, ...app.probed.summary.split(", ").map((part) => el("span", { class: "cap" + (/: no|cannot/.test(part) ? "" : " ok"), text: part }))));
      }
      const pick = el("select", { class: "select", "aria-label": "Model for planning and review" });
      pick.append(el("option", { value: "", text: "the same model" }));
      for (const p of s.profiles) if (p.profile !== s.first) pick.append(el("option", { value: p.profile, text: p.profile + " · " + p.model }));
      pick.value = s.second || "";
      pick.addEventListener("change", () => saveSettings(card, { second: pick.value || null }));
      card.append(el("div", { class: "field-row" }, el("span", { class: "muted", text: "Planning and review use" }), pick,
        el("span", { class: "help", text: "A bigger model often plans and reviews better. Add one with Plan & review below." })));
      body.append(card);
    } else {
      body.append(el("div", { class: "card prov" }, el("div", { class: "head" }, el("div", { class: "b-icon" }, icon("server")),
        el("div", { class: "grow" }, el("div", { class: "name", text: "No model set up yet" }), el("div", { class: "url", text: "Choose Use on a model below. The harness checks what it can do and tells you in plain words." })))));
    }
    body.append(el("div", { class: "sec-title", text: "Found on this computer" }));
    for (const p of found) body.append(providerCard(p, s.configured));
    if (!found.some((p) => p.up || p.cli)) {
      body.append(el("div", { class: "card prov" }, el("div", { class: "name", text: "Nothing found on this computer" }),
        el("div", { class: "help", text: "Install one of these, start it, then come back: it shows up here by itself." }),
        el("div", { class: "row" }, el("a", { href: "https://lmstudio.ai/", target: "_blank", rel: "noopener noreferrer", text: "LM Studio (lmstudio.ai)" }),
          el("a", { href: "https://ollama.com/download", target: "_blank", rel: "noopener noreferrer", text: "Ollama (ollama.com)" }))));
    }
    body.append(customCard(s.configured));
  }

  function modelButtons(kind, model, card, extra, configured) {
    const group = el("span", { class: "row" });
    const use = button("Use", { class: "btn sm primary", title: "Use " + model + " for everything" });
    use.addEventListener("click", () => useModel(kind, model, card, extra, false, use));
    group.append(use);
    if (configured) {
      const second = button("Plan & review", { class: "btn sm ghost", title: "Use " + model + " for the planner and reviewers" });
      second.addEventListener("click", () => useModel(kind, model, card, extra, true, second));
      group.append(second);
    }
    return group;
  }

  async function useModel(kind, model, card, extra, second, b) {
    b.disabled = true;
    output(card, "Checking what " + model + " can do…");
    try {
      const r = await post("/api/providers/use", Object.assign({ kind, model }, extra || {}, second ? { as: "second" } : {}));
      app.probed = { model: r.model, second: r.second, summary: r.summary };
      await loadState();
      await loadProjects();
      if (app.view === "settings") renderSettings();
    } catch (e) { output(card, e.message); }
    b.disabled = false;
  }

  function actionButton(p, action, label, card, model, after) {
    const b = button(label, { class: "btn sm" });
    b.addEventListener("click", async () => {
      b.disabled = true;
      output(card, label + "…");
      try {
        const r = await post("/api/providers/action", { kind: p.kind, action, model });
        output(card, (r.ok ? "Done" : "Failed") + "\n" + r.output);
        if (after) after(r);
      } catch (e) { output(card, e.message); }
      b.disabled = false;
    });
    return b;
  }

  function providerCard(p, configured) {
    const st = providerState(p);
    const card = el("div", { class: "card prov" }, el("div", { class: "head" }, el("div", { class: "b-icon" }, icon("server")),
      el("div", { class: "grow" }, el("div", { class: "name", text: p.label }), el("div", { class: "url", text: p.baseUrl })),
      el("span", { class: "badge " + st.cls, text: st.text })));
    for (const m of p.models) card.append(el("div", { class: "model-row" }, el("span", { class: "grow" }, el("strong", { text: m })), modelButtons(p.kind, m, card, null, configured)));
    if (p.kind === "lmstudio" && p.cli) {
      const tools = el("div", { class: "row" });
      if (!p.up) tools.append(actionButton(p, "server_start", "Start LM Studio's server", card, null, () => renderSettings()));
      tools.append(actionButton(p, "ls", "Show downloaded models", card, null, (r) => {
        const loads = el("div", { class: "row" });
        for (const key of r.models || []) loads.append(actionButton(p, "load", "Load " + key, card, key, () => renderSettings()));
        card.append(loads);
      }));
      card.append(tools);
    }
    if (p.kind === "ollama" && p.cli) {
      const name = el("input", { class: "input", type: "text", placeholder: "model to pull, e.g. name:tag", spellcheck: "false", "aria-label": "Model to pull" });
      const pull = button("Pull", { class: "btn sm" }, "download");
      pull.addEventListener("click", async () => {
        pull.disabled = true;
        output(card, "Pulling " + name.value + "… this can take a while.");
        try {
          const r = await post("/api/providers/action", { kind: "ollama", action: "pull", model: name.value.trim() });
          output(card, (r.ok ? "Done" : "Failed") + "\n" + r.output);
          renderSettings();
        } catch (e) { output(card, e.message); }
        pull.disabled = false;
      });
      card.append(el("div", { class: "field-row" }, name, pull));
    }
    if (!p.up && !p.cli) card.append(el("div", { class: "help", text: "Install it, start it, then come back: it shows up here by itself." }));
    return card;
  }

  function customCard(configured) {
    const card = el("div", { class: "card prov" }, el("div", { class: "head" }, el("div", { class: "b-icon" }, icon("link")),
      el("div", { class: "grow" }, el("div", { class: "name", text: "Another server" }), el("div", { class: "url", text: "Any OpenAI-compatible server, on this computer or hosted" }))));
    const url = el("input", { class: "input mono", type: "text", placeholder: "http://127.0.0.1:8080/v1", spellcheck: "false", "aria-label": "Server URL" });
    const key = el("input", { class: "input", type: "text", placeholder: "Key: name of an env var (optional)", spellcheck: "false", "aria-label": "Name of the environment variable with the key" });
    const probe = button("Find models", { class: "btn sm" });
    const models = el("div", { class: "steps" });
    probe.addEventListener("click", async () => {
      clear(models);
      output(card, "Asking the server for its models…");
      try {
        const p = await post("/api/providers/custom", { baseUrl: url.value.trim(), keyEnv: key.value.trim() });
        output(card, p.up ? p.models.length + " model(s) found" : p.error);
        for (const m of p.models) models.append(el("div", { class: "model-row" }, el("span", { class: "grow" }, el("strong", { text: m })),
          modelButtons("custom", m, card, { baseUrl: url.value.trim(), keyEnv: key.value.trim() }, configured)));
      } catch (e) { output(card, e.message); }
    });
    card.append(el("div", { class: "field-row" }, url, key, probe), models,
      el("div", { class: "help", text: "Never paste a key here, only the name of the environment variable that holds it." }));
    return card;
  }

  async function runsTab(body) {
    let s;
    try { s = await get("/api/settings"); } catch (e) { body.append(el("div", { class: "error-text", text: e.message })); return; }
    if (!s.configured) { body.append(el("div", { class: "help", text: "Set up a model first (Models)." })); return; }
    const holder = el("div", { class: "steps" });
    body.append(el("div", { class: "sec-title", text: "How careful" }));
    const modes = el("div", { class: "radio-cards", role: "radiogroup", "aria-label": "How careful" });
    for (const m of s.modes) {
      const on = s.mode === m.id;
      const card = el("button", { class: "rc" + (on ? " on" : ""), type: "button", role: "radio", "aria-checked": String(on) },
        el("span", { class: "h" }, el("span", { class: "radio" }), document.createTextNode(m.label), m.id === "balanced" ? el("span", { class: "badge run", text: "Recommended" }) : null),
        el("span", { class: "d", text: m.text.charAt(0).toUpperCase() + m.text.slice(1) + "." }));
      card.addEventListener("click", () => saveSettings(holder, { mode: m.id }));
      modes.append(card);
    }
    body.append(modes);
    if (!s.modes.some((m) => m.id === s.mode)) body.append(el("div", { class: "help", text: "Custom settings (review " + s.review + "): choosing one of these replaces them." }));
    body.append(el("div", { class: "sec-title", text: "Way of working" }));
    const ways = el("div", { class: "radio-cards", role: "radiogroup", "aria-label": "Way of working" });
    for (const [id, name, text] of [["pipeline", "Pipeline", "One structured answer per step. Fast, and the safest choice for small models."],
      ["agent", "Agent", "An agent reads, edits and runs the checks itself; the harness checks its work. Slower, more thorough, and you can send it notes."]]) {
      const on = s.runMode === id;
      const card = el("button", { class: "rc" + (on ? " on" : ""), type: "button", role: "radio", "aria-checked": String(on) },
        el("span", { class: "h" }, el("span", { class: "radio" }), document.createTextNode(name)), el("span", { class: "d", text }));
      card.addEventListener("click", () => saveSettings(holder, { runMode: id }));
      ways.append(card);
    }
    body.append(ways, holder);
  }

  async function saveSettings(box, change) {
    try {
      await post("/api/settings", change);
      await loadState();
      renderSettings();
    } catch (e) { output(box, e.message); }
  }

  function checkTab(body) {
    const card = el("div", { class: "card prov" });
    const list = el("div");
    const run = button("Check setup", { class: "btn primary sm" }, "shield");
    const go = async () => {
      run.disabled = true;
      clear(list);
      list.append(el("div", { class: "help", text: "Checking…" }));
      try {
        const p = $("project-picker").value || "";
        const r = await get("/api/doctor" + (p ? "?project=" + encodeURIComponent(p) : ""));
        clear(list);
        for (const c of r.checks) {
          list.append(el("div", { class: "check-row" }, el("span", { class: c.ok ? "ok" : "no", text: c.ok ? "✓" : "✕" }),
            el("span", {}, el("strong", { text: c.area + " " }), document.createTextNode(c.detail)), !c.ok && c.fix ? el("span", { class: "fix", text: "→ " + c.fix }) : null));
        }
        const problems = r.checks.filter((c) => !c.ok).length;
        list.append(el("div", { class: "help", text: r.ready
          ? "Ready" + (r.project ? " to build in " + r.project : "; pick a project in Build to check it too") + "."
          : "Not ready: " + problems + " problem" + (problems === 1 ? "" : "s") + " to fix." }));
      } catch (e) { clear(list); list.append(el("div", { class: "error-text", text: e.message })); }
      run.disabled = false;
    };
    run.addEventListener("click", go);
    card.append(el("div", { class: "head" }, el("div", { class: "b-icon" }, icon("shield")), el("div", { class: "grow" },
      el("div", { class: "name", text: "Every reason a build would not start" }),
      el("div", { class: "url", text: "Ruby, git, the config, each model server and, for the project picked in Build, the repository, its dependencies and its checks. Nothing is changed and no model writes anything." })), run), list);
    body.append(card);
    go();
  }

  function demoTab(body) {
    const go = button("Try the demo", { class: "btn primary sm" }, "play");
    go.addEventListener("click", () => runDemo(go));
    body.append(el("div", { class: "card prov" }, el("div", { class: "head" }, el("div", { class: "b-icon" }, icon("play")),
      el("div", { class: "grow" }, el("div", { class: "name", text: "Watch a whole build in 20 seconds" }),
        el("div", { class: "url", text: "A scripted model plans two tasks on a tiny sample project, its first edit fails the project's check, the fix passes, and the review runs. No model, nothing installed; it lives in demo/ next to the config." })), go)));
  }

  // Try the demo: a whole build of a bundled project by a scripted model, shown in a chat like any build.
  async function runDemo(b) {
    if (b) b.disabled = true;
    try {
      app.chat = null;
      const chat = await ensureChat();
      await post("/api/demo", { chat: chat.id });
      app.chat = await get("/api/chats/" + chat.id);
      showView("chat");
      renderTranscript();
      await refreshChats();
    } catch (e) { if (b) { b.disabled = false; b.parentNode.append(el("div", { class: "error-text", text: e.message })); } }
  }

  // ---------------------------------------------------------------- appearance (colours only)

  const COLORS = [["bg", "Background"], ["surface", "Cards"], ["text", "Text"], ["accent", "Accent"], ["success", "Done"], ["warn", "Needs you"], ["danger", "Problem"]];
  const PRESETS = {
    dark: [
      ["Dusk", { bg: "#16151c", surface: "#1d1c25", text: "#e8e6f0", accent: "#9a8cf2", success: "#86c9a8", warn: "#e3bb73", danger: "#e5939b" }],
      ["Midnight", { bg: "#121620", surface: "#182030", text: "#e4e9f2", accent: "#7fb0f0", success: "#7cc9b0", warn: "#e0b870", danger: "#e98f9a" }],
      ["Forest", { bg: "#131a17", surface: "#19221e", text: "#e3ebe6", accent: "#79c2b0", success: "#9bd1a0", warn: "#dcc07a", danger: "#e3968f" }],
      ["Ember", { bg: "#1b1614", surface: "#231d1a", text: "#efe7e2", accent: "#e8a27c", success: "#9cc9a0", warn: "#e6c06e", danger: "#ea8f8f" }],
    ],
    light: [
      ["Daylight", { bg: "#f6f5fa", surface: "#ffffff", text: "#25222e", accent: "#6553d6", success: "#286f50", warn: "#8c5a0c", danger: "#b84050" }],
      ["Paper", { bg: "#f7f3ec", surface: "#fffdf8", text: "#2b2620", accent: "#8a5a2b", success: "#3d6b3f", warn: "#86560c", danger: "#a8423a" }],
      ["Mist", { bg: "#f2f6f8", surface: "#ffffff", text: "#1f2a30", accent: "#2f6f9f", success: "#2a6e55", warn: "#86600f", danger: "#b0443f" }],
    ],
  };

  // The look on screen: dark or light.
  function shownLook() {
    const mode = document.documentElement.dataset.mode;
    if (mode === "dark" || mode === "light") return mode;
    return window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark";
  }

  function luminance(hex) {
    const c = [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16) / 255).map((v) => (v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4)));
    return 0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2];
  }
  function contrast(a, b) {
    const x = luminance(a), y = luminance(b);
    return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
  }
  function onAccent(hex) {
    return contrast(hex, "#16151c") >= contrast(hex, "#ffffff") ? "#16151c" : "#ffffff";
  }

  // Live preview: the colours being edited go on <html> through the CSSOM (allowed by the CSP); saving or leaving
  // the tab removes them again, and /theme.css carries what was saved.
  function previewColors(colors) {
    const root = document.documentElement;
    for (const [k] of COLORS) root.style.setProperty("--" + k, colors[k]);
    root.style.setProperty("--on-accent", onAccent(colors.accent));
    app.preview = true;
  }
  function discardPreview() {
    if (!app.preview) return;
    const root = document.documentElement;
    for (const [k] of COLORS) root.style.removeProperty("--" + k);
    root.style.removeProperty("--on-accent");
    app.preview = null;
  }
  function reloadTheme() {
    return new Promise((resolve) => {
      const link = $("theme-css");
      const next = el("link", { rel: "stylesheet", href: "/theme.css?v=" + Date.now(), id: "theme-css" });
      next.addEventListener("load", () => resolve());
      next.addEventListener("error", () => resolve());
      link.replaceWith(next);
    });
  }

  async function saveAppearance(look) {
    app.appearance = await post("/api/appearance", look);
    document.documentElement.dataset.mode = app.appearance.mode;
    await reloadTheme();
    discardPreview();
  }

  function appearanceTab(body) {
    const look = shownLook();
    const saved = app.appearance;
    const defaults = PRESETS[look][0][1];
    const current = Object.assign({}, defaults, saved[look] || {});
    let working = Object.assign({}, current);

    body.append(el("div", { class: "sec-title", text: "Mode" }));
    const modes = el("div", { class: "radio-cards", role: "radiogroup", "aria-label": "Mode" });
    for (const [id, ic, name, text] of [["system", "monitor", "System", "Follows your computer's light or dark setting."],
      ["dark", "moon", "Dark", "Always the dark look."], ["light", "sun", "Light", "Always the light look."]]) {
      const on = saved.mode === id;
      const card = el("button", { class: "rc" + (on ? " on" : ""), type: "button", role: "radio", "aria-checked": String(on) },
        el("span", { class: "h" }, el("span", { class: "radio" }), icon(ic, "sm"), document.createTextNode(name)), el("span", { class: "d", text }));
      card.addEventListener("click", async () => {
        discardPreview();
        try { await saveAppearance(Object.assign({}, app.appearance, { mode: id })); } catch (e) { msg.textContent = e.message; }
        renderSettings();
      });
      modes.append(card);
    }
    body.append(modes);

    body.append(el("div", { class: "sec-title", text: "Colours of the " + look + " look" }));
    body.append(el("div", { class: "help", text: "You are editing the look on screen now. Switch the mode to " + (look === "dark" ? "Light" : "Dark") + " to change the other one. Only colours change; the font and the layout stay the same." }));
    const swatches = el("div", { class: "swatches", role: "radiogroup", "aria-label": "Presets" });
    const fields = el("div", { class: "color-grid" });
    const check = el("div", { class: "contrast" });
    const msg = el("span", { class: "help", text: "Changes are saved as you make them." });
    const same = (a, b) => COLORS.every(([k]) => a[k] === b[k]);
    const save = () => saveColors(look, working, defaults, msg);
    const paint = () => {
      previewColors(working);
      clear(swatches);
      for (const [name, colors] of PRESETS[look]) {
        const on = same(colors, working);
        const chips = el("span", { class: "chips" });
        for (const k of ["bg", "surface", "accent", "success", "warn", "danger"]) {
          const c = el("span");
          c.style.background = colors[k];
          chips.append(c);
        }
        const b = el("button", { class: "swatch" + (on ? " on" : ""), type: "button", role: "radio", "aria-checked": String(on) }, chips, el("span", { text: name + (name === PRESETS[look][0][0] ? " (default)" : "") }));
        b.addEventListener("click", () => { working = Object.assign({}, colors); paint(); save(); });
        swatches.append(b);
      }
      clear(fields);
      for (const [k, label] of COLORS) {
        const input = el("input", { type: "color", value: working[k], "aria-label": label });
        const hex = el("span", { class: "hex", text: working[k] });
        input.addEventListener("input", () => { working[k] = input.value.toLowerCase(); hex.textContent = working[k]; previewColors(working); syncCheck(); markSwatches(); });
        input.addEventListener("change", save);
        fields.append(el("label", { class: "color-field" }, input, el("span", { text: label }), hex));
      }
      syncCheck();
    };
    const markSwatches = () => {
      [...swatches.children].forEach((b, i) => { const on = same(PRESETS[look][i][1], working); b.classList.toggle("on", on); b.setAttribute("aria-checked", String(on)); });
    };
    const syncCheck = () => {
      const r = contrast(working.text, working.bg);
      const rs = contrast(working.text, working.surface);
      const low = Math.min(r, rs);
      clear(check);
      check.className = "contrast " + (low >= 4.5 ? "ok" : "bad");
      check.append(icon(low >= 4.5 ? "check" : "x", "sm"), document.createTextNode("Text contrast " + low.toFixed(1) + ":1 " +
        (low >= 7 ? "(very easy to read)" : low >= 4.5 ? "(easy to read)" : "(hard to read: aim for at least 4.5:1)")));
    };
    const resetBtn = button("Back to default", { class: "btn ghost sm" });
    resetBtn.addEventListener("click", () => { working = Object.assign({}, defaults); paint(); save(); });
    body.append(swatches, fields, check, el("div", { class: "row" }, resetBtn, msg));
    paint();
    discardPreview();
  }

  // Appearance saves as you go: a preset, a reset, or a colour picker once it is let go.
  async function saveColors(look, working, defaults, msg) {
    const same = Object.keys(defaults).every((k) => defaults[k] === working[k]);
    try {
      await saveAppearance(Object.assign({}, app.appearance, { [look]: same ? {} : Object.assign({}, working) }));
      msg.textContent = "Saved.";
    } catch (e) { msg.textContent = e.message; }
  }

  // ---------------------------------------------------------------- drafts, wiring

  const draftKey = () => "harness.draft." + (app.chat ? app.chat.id : "new");
  function saveDraft() {
    try { localStorage.setItem(draftKey(), $("input").value); } catch (e) { /* storage may be off */ }
  }
  function loadDraft() {
    try { return localStorage.getItem(draftKey()) || ""; } catch (e) { return ""; }
  }

  function wire() {
    hydrateIcons(document);
    $("new-chat").addEventListener("click", newChat);
    $("open-settings").addEventListener("click", () => (app.view === "settings" ? (app.chat ? showView("chat") : showView("home")) : openSettings()));
    $("model-status").addEventListener("click", () => openSettings("models"));
    $("send").addEventListener("click", send);
    $("stop").addEventListener("click", stop);
    $("input").addEventListener("keydown", (ev) => {
      if (ev.key === "Enter" && (ev.ctrlKey || ev.metaKey)) {
        ev.preventDefault();
        send();
      }
    });
    $("input").addEventListener("input", () => { saveDraft(); autosize(); });
    for (const b of document.querySelectorAll(".seg button")) b.addEventListener("click", () => setMode(b.dataset.mode));
    $("model-picker").addEventListener("change", async () => {
      const m = currentModel();
      renderPicker();
      syncStatus();
      if (!m || !app.chat) return;
      app.chat = await post("/api/chats/" + app.chat.id + "/model", { profile: m.profile, model: m.model });
      renderTranscript();
    });
    $("chat-menu").addEventListener("click", (ev) => {
      ev.stopPropagation();
      const list = $("chat-menu-list");
      list.hidden = !list.hidden;
      $("chat-menu").setAttribute("aria-expanded", String(!list.hidden));
    });
    document.addEventListener("click", (ev) => { if (!$("chat-menu-list").contains(ev.target)) closeMenu(); });
    document.addEventListener("keydown", (ev) => {
      if (ev.key !== "Escape") return;
      closeMenu();
      if (!$("drawer").hidden) closeDrawer();
    });
    $("rename-chat").addEventListener("click", async () => {
      closeMenu();
      if (!app.chat) return;
      const title = await promptModal("Rename chat", "Title", app.chat.title);
      if (!title) return;
      app.chat = await post("/api/chats/" + app.chat.id + "/rename", { title });
      syncTop();
      await refreshChats();
    });
    $("delete-chat").addEventListener("click", async () => {
      closeMenu();
      if (!app.chat) return;
      const ok = await confirmModal("Delete this chat?", "\"" + app.chat.title + "\" and its messages are deleted. Builds keep their branches and reports. This cannot be undone.", "Delete chat", true);
      if (!ok) return;
      await post("/api/chats/" + app.chat.id + "/delete", {});
      app.chat = null;
      await refreshChats();
      showView("home");
    });
    $("project-picker").addEventListener("change", () => {
      try { localStorage.setItem("harness.project", $("project-picker").value); } catch (e) { /* storage may be off */ }
      syncComposer();
    });
    $("project-add").addEventListener("click", () => addProjectModal("link"));
    $("project-preview").addEventListener("click", () => { const p = project(); if (p) openPreview({ project: p.name }, p.name); });
    syncLan();
    setInterval(syncLan, 15000);
    $("side-toggle").addEventListener("click", () => setSide(!$("app").classList.contains("side-open")));
    $("side-scrim").addEventListener("click", () => setSide(false));
    $("chat-list").addEventListener("click", () => setSide(false));
    document.addEventListener("keydown", (ev) => { if (ev.key === "Escape") setSide(false); });
    window.matchMedia("(prefers-color-scheme: light)").addEventListener("change", () => { if (app.view === "settings" && app.settingsTab === "appearance") renderSettings(); });
    // Running cards: "updated … ago" and the elapsed time move on.
    setInterval(() => {
      for (const card of app.builds.values()) if (card.es && document.contains(card.node)) card.render();
    }, 10000);
    setMode("chat");
  }

  wire();
  loadState()
    .then(async () => {
      await loadProjects();
      if (app.state.configured && app.state.chats.length) return openChat(app.state.chats[0].id);
      showView("home");
      return null;
    })
    .catch((e) => { $("status-text").textContent = e.message; $("status-dot").className = "dot bad"; });
})();

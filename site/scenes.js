// Live replicas of the page's other footage: the two films in "A day" (a Wisp window,
// scrubbed by the scroll) and the six reel cards (a Mac desktop with Wisp's notch island,
// looping while the card is on screen). Like the hero, each scene draws everything from one
// progress value between 0 and 1, so scrolling back rewinds it and nothing drifts.
(function () {
  var UI = window.WispUI;
  if (!UI) return;
  var buddy = UI.buddy, icon = UI.icon, RIBBON = UI.RIBBON, between = UI.between, along = UI.along;

  // ---------- Small helpers shared by every scene ----------

  function setClass(element, name, isOn) { if (element.classList.contains(name) !== isOn) element.classList.toggle(name, isOn); }
  function setText(element, text) { if (element.textContent !== text) element.textContent = text; }
  function setHTML(element, html) { if (element.__html !== html) { element.__html = html; element.innerHTML = html; } }
  function escapeText(text) { return text.replace(/&/g, "&amp;").replace(/</g, "&lt;"); }
  function within(progress, ranges) {
    for (var index = 0; index < ranges.length; index++) if (progress >= ranges[index][0] && progress < ranges[index][1]) return true;
    return false;
  }

  // Rich text that streams in: lines of [text, isBold] runs, cut after `amount` of the characters.
  function streamRich(lines, amount) {
    var total = 0;
    lines.forEach(function (line) { line.forEach(function (run) { total += run[0].length; }); });
    var remaining = Math.round(total * amount);
    var html = [];
    for (var lineIndex = 0; lineIndex < lines.length && remaining > 0; lineIndex++) {
      var lineHTML = "";
      lines[lineIndex].forEach(function (run) {
        if (remaining <= 0) return;
        var shown = escapeText(run[0].slice(0, remaining));
        remaining -= run[0].length;
        lineHTML += run[1] ? "<b>" + shown + "</b>" : shown;
      });
      html.push(lineHTML || "&nbsp;");
    }
    var isStreaming = amount > 0 && amount < 1;
    return html.map(function (line, index) {
      return "<p>" + line + (isStreaming && index === html.length - 1 ? '<i class="lv-caret"></i>' : "") + "</p>";
    }).join("");
  }
  function plain(text) { return text.split("\n").map(function (line) { return [[line, false]]; }); }

  // A pointer that travels between points and dips while it presses.
  function makePointer(canvas, designWidth) {
    var element = document.createElement("div");
    element.className = "lv-pointer";
    element.innerHTML = UI.POINTER;
    canvas.appendChild(element);
    return {
      // Where an element's centre is, in the canvas's own design pixels.
      centreOf: function (target, offsetX, offsetY) {
        var canvasBox = canvas.getBoundingClientRect();
        var box = target.getBoundingClientRect();
        var scale = designWidth / canvasBox.width;
        return [(box.left - canvasBox.left + box.width / 2) * scale + (offsetX || 0), (box.top - canvasBox.top + box.height / 2) * scale + (offsetY || 0)];
      },
      place: function (point, isPressed, isHidden) {
        element.style.transform = "translate(" + (point[0] - 3).toFixed(1) + "px," + (point[1] - 3).toFixed(1) + "px) scale(" + (isPressed ? 0.86 : 1) + ")";
        setClass(element, "hidden", !!isHidden);
      }
    };
  }

  // Path stops whose points may be elements; resolved every frame so layout changes don't matter.
  function resolveStops(pointer, stops) {
    return stops.map(function (stop) {
      var point = stop[1];
      if (point && point.nodeType) point = pointer.centreOf(point, stop[2], stop[3]);
      return [stop[0], point[0], point[1]];
    });
  }

  // ---------- Wisp's window, used by the two films ----------

  var SIDEBAR = [
    { id: "cowork", shape: "pebble", name: "Cowork", text: "Runs when you ask" },
    { id: "focus", shape: "drop", name: "Focus", role: "Planner", text: "Runs when you ask" },
    { id: "researcher", shape: "capsule", name: "Researcher", role: "R", time: "8:12 AM", text: "Three good sources on enzyme rates" },
    { id: "inbox", shape: "cloud", name: "Inbox", role: "Inbox", time: "8:40 AM", text: "Two things: Ms. Rivera moved office hours" },
    { id: "writer", shape: "square", name: "Writer", role: "Writer", time: "Yesterday", text: "Your essay outline is ready" },
    { id: "planner", shape: "circle", name: "Planner", role: "Planner", time: "7:30 AM", text: "Today's checklist is ready" }
  ];

  function wispWindow(activeRail, mainHTML) {
    return '<div class="wa ws">' +
      '<div class="wa-lights"><i></i><i></i><i></i></div>' +
      '<nav class="wa-rail">' + UI.rail(activeRail) + "</nav>" +
      '<aside class="wa-side">' +
        '<span class="wa-new">' + icon("plus", 16) + "</span>" +
        '<div class="wa-search">' + icon("sidebar", 17) + '<span class="wa-field">' + icon("search", 14) + "Search</span></div>" +
        '<div class="wa-group">Pinned <i>1</i>' + icon("chevron", 13) + "</div>" +
        UI.sidebarRow({ id: "briefer", shape: "triangle", name: "Briefer", time: "Yesterday", text: "Two things today. Your essay is due Friday" }) +
        '<div class="wa-group">Buddies <i>6</i>' + icon("chevron", 13) + "</div>" +
        SIDEBAR.map(UI.sidebarRow).join("") +
        '<div class="wa-side-foot"><b data-foot>Ready</b><span>Claude Sonnet 5.5</span></div>' +
      "</aside>" +
      '<section class="wa-main ws-main">' +
        '<div class="wa-status">' + RIBBON + '<b data-status>Ready</b><i class="wa-dot"></i><span>Claude Sonnet 5.5</span></div>' +
        mainHTML +
      "</section>" +
    "</div>";
  }

  // ---------- Film: the Briefer hands its brief to the Writer ----------

  var BRIEF = [[["Three things today. The ", false], ["Bio lab report", true], [" is due at 11:59 PM, so start the results section in your 2:00 study block. The ", false],
    ["Spanish quiz", true], [" is at 10, and soccer is at 5. History chapter 7 rolled over from yesterday; it can wait until tonight.", false]]];
  var PLAN = [
    [["Here's a plan to get the lab report done before soccer:", false]],
    [["Results (2:00–2:30): ", true], ["the table and graph first, with units and the averages.", false]],
    [["Analysis (2:30–3:00): ", true], ["percent error against the expected value, and one line on what it means.", false]],
    [["Discussion (tonight): ", true], ["two sources of error and how each one moved your result.", false]],
    [["Intro and conclusion (last): ", true], ["five sentences each, once you know what you found.", false]],
    [["", false]],
    [["Paste your draft here when you have one and I'll tighten it.", false]]
  ];

  function handoffScene(canvas) {
    var briefText = BRIEF[0].map(function (run) { return run[0]; }).join("");
    canvas.innerHTML = wispWindow("people",
      '<div class="ws-bar">' +
        '<span class="ws-tab" data-tab>' + buddy("triangle", 18) + "<b>Briefer</b></span>" +
        '<span class="ws-tab-plus">' + icon("plus", 14) + "</span>" +
        '<span class="ws-model">Claude Sonnet 5.5</span>' +
        '<span class="ws-run" data-run>' + icon("play", 12) + "Run now</span>" +
        '<span class="ws-icon">' + icon("more", 18) + '</span><span class="ws-icon">' + icon("panel", 17) + "</span>" +
      "</div>" +
      '<div class="ws-threads">' +
        '<div class="ws-thread" data-thread="briefer">' +
          '<p class="ws-mission">' + icon("flag", 14) + "Tell me what's on my calendar and what to prepare, briefly.</p>" +
          '<p class="ws-day">Today</p>' +
          '<div class="ws-steps" data-brief-steps><span class="ws-spin"></span><span data-brief-step>Reading your calendar</span></div>' +
          '<div class="ws-bubble" data-brief></div>' +
          '<div class="ws-meta" data-brief-meta>9:00 AM ' + icon("copy", 13) + icon("retry", 13) + icon("share", 13) + "</div>" +
          '<div class="ws-handed" data-handed>' + icon("share", 14) + "Handed its answer to " + buddy("square", 18) + "<b>Writer</b></div>" +
        "</div>" +
        '<div class="ws-thread" data-thread="writer">' +
          '<p class="ws-mission">' + icon("flag", 14) + "Help me outline, draft and tighten essays and assignments.</p>" +
          '<p class="ws-day">Today</p>' +
          '<div class="ws-from">' + buddy("triangle", 26) + '<div><span>From Briefer</span><p>' + escapeText(briefText) + "</p></div></div>" +
          '<div class="ws-steps" data-plan-steps><span class="ws-spin"></span><span>Planning around your day</span></div>' +
          '<div class="ws-bubble ws-plan" data-plan></div>' +
          '<div class="ws-meta" data-plan-meta>9:01 AM ' + icon("copy", 13) + icon("retry", 13) + icon("share", 13) + "</div>" +
        "</div>" +
      "</div>" +
      '<div class="ws-composer">' + icon("plus", 16) + '<span data-composer>Message Briefer</span><span class="ws-send">' + icon("send", 14) + "</span></div>" +
      '<div class="ws-baton" data-baton>' + buddy("triangle", 20) + "Brief for Writer</div>");

    var find = function (selector) { return canvas.querySelector(selector); };
    var app = find(".wa");
    var pointer = makePointer(app, 1400);
    var tab = find("[data-tab]"), run = find("[data-run]"), composer = find("[data-composer]");
    var briefThread = find('[data-thread="briefer"]'), writerThread = find('[data-thread="writer"]');
    var brief = find("[data-brief]"), briefSteps = find("[data-brief-steps]"), briefStep = find("[data-brief-step]"), briefMeta = find("[data-brief-meta]");
    var handed = find("[data-handed]"), baton = find("[data-baton]");
    var plan = find("[data-plan]"), planSteps = find("[data-plan-steps]"), planMeta = find("[data-plan-meta]");
    var briefRow = find('[data-row="briefer"]'), writerRow = find('[data-row="writer"]');
    var writerText = writerRow.querySelector(".wa-row-text"), writerTime = writerRow.querySelector(".wa-time");
    var briefRowText = briefRow.querySelector(".wa-row-text"), briefRowTime = briefRow.querySelector(".wa-time");
    var status = find("[data-status]"), foot = find("[data-foot]");
    var showingWriter = null;

    return function (progress) {
      // Run now is pressed, the Briefer reads the calendar and writes its brief.
      var briefWorking = progress >= 0.08 && progress < 0.34;
      setClass(run, "pressed", within(progress, [[0.06, 0.09]]));
      setClass(briefSteps, "shown", progress >= 0.08);
      setClass(briefSteps, "done", progress >= 0.15);
      setText(briefStep, progress >= 0.15 ? "Read your calendar and reminders · 3s" : "Reading your calendar");
      setHTML(brief, streamRich(BRIEF, between(progress, 0.15, 0.33)));
      setClass(brief, "shown", progress >= 0.15);
      setClass(briefMeta, "shown", progress >= 0.34);
      setClass(briefRow, "working", briefWorking);
      setText(briefRowText, progress >= 0.34 ? "Three things today. The Bio lab report…" : "Two things today. Your essay is due Friday");
      setText(briefRowTime, progress >= 0.34 ? "9:00 AM" : "Yesterday");

      // It hands the brief on: the step appears and the brief flies to Writer in the sidebar.
      setClass(handed, "shown", progress >= 0.38);
      var flight = between(progress, 0.4, 0.48);
      setClass(baton, "flying", flight > 0 && flight < 1);
      if (flight > 0 && flight < 1) {
        var from = pointer.centreOf(handed), to = pointer.centreOf(writerRow);
        var eased = UI.smooth(flight);
        var x = from[0] + (to[0] - from[0]) * eased;
        var y = from[1] + (to[1] - from[1]) * eased - Math.sin(eased * Math.PI) * 120;
        baton.style.transform = "translate(" + x.toFixed(1) + "px," + y.toFixed(1) + "px) translate(-50%,-50%) scale(" + (1 - eased * 0.35).toFixed(3) + ")";
      }
      var writerWorking = progress >= 0.47 && progress < 0.86;
      setClass(writerRow, "working", writerWorking);
      setClass(writerRow, "unread", progress >= 0.86);
      setText(writerText, progress >= 0.86 ? "Here's a plan to get the lab report done" : writerWorking ? "Planning the lab report…" : "Your essay outline is ready");
      setText(writerTime, progress >= 0.86 ? "9:01 AM" : writerWorking ? "" : "Yesterday");

      // You open Writer's chat and its plan streams in.
      var onWriter = progress >= 0.5;
      if (onWriter !== showingWriter) {
        showingWriter = onWriter;
        setHTML(tab, onWriter ? buddy("square", 18) + "<b>Writer</b>" : buddy("triangle", 18) + "<b>Briefer</b>");
        setText(composer, onWriter ? "Message Writer" : "Message Briefer");
        setClass(briefThread, "away", onWriter);
        setClass(writerThread, "here", onWriter);
        setClass(briefRow, "selected", !onWriter);
        setClass(writerRow, "selected", onWriter);
      }
      setClass(planSteps, "shown", progress >= 0.54);
      setClass(planSteps, "done", progress >= 0.6);
      setHTML(plan, streamRich(PLAN, between(progress, 0.6, 0.85)));
      setClass(plan, "shown", progress >= 0.6);
      setClass(planMeta, "shown", progress >= 0.86);

      var state = briefWorking || writerWorking ? "Working · 1" : "Ready";
      setClass(app, "is-thinking", briefWorking || writerWorking);
      setText(status, state);
      setText(foot, state);

      var stops = resolveStops(pointer, [[0, [900, 640]], [0.05, run, 4, 2], [0.12, run, 4, 2], [0.2, [960, 520]], [0.42, [1020, 600]],
        [0.49, writerRow, -20, 0], [0.53, writerRow, -20, 0], [0.62, [1000, 700]], [1, [1080, 760]]]);
      pointer.place(along(stops, progress), within(progress, [[0.06, 0.09], [0.495, 0.52]]));
    };
  }

  // ---------- Film: an automation, said once ----------

  var AUTOMATIONS = [
    ["circle", "Daily checklist", "Every day at 7:30 AM · next Tomorrow 7:30 AM"],
    ["triangle", "Weekly review", "Every Sunday at 6:00 PM · next Sun 6:00 PM"],
    ["triangle", "Meeting prep", "10 minutes before a meeting"],
    ["drop", "Summarize this page", "When I run it"],
    ["drop", "Explain this error", "When I run it"],
    ["drop", "Draft a reply", "When I run it"],
    ["drop", "What should I click?", "When I run it"]
  ];
  var SAID = "every weekday at 8, tell me what's due";
  var CHIPS = [["clock", "When", "Every weekday at 8:00 AM"], ["calendar", "From", "Canvas, next 3 days"], ["card", "To", "Notch card"],
    ["people", "Who", "Planner"], ["bell", "Tell me", "Every time"]];

  function automationRow(shape, title, detail, extraClass) {
    return '<div class="ws-auto-row ' + (extraClass || "") + '">' + buddy(shape, 28) + "<span><b>" + title + "</b>" + detail + "</span>" +
      icon("right", 15) + '<span class="ws-play">' + icon("play", 10) + '</span><span class="ws-toggle"></span></div>';
  }

  function automateScene(canvas) {
    canvas.innerHTML = wispWindow("bolt",
      '<div class="ws-auto">' +
        '<div class="ws-say" data-say-bar>' + icon("bubble", 16) + '<span data-say></span><i class="lv-caret" data-say-caret></i>' +
          '<span class="ws-say-send" data-say-send>' + icon("send", 13) + '</span><span class="ws-say-new">' + icon("plus", 13) + "New</span></div>" +
        '<div class="ws-draft" data-draft><div class="ws-draft-inner">' +
          '<div class="ws-draft-head">' + icon("flask", 17) + "<b>What's due</b></div>" +
          '<p class="ws-draft-body">Tell me what\'s due</p>' +
          '<div class="ws-chips">' + CHIPS.map(function (chip, index) {
            return '<span class="ws-chip" data-chip="' + index + '">' + icon(chip[0], 15) + "<span><i>" + chip[1] + "</i>" + chip[2] + "</span>" + icon("chevron", 12) + "</span>";
          }).join("") + "</div>" +
          '<div class="ws-leaves" data-leaves><p class="ws-leaves-head">' + icon("cloud", 16) + "This leaves your Mac</p>" +
            "<p>Canvas, next 3 days would be sent to Planner's cloud model each run.</p>" +
            '<p class="ws-allow">Allow this <span class="ws-toggle off"></span></p><p class="ws-leaves-note">Until you allow it, runs skip this source.</p></div>' +
          '<div class="ws-draft-foot"><span>' + icon("flask", 14) + 'Test run</span><span class="ws-cancel">Cancel</span><span class="ws-save" data-save>Save</span></div>' +
        "</div></div>" +
        '<p class="ws-list-head">Your automations <i data-count>7</i></p>' +
        '<div class="ws-list">' + automationRow("circle", "What's due", "Every weekday at 8:00 AM · next Mon 8:00 AM", "ws-new-row") +
          AUTOMATIONS.map(function (row) { return automationRow(row[0], row[1], row[2]); }).join("") + "</div>" +
      "</div>");

    var find = function (selector) { return canvas.querySelector(selector); };
    var app = find(".wa");
    var pointer = makePointer(app, 1400);
    var sayBar = find("[data-say-bar]"), say = find("[data-say]"), caret = find("[data-say-caret]"), send = find("[data-say-send]");
    var draft = find("[data-draft]"), leaves = find("[data-leaves]"), save = find("[data-save]"), count = find("[data-count]");
    var newRow = find(".ws-new-row");
    var chips = Array.prototype.slice.call(canvas.querySelectorAll("[data-chip]"));

    return function (progress) {
      // You click the bar and say it.
      var typing = between(progress, 0.12, 0.32);
      var isFocused = progress >= 0.1 && progress < 0.38;
      var saved = progress >= 0.9;
      setClass(sayBar, "focused", isFocused);
      setClass(caret, "shown", isFocused);
      var typed = SAID.slice(0, Math.round(SAID.length * typing));
      setText(say, typed || "Say it: “every weekday at 8, tell me what's due”");
      setClass(say, "placeholder", !typed || progress >= 0.38);
      if (progress >= 0.38) setText(say, "Say it: “every weekday at 8, tell me what's due”");
      setClass(send, "ready", typed.length > 0 && progress < 0.38);
      setClass(send, "pressed", within(progress, [[0.36, 0.39]]));

      // It becomes a card you can check, one field at a time.
      setClass(draft, "open", progress >= 0.38 && !saved);
      chips.forEach(function (chip, index) {
        var appearsAt = 0.44 + index * 0.045;
        setClass(chip, "shown", progress >= appearsAt);
        setClass(chip, "glint", progress >= appearsAt && progress < appearsAt + 0.06);
      });
      setClass(leaves, "shown", progress >= 0.7);
      setClass(save, "pressed", within(progress, [[0.87, 0.9]]));

      // Saved: the card folds into the list.
      setClass(newRow, "shown", saved);
      setClass(newRow, "glint", saved && progress < 0.98);
      setText(count, saved ? "8" : "7");

      var stops = resolveStops(pointer, [[0, [980, 560]], [0.08, sayBar, -120, 0], [0.32, sayBar, -120, 6], [0.36, send], [0.4, send],
        [0.6, [1060, 470]], [0.74, leaves, 60, 20], [0.82, leaves, 60, 20], [0.87, save], [0.92, save], [1, [1150, 640]]]);
      pointer.place(along(stops, progress), within(progress, [[0.1, 0.12], [0.36, 0.39], [0.87, 0.9]]));
    };
  }

  // ---------- The Mac desktop, used by the reel ----------

  // macOS window chrome around a light app.
  function macWindow(name, title, bodyHTML, style) {
    return '<div class="mw" data-window="' + name + '" style="' + style + '"><div class="mw-bar"><span class="mw-lights"><i></i><i></i><i></i></span>' +
      '<span class="mw-title">' + title + "</span></div>" + bodyHTML + "</div>";
  }

  function textEditBody(documentHTML) {
    return '<div class="te-tools"><span>¶ ⌄</span><span class="te-group"><b data-tool="bold">B</b><i>I</i><u>U</u><s>S</s></span><span class="te-swatch"></span>' +
      '<span class="te-select">Helvetica</span><span class="te-select">Regular</span><span class="te-select">28</span>' +
      '<span class="te-group te-align"><em data-tool="left">' + alignIcon("left") + '</em><em data-tool="center">' + alignIcon("center") + "</em><em>" + alignIcon("right") + "</em></span>" +
      '<span class="te-select">1.0</span></div>' +
      '<div class="te-ruler"></div><div class="te-doc" data-doc>' + documentHTML + "</div>";
  }
  function alignIcon(kind) {
    var lines = kind === "center" ? "M5 7h14M8 11h8M5 15h14M8 19h8" : kind === "right" ? "M5 7h14M10 11h9M5 15h14M10 19h9" : "M5 7h14M5 11h9M5 15h14M5 19h9";
    return '<svg width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round"><path d="' + lines + '"/></svg>';
  }

  // The notch island: listens (with the words as you say them), thinks, guides, asks or answers.
  function islandHTML() {
    return '<div class="isl" data-island><span class="isl-notch"></span>' +
      '<span class="isl-left">' + RIBBON + '</span><span class="isl-right"><span class="isl-wave"><i></i><i></i><i></i><i></i><i></i></span><span class="isl-dots"><i></i><i></i><i></i></span></span>' +
      '<div class="isl-body" data-island-body></div></div>';
  }
  function makeIsland(desktop) {
    var island = desktop.querySelector("[data-island]");
    var body = desktop.querySelector("[data-island-body]");
    var lastKey = "";
    return function (state, key, html, flash) {
      if (island.dataset.state !== state) island.dataset.state = state;
      setClass(island, "flash", !!flash);
      if (key !== lastKey) {
        lastKey = key;
        body.innerHTML = html || "";
        // Grow to fit what it now holds; the CSS transition animates the change.
        var height = state === "think" || state === "idle" ? 32 : body.offsetHeight + 46;
        island.style.height = height + "px";
      }
    };
  }
  function heard(text, amount) {
    var words = text.split(" ");
    var shown = words.slice(0, Math.max(1, Math.round(words.length * amount))).join(" ");
    return '<p class="isl-heard">' + escapeText(shown) + '<i class="lv-caret"></i></p>';
  }
  function replyCard(text, kicker) {
    return '<p class="isl-kicker">' + RIBBON + (kicker || "Wisp") + "</p><p>" + text + "</p>";
  }

  function desktop(canvas, wall, appName, contentHTML) {
    canvas.innerHTML = '<div class="dk" style="' + wall + '">' +
      '<div class="dk-menubar"><span class="dk-apple"></span><b>' + appName + "</b><span>File</span><span>Edit</span><span>Format</span><span>View</span><span>Window</span><span>Help</span>" +
      '<span class="dk-right">' + RIBBON + '<span>Tue 9:41 AM</span></span></div>' + contentHTML + islandHTML() + "</div>";
    var root = canvas.querySelector(".dk");
    return { root: root, find: function (selector) { return root.querySelector(selector); }, island: makeIsland(root), pointer: makePointer(root, 1280),
      camera: function (stops, progress) { aimCamera(root, stops, progress); } };
  }

  // The reel cards are small, so each scene's camera eases in on where the action is, like a
  // screen recording edited with zooms. Stops are [progress, centre x, centre y, zoom].
  function aimCamera(root, stops, progress) {
    var view = stops[stops.length - 1].slice(1);
    for (var index = 0; index < stops.length - 1; index++) {
      var from = stops[index], to = stops[index + 1];
      if (progress < from[0]) { view = from.slice(1); break; }
      if (progress <= to[0]) {
        var amount = UI.smooth(between(progress, from[0], to[0]));
        view = [1, 2, 3].map(function (key) { return from[key] + (to[key] - from[key]) * amount; });
        break;
      }
    }
    var zoom = view[2];
    var shiftX = UI.clamp(640 - view[0] * zoom, 1280 - 1280 * zoom, 0);
    var shiftY = UI.clamp(360 - view[1] * zoom, 720 - 720 * zoom, 0);
    root.style.transform = "translate(" + shiftX.toFixed(2) + "px," + shiftY.toFixed(2) + "px) scale(" + zoom.toFixed(4) + ")";
  }
  var WIDE = [640, 360, 1];
  function shot(progress, view) { return [progress, view[0], view[1], view[2]]; }
  var ON_ISLAND = [640, 110, 1.9];

  var WALLS = {
    violet: "--w1:#6E5BFF;--w2:#FF6FA3;--w3:#FFB45E;--w4:#1C1E4E",
    ocean: "--w1:#2EC5FF;--w2:#6E5BFF;--w3:#58E0B0;--w4:#0F2347",
    sunset: "--w1:#FF7A59;--w2:#C04BFF;--w3:#FFD25E;--w4:#2A1440",
    mint: "--w1:#3DDC97;--w2:#3D7CF6;--w3:#B98CFF;--w4:#0E2A35",
    berry: "--w1:#FF4F8B;--w2:#7B5CFF;--w3:#38C7FF;--w4:#22103A",
    dawn: "--w1:#FFB347;--w2:#FF5E8A;--w3:#6E7BFF;--w4:#2B1838"
  };

  var NOTES_DOCUMENT = '<p class="te-big">Meeting notes</p><p class="te-big">Ship the README today</p>';

  // ---------- Reel: email, drafted ----------

  var EMAIL_BODY = "Hi Sam,\n\nWould it be possible to move Friday's launch review to Monday? Let me know if that works for you, and if so, what time suits you best.\n\nThanks for being flexible.\n\nAnay";
  function emailScene(canvas) {
    var scene = desktop(canvas, WALLS.violet, "TextEdit",
      macWindow("notes", "Launch checklist", textEditBody(NOTES_DOCUMENT), "left:90px;top:120px;width:640px;height:440px") +
      '<div class="em" data-email><div class="em-head"><b>New email</b>' + icon("x", 14) + "</div>" +
        '<div class="em-field"><i>To</i><span>Sam Chen &lt;sam@example.com&gt;</span><em>Cc</em></div>' +
        '<div class="em-field"><i>Subject</i><span data-subject></span></div>' +
        '<div class="em-body" data-body></div>' +
        '<div class="em-foot"><span class="em-more">More ⌄</span><span class="em-from">Sends from your Mail account</span><span class="em-discard">Discard</span>' +
        '<span class="em-send" data-send>Send <i>⌘↩</i></span></div></div>');
    var email = scene.find("[data-email]"), subject = scene.find("[data-subject]"), body = scene.find("[data-body]"), send = scene.find("[data-send]");
    return function (progress) {
      scene.camera([shot(0, WIDE), shot(0.05, ON_ISLAND), shot(0.32, ON_ISLAND), shot(0.4, [820, 330, 1.45]), shot(0.76, [820, 330, 1.45]), shot(0.8, [900, 480, 1.6]), shot(0.86, [900, 480, 1.6]), shot(0.9, ON_ISLAND), shot(1, ON_ISLAND)], progress);
      var spoken = "draft an email to Sam moving Friday's launch review to Monday";
      if (progress < 0.04 || progress >= 0.4 && progress < 0.86) scene.island("idle", "idle");
      else if (progress < 0.3) scene.island("listen", "listen" + Math.round(between(progress, 0.05, 0.28) * 20), heard(spoken, between(progress, 0.05, 0.28)));
      else if (progress < 0.4) scene.island("think", "think");
      else scene.island("reply", "sent", replyCard("Sent to Sam Chen.", "Wisp · Mail"), true);
      setClass(email, "shown", progress >= 0.38 && progress < 0.88);
      setClass(email, "sending", progress >= 0.86);
      setText(subject, "Moving Friday's launch review to Monday".slice(0, Math.round(39 * between(progress, 0.42, 0.5))));
      var writing = between(progress, 0.5, 0.74);
      setClass(body, "writing", progress >= 0.4 && writing === 0);
      setHTML(body, writing > 0 ? streamRich(plain(EMAIL_BODY), writing) : '<p class="em-writing">Writing…</p>');
      setClass(send, "pressed", within(progress, [[0.82, 0.86]]));
      var stops = resolveStops(scene.pointer, [[0, [980, 640]], [0.5, [1010, 600]], [0.76, [1000, 620]], [0.81, send], [0.9, send], [1, [1060, 660]]]);
      scene.pointer.place(along(stops, progress), within(progress, [[0.82, 0.86]]));
    };
  }

  // ---------- Reel: an errand in your browser ----------

  function browserScene(canvas) {
    var article = '<div class="wk" data-page><div class="wk-top"><span class="wk-logo">Wikipedia</span><span class="wk-search">Search</span></div>' +
      '<h4>Enigma machine</h4><p class="wk-tabs"><b>Article</b><span>Talk</span><em>Read</em><em>Edit</em><em>View history</em></p>' +
      '<div class="wk-cols"><div><p>The <b>Enigma machine</b> is a cipher device developed in the early twentieth century and used to protect military and diplomatic messages.</p>' +
      "<p>Each key press sent current through a set of rotating wheels, so the same letter came out differently every time. Operators set the wheels each day from a shared key sheet.</p>" +
      "<p>Codebreakers in Poland and later at Bletchley Park found weaknesses in how it was used, and reading its traffic shaped the course of the Second World War.</p></div>" +
      '<figure class="wk-figure"><svg viewBox="0 0 120 90" aria-hidden="true"><rect x="8" y="22" width="104" height="60" rx="6" fill="#3B3227"/><rect x="14" y="10" width="92" height="22" rx="4" fill="#5C4D3A"/>' +
      '<g fill="#E9E1CF">' + Array.apply(null, Array(24)).map(function (_, index) { return '<circle cx="' + (22 + (index % 8) * 11) + '" cy="' + (44 + Math.floor(index / 8) * 11) + '" r="3.6"/>'; }).join("") +
      '</g><g fill="#C9A96B"><rect x="40" y="14" width="8" height="14" rx="2"/><rect x="56" y="14" width="8" height="14" rx="2"/><rect x="72" y="14" width="8" height="14" rx="2"/></g></svg>' +
      "<figcaption>An Enigma with three rotors.</figcaption></figure></div></div>";
    var scene = desktop(canvas, WALLS.ocean, "Google Chrome",
      '<div class="cr" data-chrome><div class="cr-tabs"><span class="mw-lights"><i></i><i></i><i></i></span>' +
        '<span class="cr-tab cr-user">Launch notes</span><span class="cr-tab cr-wisp" data-wisp-tab>' + RIBBON + "<span>Enigma machine</span></span><span class=\"cr-plus\">+</span></div>" +
        '<div class="cr-bar">' + icon("back", 16) + icon("right", 16) + icon("reload", 15) + '<span class="cr-omni" data-omni></span>' + icon("star", 15) + "</div>" +
        '<div class="cr-page"><div class="cr-blank" data-blank><p>Launch notes</p><span></span><span></span><span></span></div><div class="cr-loading" data-loading></div>' + article + "</div></div>" +
      '<div class="lv-agent" data-agent><svg width="22" height="22" viewBox="0 0 24 24"><path d="M3 3l17 7-7 2.5L10 20 3 3Z" fill="#8B5CF6" stroke="#fff" stroke-width="1.6" stroke-linejoin="round"/></svg><span>Reading the article</span></div>');
    var chrome = scene.find("[data-chrome]"), wispTab = scene.find("[data-wisp-tab]"), omni = scene.find("[data-omni]");
    var blank = scene.find("[data-blank]"), loading = scene.find("[data-loading]"), page = scene.find("[data-page]"), agent = scene.find("[data-agent]");
    var address = "en.wikipedia.org/wiki/Enigma_machine";
    return function (progress) {
      scene.camera([shot(0, WIDE), shot(0.05, ON_ISLAND), shot(0.3, ON_ISLAND), shot(0.36, [520, 150, 1.7]), shot(0.46, [520, 150, 1.7]), shot(0.52, [560, 360, 1.3]), shot(0.68, [600, 380, 1.3]), shot(0.74, [640, 130, 1.8]), shot(1, [640, 130, 1.8])], progress);
      var spoken = "open the Wikipedia page on the Enigma machine and sum it up";
      if (progress < 0.04 || progress >= 0.32 && progress < 0.7) scene.island("idle", "idle");
      else if (progress < 0.26) scene.island("listen", "l" + Math.round(between(progress, 0.05, 0.24) * 20), heard(spoken, between(progress, 0.05, 0.24)));
      else if (progress < 0.32) scene.island("think", "think");
      else scene.island("reply", "summary", replyCard("I'm on the Enigma machine page. It was a rotor cipher machine that changed every letter as you typed. Breaking it at Bletchley Park helped the Allies win the war.", "Wisp · Chrome"));
      var working = progress >= 0.32 && progress < 0.7;
      setClass(chrome, "rim", working);
      setClass(wispTab, "shown", progress >= 0.32);
      setClass(chrome, "wisp-tab", progress >= 0.32);
      var typed = between(progress, 0.34, 0.44);
      setText(omni, progress >= 0.32 ? address.slice(0, Math.round(address.length * typed)) : "notes.example.com/launch");
      setClass(blank, "hidden", progress >= 0.32);
      setClass(loading, "on", progress >= 0.44 && progress < 0.5);
      setClass(page, "shown", progress >= 0.48);
      var reading = between(progress, 0.52, 0.68);
      setClass(agent, "shown", progress >= 0.5 && progress < 0.7);
      agent.style.transform = "translate(" + (420 + reading * 260).toFixed(1) + "px," + (330 + Math.sin(reading * Math.PI * 3) * 6 + reading * 150).toFixed(1) + "px)";
      scene.pointer.place([1150, 650], false, false);
    };
  }

  // ---------- Reel: desk, tidied ----------

  function windowsScene(canvas) {
    var dictionary = '<div class="dict"><p class="dict-tabs"><span>All</span><span>Dictionary</span><span>Thesaurus</span><span>Apple</span><b>Wikipedia</b></p><p class="dict-hint">Type a word to look up in…</p><p class="dict-wiki">Wikipedia</p></div>';
    var scene = desktop(canvas, WALLS.sunset, "Finder",
      macWindow("dictionary", "Dictionary", dictionary, "") +
      macWindow("textedit", "Launch checklist", textEditBody('<p>Launch checklist</p><p>- Ship the README</p><p>- Record the demo</p>'), ""));
    var dictionaryWindow = scene.find('[data-window="dictionary"]'), textWindow = scene.find('[data-window="textedit"]');
    // Messy, then tiled: [left, top, width, height] in the desktop's pixels.
    var MESSY_DICTIONARY = [430, 150, 520, 380], MESSY_TEXT = [150, 250, 560, 360];
    var LEFT_HALF = [0, 30, 639, 690], RIGHT_HALF = [641, 30, 639, 690];
    function frame(element, from, to, amount) {
      var values = from.map(function (start, index) { return start + (to[index] - start) * amount; });
      element.style.left = values[0] + "px"; element.style.top = values[1] + "px";
      element.style.width = values[2] + "px"; element.style.height = values[3] + "px";
    }
    return function (progress) {
      scene.camera([shot(0, WIDE), shot(0.05, ON_ISLAND), shot(0.33, ON_ISLAND), shot(0.38, WIDE), shot(0.52, WIDE), shot(0.58, [640, 260, 1.35]), shot(1, [640, 260, 1.35])], progress);
      var spoken = "put Dictionary on the left and TextEdit on the right";
      if (progress < 0.04 || progress >= 0.36 && progress < 0.52) scene.island("idle", "idle");
      else if (progress < 0.34) scene.island("listen", "l" + Math.round(between(progress, 0.05, 0.3) * 20), heard(spoken, between(progress, 0.05, 0.3)));
      else if (progress < 0.36) scene.island("idle", "idle");
      else scene.island("reply", "done", replyCard("Done. Dictionary left, TextEdit right.", "Wisp · no model needed"), true);
      var tidy = UI.smooth(between(progress, 0.36, 0.5));
      frame(dictionaryWindow, MESSY_DICTIONARY, LEFT_HALF, tidy);
      frame(textWindow, MESSY_TEXT, RIGHT_HALF, tidy);
      setClass(dictionaryWindow, "front", progress >= 0.36);
      scene.pointer.place([1110, 600], false, false);
    };
  }

  // ---------- Reel: walked through it ----------

  function guideScene(canvas) {
    var scene = desktop(canvas, WALLS.mint, "TextEdit",
      macWindow("textedit", "Launch Checklist", textEditBody(NOTES_DOCUMENT), "left:150px;top:150px;width:980px;height:500px") +
      '<div class="gd-box" data-guide-box><span class="gd-badge" data-guide-badge>1</span><span class="gd-label" data-guide-label>Bold</span></div>');
    var bold = scene.find('[data-tool="bold"]'), center = scene.find('[data-tool="center"]'), doc = scene.find("[data-doc]");
    var box = scene.find("[data-guide-box]"), badge = scene.find("[data-guide-badge]"), label = scene.find("[data-guide-label]");
    function checklist(stepOneDone, stepTwoDone) {
      function step(number, title, hint, isDone, isActive) {
        return '<div class="gd-step' + (isDone ? " done" : "") + (isActive ? " active" : "") + '"><span>' + (isDone ? icon("check", 11) : number) + "</span><p><b>" + title + "</b>" + (isActive ? "<i>" + hint + "</i>" : "") + "</p></div>";
      }
      return step(1, "Click Bold", "Click the highlighted spot.", stepOneDone, !stepOneDone) +
        step(2, "Click Align Center", "Click the highlighted spot.", stepTwoDone, stepOneDone && !stepTwoDone) +
        '<div class="isl-buttons"><span class="isl-primary">Do it for me</span><span>Next</span><span>Stop</span></div>';
    }
    return function (progress) {
      scene.camera([shot(0, WIDE), shot(0.05, ON_ISLAND), shot(0.22, ON_ISLAND), shot(0.28, [470, 160, 1.6]), shot(0.5, [470, 160, 1.6]), shot(0.58, [560, 170, 1.55]), shot(0.72, [560, 170, 1.55]), shot(0.8, [640, 220, 1.4]), shot(1, [640, 220, 1.4])], progress);
      var spoken = "how do I make this bold and centered";
      var stepOneDone = progress >= 0.43, stepTwoDone = progress >= 0.67;
      if (progress < 0.04) scene.island("idle", "idle");
      else if (progress < 0.2) scene.island("listen", "l" + Math.round(between(progress, 0.05, 0.18) * 20), heard(spoken, between(progress, 0.05, 0.18)));
      else if (progress < 0.24) scene.island("think", "think");
      else if (progress < 0.74) scene.island("guide", "g" + stepOneDone + stepTwoDone, checklist(stepOneDone, stepTwoDone));
      else scene.island("reply", "done", replyCard("All done. It's bold and centered.", "Wisp · walkthrough"), true);
      setClass(doc, "bold", stepOneDone);
      setClass(doc, "centered", stepTwoDone);
      setClass(bold, "on", stepOneDone);
      setClass(center, "on", stepTwoDone);
      var target = stepOneDone ? center : bold;
      var targetBox = scene.pointer.centreOf(target);
      setClass(box, "shown", progress >= 0.24 && progress < 0.72);
      box.style.transform = "translate(" + (targetBox[0] - 17).toFixed(1) + "px," + (targetBox[1] - 15).toFixed(1) + "px)";
      setText(badge, stepOneDone ? "2" : "1");
      setText(label, stepOneDone ? "Align Center" : "Bold");
      var stops = resolveStops(scene.pointer, [[0, [760, 560]], [0.28, [700, 520]], [0.38, bold, 2, 2], [0.46, bold, 2, 2], [0.56, center, 2, 2], [0.7, center, 2, 2], [0.8, [820, 500]], [1, [840, 520]]]);
      scene.pointer.place(along(stops, progress), within(progress, [[0.4, 0.43], [0.64, 0.67]]));
    };
  }

  // ---------- Reel: homework, worked ----------

  var WORKING = ["3x + 7 = 22", "3x = 22 − 7", "3x = 15", "x = 15 ÷ 3", "x = 5"];
  function mathScene(canvas) {
    var scene = desktop(canvas, WALLS.berry, "TextEdit",
      macWindow("homework", "Homework 4", textEditBody('<p class="te-big">Homework 4</p><p class="te-mid">Solve for x:</p><p class="te-big te-equation">3x + 7 = 22</p>'), "left:110px;top:90px;width:1060px;height:590px") +
      '<div class="hw" data-working>' + WORKING.map(function (line, index) { return '<p class="hw-line" data-line="' + index + '"><span>' + line + "</span></p>"; }).join("") +
      '<svg class="hw-circle" viewBox="0 0 200 80" aria-hidden="true"><path data-circle d="M30 44C26 18 90 8 140 14S196 38 178 56 80 76 44 64 18 38 52 26" fill="none" stroke="#3D7CF6" stroke-width="3.2" stroke-linecap="round" pathLength="1"/></svg></div>');
    var lines = Array.prototype.slice.call(canvas.querySelectorAll("[data-line]"));
    var circle = scene.find("[data-circle]");
    return function (progress) {
      scene.camera([shot(0, WIDE), shot(0.05, ON_ISLAND), shot(0.26, ON_ISLAND), shot(0.32, [620, 380, 1.4]), shot(0.84, [640, 390, 1.45]), shot(0.9, [640, 200, 1.5]), shot(1, [640, 200, 1.5])], progress);
      var spoken = "walk me through this one";
      if (progress < 0.04) scene.island("idle", "idle");
      else if (progress < 0.18) scene.island("listen", "l" + Math.round(between(progress, 0.05, 0.16) * 10), heard(spoken, between(progress, 0.05, 0.16)));
      else if (progress < 0.27) scene.island("think", "think");
      else if (progress < 0.86) scene.island("idle", "idle");
      else scene.island("reply", "said", replyCard("Subtract 7 from both sides, then divide by 3. So x is 5.", "Wisp · said aloud"));
      lines.forEach(function (line, index) {
        var written = between(progress, 0.3 + index * 0.1, 0.38 + index * 0.1);
        line.style.setProperty("--written", written.toFixed(3));
        setClass(line, "shown", written > 0);
      });
      circle.style.strokeDashoffset = (1 - between(progress, 0.76, 0.84)).toFixed(3);
      scene.pointer.place([1140, 640], false, false);
    };
  }

  // ---------- Reel: you approve what matters ----------

  function approvalScene(canvas) {
    var scene = desktop(canvas, WALLS.dawn, "TextEdit",
      macWindow("textedit", "Launch Checklist", textEditBody(NOTES_DOCUMENT), "left:150px;top:190px;width:980px;height:470px"));
    var approvalHTML = function (seconds, pressed) {
      return '<p class="isl-kicker">' + RIBBON + 'Wisp needs your OK<span class="isl-count">' + seconds + "s</span></p>" +
        '<div class="ap-card"><p class="ap-title">' + icon("layers", 15) + "<b>Run Shortcut</b><span>Shortcuts</span></p>" +
        '<p class="ap-row"><span>Shortcut</span><b>Word of the Day</b></p><p class="ap-note">' + icon("sparkle", 12) + "Does whatever this shortcut is built to do</p></div>" +
        '<p class="ap-details">› Details</p>' +
        '<div class="isl-buttons isl-wide"><span>Cancel</span><span class="isl-primary' + (pressed ? " pressed" : "") + '" data-allow>Allow →</span></div><p class="ap-say">or just say yes</p>';
    };
    return function (progress) {
      scene.camera([shot(0, WIDE), shot(0.05, ON_ISLAND), shot(0.28, ON_ISLAND), shot(0.34, [640, 190, 1.75]), shot(0.7, [640, 190, 1.75]), shot(0.76, [640, 130, 1.8]), shot(1, [640, 130, 1.8])], progress);
      var spoken = "run my word of the day shortcut";
      var seconds = 45 - Math.floor(between(progress, 0.3, 0.66) * 6);
      var pressed = within(progress, [[0.62, 0.66]]);
      if (progress < 0.04) scene.island("idle", "idle");
      else if (progress < 0.2) scene.island("listen", "l" + Math.round(between(progress, 0.05, 0.18) * 12), heard(spoken, between(progress, 0.05, 0.18)));
      else if (progress < 0.28) scene.island("think", "think");
      else if (progress < 0.68) scene.island("approve", "a" + seconds + pressed, approvalHTML(seconds, pressed));
      else scene.island("reply", "done", replyCard("Word of the day: <b>sonder</b>, the sense that every passer-by has a life as full as your own.", "Wisp · Shortcuts"), true);
      var allow = scene.find("[data-allow]");
      var stops = resolveStops(scene.pointer, [[0, [900, 600]], [0.4, [880, 520]], [0.58, allow || [700, 330]], [0.68, allow || [700, 330]], [0.8, [900, 560]], [1, [920, 580]]]);
      scene.pointer.place(along(stops, progress), pressed);
    };
  }

  var SCENES = { handoff: handoffScene, automate: automateScene, email: emailScene, browser: browserScene, windows: windowsScene,
    guide: guideScene, math: mathScene, approval: approvalScene };

  // ---------- Starting the scenes ----------

  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var isFlat = reduceMotion || window.matchMedia("(max-width: 900px), (pointer: coarse)").matches;

  // Play a scene on a loop while it's on screen: the story, then a short hold on the end.
  function loopWhileVisible(host, setProgress, seconds) {
    if (reduceMotion) { setProgress(1); return; }
    var HOLD_SECONDS = 2.2;
    var isVisible = false, startedAt = 0;
    function tick(now) {
      if (!isVisible) return;
      if (!startedAt) startedAt = now;
      var elapsed = ((now - startedAt) / 1000) % (seconds + HOLD_SECONDS);
      setProgress(Math.min(1, elapsed / seconds));
      window.requestAnimationFrame(tick);
    }
    if (!("IntersectionObserver" in window)) { setProgress(1); return; }
    new IntersectionObserver(function (entries) {
      var wasVisible = isVisible;
      isVisible = entries[0].isIntersecting;
      if (isVisible && !wasVisible) { startedAt = 0; window.requestAnimationFrame(tick); }
    }, { threshold: 0.5 }).observe(host);
  }

  Array.prototype.slice.call(document.querySelectorAll("[data-live]")).forEach(function (host) {
    var makeScene = SCENES[host.dataset.live];
    if (!makeScene) return;
    var designWidth = parseInt(host.dataset.width, 10);
    var setProgress;
    try {
      setProgress = makeScene(host);
    } catch (error) {
      // Leave the poster showing if a scene can't be drawn.
      host.innerHTML = "";
      return;
    }
    UI.fitCanvas(host, designWidth);
    var frame = host.parentElement;
    var poster = frame.querySelector(".poster, img");
    if (poster) poster.hidden = true;
    frame.classList.add("is-live");
    var lastProgress = -1;
    host.setProgress = function (progress) {
      if (Math.abs(progress - lastProgress) < 0.0004) return;
      lastProgress = progress;
      setProgress(progress);
    };
    host.setProgress(0);
    // The films follow the scroll on the pinned page (script.js); everything else loops.
    if (host.dataset.scrub === undefined || isFlat) loopWhileVisible(host, host.setProgress, parseFloat(host.dataset.seconds) || 9);
  });
})();

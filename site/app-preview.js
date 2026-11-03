// A live replica of Wisp's Today window, drawn in HTML instead of a screenshot, so it is
// sharp at any size and its colours are exact. One story plays through it: you ask Wisp
// to plan your afternoon, it thinks, the checklist and calendar change, and a buddy goes
// to work. Everything on screen is a function of one progress value (0–1), so scrolling
// back rewinds it. On the pinned page script.js sets the progress from the scroll; on the
// flat page (phones, touch) the story plays on its own while it's on screen.
(function () {
  var host = document.querySelector("[data-app]");
  if (!host) return;

  var CANVAS_WIDTH = 1400;
  var CANVAS_HEIGHT = 863;
  var QUESTION = "Plan my afternoon around the bio lab report";
  var ANSWER = "Done. Study block 2 to 3 PM is on your calendar, the Spanish quiz is off your list, and Writer is drafting your conclusion.";

  // Buddies are drawn as small SVG characters in their own colours.
  var SHAPES = {
    drop: '<path d="M20 2C26 12 33 19 33 26.5A13 13 0 0 1 7 26.5C7 19 14 12 20 2Z" fill="#3D7CF6"/><ellipse cx="14.5" cy="16" rx="3.6" ry="1.9" fill="#fff" opacity=".4" transform="rotate(-35 14.5 16)"/>',
    triangle: '<path d="M20 5L36 33H4Z" fill="#F0477F" stroke="#F0477F" stroke-width="3.5" stroke-linejoin="round"/><path d="M20 14L28.5 29.5H11.5Z" fill="#FF9CC0" opacity=".5"/>',
    circle: '<circle cx="20" cy="21" r="15.5" fill="#8B5CF6"/><ellipse cx="13.5" cy="13" rx="4" ry="2.2" fill="#fff" opacity=".35" transform="rotate(-35 13.5 13)"/>',
    capsule: '<rect x="9" y="3" width="22" height="34" rx="11" fill="#F5893A"/><ellipse cx="14" cy="10" rx="2.4" ry="3.4" fill="#fff" opacity=".35"/>',
    cloud: '<g fill="#45BE6B"><circle cx="12.5" cy="23" r="9"/><circle cx="27.5" cy="23" r="9"/><circle cx="20" cy="16" r="10"/><circle cx="20" cy="25" r="10"/></g><ellipse cx="15" cy="11.5" rx="3.5" ry="1.8" fill="#fff" opacity=".35" transform="rotate(-25 15 11.5)"/>',
    square: '<rect x="5" y="8" width="30" height="26" rx="10" fill="#34BFAE"/><ellipse cx="12" cy="13.5" rx="3.6" ry="1.8" fill="#fff" opacity=".35" transform="rotate(-20 12 13.5)"/>',
    pebble: '<rect x="3" y="11" width="34" height="21" rx="10.5" fill="#A0643F"/><ellipse cx="11" cy="15" rx="3.6" ry="1.6" fill="#fff" opacity=".3" transform="rotate(-15 11 15)"/>'
  };
  var EYE_HEIGHT = { drop: 25, triangle: 26, circle: 21, capsule: 20, cloud: 22, square: 21, pebble: 21 };

  function face(shape) {
    var y = EYE_HEIGHT[shape];
    var gap = shape === "triangle" ? 3.4 : 4.6;
    var ink = "#141428";
    return '<g class="eyes"><circle cx="' + (20 - gap) + '" cy="' + y + '" r="2.1" fill="' + ink + '"/><circle cx="' + (20 + gap) + '" cy="' + y + '" r="2.1" fill="' + ink + '"/>' +
      '<circle cx="' + (20 - gap + 0.7) + '" cy="' + (y - 0.7) + '" r=".7" fill="#fff"/><circle cx="' + (20 + gap + 0.7) + '" cy="' + (y - 0.7) + '" r=".7" fill="#fff"/></g>' +
      '<path class="mouth" d="M' + (20 - 2.4) + " " + (y + 3.6) + " q2.4 2 4.8 0" + '" stroke="' + ink + '" stroke-width="1.4" fill="none" stroke-linecap="round"/>';
  }
  function buddy(shape, size, extraClass) {
    return '<svg class="bud ' + (extraClass || "") + '" width="' + size + '" height="' + size + '" viewBox="0 0 40 40" aria-hidden="true">' + SHAPES[shape] + face(shape) + "</svg>";
  }

  // The left rail's icons, single strokes like Wisp's own.
  var ICONS = {
    people: '<circle cx="9" cy="8" r="3.2"/><path d="M3 19c0-3.5 2.7-6 6-6s6 2.5 6 6"/><circle cx="16.5" cy="9" r="2.6"/><path d="M15.5 13.2c3 .2 5.5 2.5 5.5 5.8"/>',
    sun: '<circle cx="12" cy="12" r="4"/><path d="M12 2.5v2M12 19.5v2M2.5 12h2M19.5 12h2M5.3 5.3l1.4 1.4M17.3 17.3l1.4 1.4M5.3 18.7l1.4-1.4M17.3 6.7l1.4-1.4"/>',
    chat: '<path d="M4 5h11a2 2 0 0 1 2 2v6a2 2 0 0 1-2 2H9l-4 3v-3H4a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2Z"/><path d="M19 9h1a2 2 0 0 1 2 2v5a2 2 0 0 1-2 2v2.5L17 18h-4"/>',
    bolt: '<path d="M13 2 5 13.5h6L10 22l8-11.5h-6L13 2Z"/>',
    flow: '<circle cx="5" cy="6" r="2"/><circle cx="19" cy="6" r="2"/><circle cx="12" cy="18" r="2"/><path d="M7 6h10M6 8l5 8.3M18 8l-5 8.3"/>',
    cap: '<path d="M2 9.5 12 5l10 4.5-10 4.5L2 9.5Z"/><path d="M6 11.5V16c0 1.5 2.7 3 6 3s6-1.5 6-3v-4.5M22 9.5v5"/>',
    timer: '<path d="M7 3h10M7 21h10M8 3c0 4 8 5 8 9s-8 5-8 9M16 3c0 4-8 5-8 9s8 5 8 9"/>',
    brain: '<path d="M9 4a3 3 0 0 0-3 3 3 3 0 0 0-2 5 3 3 0 0 0 2 5 3 3 0 0 0 3 3h1V4H9ZM15 4a3 3 0 0 1 3 3 3 3 0 0 1 2 5 3 3 0 0 1-2 5 3 3 0 0 1-3 3h-1V4h1Z"/>',
    spark: '<circle cx="12" cy="12" r="9"/><path d="M13 6.5 8.5 13h4l-1 4.5L16 11h-4l1-4.5Z"/>',
    history: '<path d="M3.5 12a8.5 8.5 0 1 0 2.5-6L3.5 8.5M3.5 4v4.5H8"/><path d="M12 8v4.5l3 2"/>',
    plug: '<path d="M9 7V3M15 7V3M6 7h12v4a6 6 0 0 1-12 0V7ZM12 17v4"/>',
    gear: '<circle cx="12" cy="12" r="3"/><path d="M12 2.5v3M12 18.5v3M2.5 12h3M18.5 12h3M5.3 5.3l2.1 2.1M16.6 16.6l2.1 2.1M5.3 18.7l2.1-2.1M16.6 7.4l2.1-2.1"/>',
    mic: '<rect x="9" y="3" width="6" height="11" rx="3"/><path d="M5.5 11a6.5 6.5 0 0 0 13 0M12 17.5V21"/>',
    speaker: '<path d="M4 9.5h3.5L12 5.5v13l-4.5-4H4v-5Z"/><path d="M15.5 9a4 4 0 0 1 0 6M18 6.5a7.5 7.5 0 0 1 0 11"/>',
    list: '<rect x="3" y="4" width="18" height="16" rx="4"/><path d="M7 9h1M11 9h6M7 15h1M11 15h6"/>',
    clock: '<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
    calendar: '<rect x="3.5" y="5" width="17" height="15" rx="3"/><path d="M3.5 10h17M8 3v4M16 3v4"/>',
    search: '<circle cx="11" cy="11" r="6"/><path d="m20 20-4.5-4.5"/>',
    sidebar: '<rect x="3" y="4" width="18" height="16" rx="3"/><path d="M9 4v16"/>',
    plus: '<path d="M12 5v14M5 12h14"/>',
    chevron: '<path d="m6 9 6 6 6-6"/>',
    check: '<path d="m7 12.5 3.2 3.2L17 9"/>'
  };
  function icon(name, size) {
    return '<svg class="ic" width="' + size + '" height="' + size + '" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">' + ICONS[name] + "</svg>";
  }
  var RIBBON = '<svg width="22" height="14" viewBox="0 0 22 14" aria-hidden="true"><path d="M2 12C5 12 6 2 9.5 2S12 12 15.5 12 18 2 20 2" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round"/></svg>';

  var SIDEBAR_BUDDIES = [
    { id: "cowork", shape: "pebble", name: "Cowork", text: "Runs when you ask" },
    { id: "focus", shape: "drop", name: "Focus", role: "Planner", text: "Runs when you ask" },
    { id: "researcher", shape: "capsule", name: "Researcher", role: "R", time: "1:08 PM", text: "Three good sources on enzyme rates" },
    { id: "inbox", shape: "cloud", name: "Inbox", role: "Inbox", time: "12:18 PM", text: "Two things: Ms. Rivera moved office hours" },
    { id: "writer", shape: "square", name: "Writer", role: "Writer", time: "11:49 AM", text: "Here's a plan to get the essay done" },
    { id: "planner", shape: "circle", name: "Planner", role: "Planner", time: "7:30 AM", text: "Today's checklist is ready" }
  ];

  function sidebarRow(entry) {
    return '<div class="wa-row" data-row="' + entry.id + '">' +
      '<span class="wa-av">' + buddy(entry.shape, 38) + '<span class="wa-ring"></span></span>' +
      '<span class="wa-row-body"><span class="wa-row-top"><b>' + entry.name + "</b>" +
      (entry.role ? '<span class="wa-chip">' + entry.role + "</span>" : "") +
      '<span class="wa-time">' + (entry.time || "") + '</span><span class="wa-unread"></span></span>' +
      '<span class="wa-row-text">' + entry.text + "</span></span></div>";
  }

  var CHECKLIST = [
    { id: "lab", text: "Bio lab report", note: "BIO 201 · due 11:59 PM" },
    { id: "quiz", text: "Spanish quiz", note: "SPAN 102 · 10:00 AM" },
    { id: "study", text: "Study block: lab report results", note: "2:00 – 3:00 PM", isNew: true },
    { id: "read", text: "Read chapter 7", note: "HIST 110 · from yesterday" },
    { id: "soccer", text: "Soccer practice", note: "5:00 PM · North field" }
  ];

  var rail = ["people", "sun", "chat", "bolt", "flow", "cap", "timer", "brain", "spark", "history", "plug"].map(function (name) {
    return '<span class="wa-rail-ic' + (name === "sun" ? " on" : "") + '">' + icon(name, 19) + "</span>";
  }).join("");

  host.innerHTML =
    '<div class="wa">' +
      '<div class="wa-lights"><i></i><i></i><i></i></div>' +
      '<nav class="wa-rail">' + rail + '<span class="wa-rail-ic wa-rail-gear">' + icon("gear", 19) + "</span></nav>" +
      '<aside class="wa-side">' +
        '<span class="wa-new">' + icon("plus", 16) + "</span>" +
        '<div class="wa-search">' + icon("sidebar", 17) + '<span class="wa-field">' + icon("search", 14) + "Search</span></div>" +
        '<div class="wa-group">Pinned <i>1</i>' + icon("chevron", 13) + "</div>" +
        sidebarRow({ id: "briefer", shape: "triangle", name: "Briefer", time: "9:00 AM", text: "Three things today. The lab is due tonight" }) +
        '<div class="wa-group">Buddies <i>6</i>' + icon("chevron", 13) + "</div>" +
        SIDEBAR_BUDDIES.map(sidebarRow).join("") +
        '<div class="wa-side-foot"><b data-foot-state>Ready</b><span>Claude Sonnet 5.5</span></div>' +
      "</aside>" +
      '<section class="wa-main">' +
        '<div class="wa-status">' + RIBBON + '<b data-status>Ready</b><i class="wa-dot"></i><span>Claude Sonnet 5.5</span></div>' +
        '<div class="wa-hero">' +
          '<div class="wa-mascot">' + buddy("drop", 70, "big") + "</div>" +
          '<div class="wa-ask"><span class="wa-mic">' + icon("mic", 17) + '</span><span class="wa-ask-text" data-ask></span><span class="wa-caret"></span><span class="wa-wave"><i></i><i></i><i></i><i></i><i></i></span></div>' +
          "<h3>Good afternoon. What did we learn today?</h3>" +
          '<p class="wa-hint" data-hint>Hold <kbd>ctrl</kbd> <kbd>option</kbd> and tell me what to take off your plate</p>' +
          '<p class="wa-answer" data-answer></p>' +
          '<span class="wa-speaker">' + icon("speaker", 15) + "</span>" +
        "</div>" +
        '<div class="wa-card wa-check">' +
          '<div class="wa-card-head">' + icon("list", 17) + "<b>Today's checklist</b><span data-count></span></div>" +
          CHECKLIST.map(function (item) {
            return '<div class="wa-item' + (item.isNew ? " is-new" : "") + '" data-item="' + item.id + '"><span class="wa-box">' + icon("check", 13) + "</span>" +
              '<span class="wa-item-text">' + item.text + '</span><span class="wa-item-note">' + item.note + "</span></div>";
          }).join("") +
        "</div>" +
        '<div class="wa-grid">' +
          '<div class="wa-card"><div class="wa-card-head">' + icon("people", 17) + '<b>Buddies</b><span class="wa-round">' + icon("plus", 13) + "</span></div>" +
            '<div class="wa-mini">' + buddy("triangle", 30) + "<span><b>Briefer</b>Every day at 9:00 AM</span></div>" +
            '<div class="wa-mini" data-mini-writer>' + buddy("square", 30) + '<span><b>Writer</b><em data-writer-mini>Runs when you ask</em></span></div>' +
            '<div class="wa-mini">' + buddy("pebble", 30) + "<span><b>Cowork</b>Runs when you ask</span></div></div>" +
          '<div class="wa-card"><div class="wa-card-head">' + icon("clock", 17) + "<b>Next up</b></div>" +
            '<div class="wa-mini">' + buddy("circle", 26) + "<span><b>Daily checklist</b>Tomorrow 7:30 AM</span></div>" +
            '<div class="wa-mini">' + buddy("triangle", 26) + "<span><b>Briefer</b>Tomorrow 9:00 AM</span></div>" +
            '<div class="wa-mini">' + buddy("triangle", 26) + "<span><b>Weekly review</b>Sun 6:00 PM</span></div></div>" +
          '<div class="wa-card"><div class="wa-card-head">' + icon("calendar", 17) + "<b>Up next</b></div>" +
            '<div class="wa-event is-new" data-event style="--bar:#5BD38A"><b>Study block: lab report</b>2:00 PM · in 45 min</div>' +
            '<div class="wa-event" style="--bar:#F5A33A"><b>Soccer practice</b>5:00 PM · North field</div>' +
            '<div class="wa-event" style="--bar:#4C8DF6"><b>Group project check-in</b>Tuesday 9:00 AM · Library</div></div>' +
          '<div class="wa-card wa-brain"><div class="wa-card-head">' + icon("brain", 17) + "<b>Brain</b></div>" +
            '<strong data-pages>11</strong><span>pages</span><p data-brain-note>Wisp files lasting facts from your conversations here.</p></div>' +
        "</div>" +
      "</section>" +
    "</div>";

  var poster = host.parentElement.querySelector(".poster");
  if (poster) poster.hidden = true;
  host.parentElement.classList.add("is-live");

  var app = host.firstChild;
  var ask = host.querySelector("[data-ask]");
  var answer = host.querySelector("[data-answer]");
  var status = host.querySelector("[data-status]");
  var footState = host.querySelector("[data-foot-state]");
  var count = host.querySelector("[data-count]");
  var pages = host.querySelector("[data-pages]");
  var brainNote = host.querySelector("[data-brain-note]");
  var writerRow = host.querySelector('[data-row="writer"]');
  var writerText = writerRow.querySelector(".wa-row-text");
  var writerTime = writerRow.querySelector(".wa-time");
  var writerMini = host.querySelector("[data-writer-mini]");
  var quiz = host.querySelector('[data-item="quiz"]');
  var study = host.querySelector('[data-item="study"]');
  var studyEvent = host.querySelector("[data-event]");

  // Keep the window at its design size and scale it to whatever the frame is.
  // zoom lays the text out at its real size, so it stays sharp; transform is the fallback.
  var canZoom = window.CSS && CSS.supports("zoom", "0.5");
  function fit() {
    var scale = host.parentElement.clientWidth / CANVAS_WIDTH;
    if (canZoom) host.style.zoom = String(scale);
    else host.style.transform = "scale(" + scale + ")";
  }
  fit();
  if ("ResizeObserver" in window) new ResizeObserver(fit).observe(host.parentElement);
  else window.addEventListener("resize", fit);

  function between(progress, start, end) { return Math.min(1, Math.max(0, (progress - start) / (end - start))); }
  function setText(element, text) { if (element.textContent !== text) element.textContent = text; }
  function setState(name, isOn) { app.classList.toggle(name, isOn); }

  var lastProgress = -1;
  function setProgress(progress) {
    if (Math.abs(progress - lastProgress) < 0.0005) return;
    lastProgress = progress;

    // 1. Holding ctrl+option: the screen glows and the words come in as you say them.
    var isListening = progress >= 0.04 && progress < 0.3;
    var isThinking = progress >= 0.3 && progress < 0.44;
    var hasAnswered = progress >= 0.44;
    var spokenWords = QUESTION.split(" ");
    var heardWordCount = Math.round(between(progress, 0.07, 0.27) * spokenWords.length);
    setState("is-listening", isListening);
    setState("is-thinking", isThinking);
    setState("is-answered", hasAnswered);
    setText(ask, hasAnswered || progress < 0.07 ? "Hi, how can I help ^_^?" : spokenWords.slice(0, heardWordCount).join(" ") || "Listening…");
    ask.classList.toggle("is-placeholder", hasAnswered || progress < 0.07);

    // 2. The answer replaces the hint, typed out as it streams.
    setText(answer, ANSWER.slice(0, Math.round(between(progress, 0.45, 0.6) * ANSWER.length)));

    // 3. The checklist and calendar change.
    var quizDone = progress >= 0.5;
    var studyAdded = progress >= 0.53;
    quiz.classList.toggle("done", quizDone);
    study.classList.toggle("shown", studyAdded);
    study.classList.toggle("flash", studyAdded && progress < 0.74);
    studyEvent.classList.toggle("shown", progress >= 0.57);
    setText(count, (quizDone ? 1 : 0) + " of " + (studyAdded ? 5 : 4));

    // 4. Writer goes to work, then has something new for you.
    var writerWorking = progress >= 0.6 && progress < 0.84;
    var writerDone = progress >= 0.84;
    writerRow.classList.toggle("working", writerWorking);
    writerRow.classList.toggle("unread", writerDone);
    host.querySelector("[data-mini-writer]").classList.toggle("working", writerWorking);
    setText(writerText, writerDone ? "Your conclusion draft is ready to read" : writerWorking ? "Drafting your conclusion…" : "Here's a plan to get the essay done");
    setText(writerTime, writerDone ? "2:51 PM" : writerWorking ? "" : "11:49 AM");
    setText(writerMini, writerWorking ? "Working…" : writerDone ? "Draft ready" : "Runs when you ask");

    // 5. The brain keeps the deadline.
    var brainUpdated = progress >= 0.9;
    setText(pages, brainUpdated ? "12" : "11");
    setText(brainNote, brainUpdated ? "New: BIO 201 lab report is due tonight at 11:59 PM." : "Wisp files lasting facts from your conversations here.");
    host.querySelector(".wa-brain").classList.toggle("fresh", brainUpdated);

    var stateText = isListening ? "Listening" : isThinking ? "Thinking" : writerWorking ? "Working · 1" : "Ready";
    setText(status, stateText);
    setText(footState, stateText);
  }

  window.WispPreview = { setProgress: setProgress };
  setProgress(0);

  // Without the pinned scroll scene, play the story on a loop while it's on screen.
  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var playsOnItsOwn = reduceMotion || window.matchMedia("(max-width: 900px), (pointer: coarse)").matches;
  if (!playsOnItsOwn) return;
  if (reduceMotion) { setProgress(1); return; }
  var STORY_SECONDS = 12;
  var HOLD_SECONDS = 3;
  var isVisible = false;
  var startedAt = 0;
  function tick(now) {
    if (!isVisible) return;
    if (!startedAt) startedAt = now;
    var seconds = ((now - startedAt) / 1000) % (STORY_SECONDS + HOLD_SECONDS);
    setProgress(Math.min(1, seconds / STORY_SECONDS));
    window.requestAnimationFrame(tick);
  }
  if ("IntersectionObserver" in window) {
    new IntersectionObserver(function (entries) {
      var wasVisible = isVisible;
      isVisible = entries[0].isIntersecting;
      if (isVisible && !wasVisible) window.requestAnimationFrame(tick);
    }, { threshold: 0.3 }).observe(host);
  } else {
    setProgress(1);
  }
})();

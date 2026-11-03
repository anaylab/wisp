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

  var UI = window.WispUI;
  var buddy = UI.buddy, icon = UI.icon, RIBBON = UI.RIBBON, sidebarRow = UI.sidebarRow;

  var SIDEBAR_BUDDIES = [
    { id: "cowork", shape: "pebble", name: "Cowork", text: "Runs when you ask" },
    { id: "focus", shape: "drop", name: "Focus", role: "Planner", text: "Runs when you ask" },
    { id: "researcher", shape: "capsule", name: "Researcher", role: "R", time: "1:08 PM", text: "Three good sources on enzyme rates" },
    { id: "inbox", shape: "cloud", name: "Inbox", role: "Inbox", time: "12:18 PM", text: "Two things: Ms. Rivera moved office hours" },
    { id: "writer", shape: "square", name: "Writer", role: "Writer", time: "11:49 AM", text: "Here's a plan to get the essay done" },
    { id: "planner", shape: "circle", name: "Planner", role: "Planner", time: "7:30 AM", text: "Today's checklist is ready" }
  ];

  var CHECKLIST = [
    { id: "lab", text: "Bio lab report", note: "BIO 201 · due 11:59 PM" },
    { id: "quiz", text: "Spanish quiz", note: "SPAN 102 · 10:00 AM" },
    { id: "study", text: "Study block: lab report results", note: "2:00 – 3:00 PM", isNew: true },
    { id: "read", text: "Read chapter 7", note: "HIST 110 · from yesterday" },
    { id: "soccer", text: "Soccer practice", note: "5:00 PM · North field" }
  ];

  host.innerHTML =
    '<div class="wa">' +
      '<div class="wa-lights"><i></i><i></i><i></i></div>' +
      '<nav class="wa-rail">' + UI.rail("sun") + "</nav>" +
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
      '<div class="wa-island" data-island>' +
        '<span class="wa-notch"></span>' +
        '<span class="wa-flank wa-flank-left">' + RIBBON + "</span>" +
        '<span class="wa-flank wa-flank-right"><span class="wa-wave"><i></i><i></i><i></i><i></i><i></i></span><span class="wa-dots"><i></i><i></i><i></i></span></span>' +
        '<div class="wa-island-card wa-approve">' +
          '<p class="wa-island-kicker">' + RIBBON + "Wisp needs your OK</p>" +
          "<p><b>Add to Calendar</b><br>Study block: lab report · Today 2:00 – 3:00 PM</p>" +
          '<div class="wa-island-buttons"><span>Cancel</span><span class="wa-allow">Allow</span></div>' +
        "</div>" +
        '<div class="wa-island-card wa-reply">' +
          '<p class="wa-island-kicker">' + RIBBON + "Wisp</p>" +
          "<p>Study block added for 2 PM. Writer is drafting your conclusion.</p>" +
        "</div>" +
      "</div>" +
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
  var island = host.querySelector("[data-island]");

  UI.fitCanvas(host, CANVAS_WIDTH);

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

    // The notch island: wraps the notch while listening and thinking, asks before writing
    // to the calendar (Allow is pressed), shows a short reply, then tucks away.
    var islandState = isListening ? "listening" : isThinking ? "thinking" :
      progress >= 0.44 && progress < 0.53 ? "approve" : progress >= 0.53 && progress < 0.68 ? "reply" : "idle";
    if (island.dataset.state !== islandState) island.dataset.state = islandState;
    island.classList.toggle("allowed", progress >= 0.5);

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

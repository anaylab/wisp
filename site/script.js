// Hero stage: a tab strip that swaps the real captures and types the matching request into the notch.
(function () {
  var scenes = [
    { prompt: "Draft an email to Sam about moving Friday's review", src: "assets/shots/feature-email.jpg", alt: "An editable email draft with Send and Discard", cap: "A finished draft to the right person. Nothing is sent until you press Send." },
    { prompt: "Every weekday at 8, tell me what's due", src: "assets/shots/buddy-handoff.jpg", alt: "The Briefer's morning brief, its daily schedule and its hand-off to the Writer", cap: "Say it once. A buddy does it on schedule, and hands its answer on." },
    { prompt: "Open Wikipedia and search for the Enigma machine", src: "assets/shots/feature-browser.jpg", alt: "Chrome on the Enigma machine article", cap: "Your real browser, in its own tab, and an honest summary of where it landed." },
    { prompt: "Put Dictionary on the left and TextEdit on the right", src: "assets/shots/feature-windows.jpg", alt: "Two windows tiled side by side", cap: "Windows tiled by voice, with no model call." },
    { prompt: "Walk me through making this bold and centered", src: "assets/shots/feature-walkthrough.jpg", alt: "A numbered checklist in the notch and a box on the Bold button", cap: "Steps on your real screen, ticked off as you go. Or let Wisp click." },
    { prompt: "Solve this, step by step", src: "assets/shots/feature-math.jpg", alt: "Handwritten working beside 3x + 7 = 22, ending in x = 5", cap: "The working, written on the page one line at a time." }
  ];

  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var img = document.getElementById("stage-img");
  var cap = document.getElementById("stage-cap");
  var notchText = document.getElementById("notch-text");
  var tabs = Array.prototype.slice.call(document.querySelectorAll(".stage-tabs button"));
  var stage = document.getElementById("stage");
  if (!img || !tabs.length) return;

  var current = 0, typeTimer = null, rotateTimer = null, paused = false;

  function typeInto(text) {
    clearInterval(typeTimer);
    if (reduceMotion) { notchText.textContent = text; return; }
    var n = 0;
    notchText.textContent = "";
    typeTimer = setInterval(function () {
      n += 1;
      notchText.textContent = text.slice(0, n);
      if (n >= text.length) clearInterval(typeTimer);
    }, 28);
  }

  function show(i) {
    current = i;
    var s = scenes[i];
    tabs.forEach(function (t, k) {
      t.setAttribute("aria-selected", k === i ? "true" : "false");
      t.tabIndex = k === i ? 0 : -1;
    });
    img.style.opacity = "0";
    window.setTimeout(function () {
      img.src = s.src;
      img.alt = s.alt;
      cap.textContent = s.cap;
      img.style.opacity = "1";
    }, reduceMotion ? 0 : 160);
    typeInto(s.prompt);
  }

  function schedule() {
    clearInterval(rotateTimer);
    if (reduceMotion) return;
    rotateTimer = setInterval(function () {
      if (!paused) show((current + 1) % scenes.length);
    }, 7000);
  }

  tabs.forEach(function (tab, k) {
    tab.addEventListener("click", function () { show(k); schedule(); });
    tab.addEventListener("keydown", function (e) {
      var next = null;
      if (e.key === "ArrowRight") next = (k + 1) % tabs.length;
      if (e.key === "ArrowLeft") next = (k - 1 + tabs.length) % tabs.length;
      if (next === null) return;
      e.preventDefault();
      tabs[next].focus();
      show(next);
      schedule();
    });
  });

  stage.addEventListener("mouseenter", function () { paused = true; });
  stage.addEventListener("mouseleave", function () { paused = false; });
  stage.addEventListener("focusin", function () { paused = true; });
  stage.addEventListener("focusout", function () { paused = false; });

  // Warm the remaining captures so tab switches are instant.
  scenes.slice(1).forEach(function (s) { var p = new Image(); p.src = s.src; });

  tabs.forEach(function (t, k) { t.tabIndex = k === 0 ? 0 : -1; });
  typeInto(scenes[0].prompt);
  schedule();
})();

// Copy button for the install commands.
(function () {
  var button = document.getElementById("copy");
  var code = document.getElementById("code");
  if (!button || !code) return;
  button.addEventListener("click", function () {
    var text = code.innerText;
    var done = function () {
      button.textContent = "Copied";
      window.setTimeout(function () { button.textContent = "Copy"; }, 1600);
    };
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(done, done);
    } else {
      done();
    }
  });
})();

// A day with Wisp: the chapter in the middle of the screen picks the frame on the right,
// a clip plays while its chapter is showing, and the bar fills as you scroll the day.
(function () {
  var chapters = Array.prototype.slice.call(document.querySelectorAll(".chapter"));
  var shots = Array.prototype.slice.call(document.querySelectorAll(".story-shot"));
  var list = document.querySelector(".chapters");
  var fill = document.getElementById("story-progress-fill");
  if (!chapters.length || !shots.length) return;
  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  function videoFor(shot) {
    var existing = shot.querySelector("video");
    if (existing || !shot.dataset.video) return existing;
    var video = document.createElement("video");
    video.muted = true; video.loop = true; video.playsInline = true; video.preload = "auto";
    video.setAttribute("aria-hidden", "true");
    video.src = shot.dataset.video;
    video.addEventListener("error", function () { video.remove(); });
    shot.appendChild(video);
    return video;
  }

  function activate(index) {
    chapters.forEach(function (c, k) { c.classList.toggle("is-active", k === index); });
    shots.forEach(function (shot, k) {
      var isActive = k === index;
      shot.classList.toggle("is-active", isActive);
      var video = isActive && !reduceMotion ? videoFor(shot) : shot.querySelector("video");
      if (!video) return;
      if (isActive && !reduceMotion) { video.currentTime = 0; video.play().catch(function () {}); }
      else video.pause();
    });
  }

  var activeIndex = 0;
  var ticking = false;
  function updateProgress() {
    ticking = false;
    var middle = window.innerHeight / 2;
    // The chapter whose middle is nearest the middle of the screen is the one showing.
    var nearestIndex = activeIndex, nearestDistance = Infinity;
    chapters.forEach(function (c, k) {
      var box = c.getBoundingClientRect();
      var distance = Math.abs(box.top + box.height / 2 - middle);
      if (distance < nearestDistance) { nearestDistance = distance; nearestIndex = k; }
    });
    if (nearestIndex !== activeIndex) { activeIndex = nearestIndex; activate(activeIndex); }
    if (!fill || !list) return;
    var listBox = list.getBoundingClientRect();
    var done = (middle - listBox.top) / listBox.height;
    fill.style.width = (Math.max(0, Math.min(1, done)) * 100).toFixed(1) + "%";
  }
  window.addEventListener("scroll", function () {
    if (!ticking) { ticking = true; window.requestAnimationFrame(updateProgress); }
  }, { passive: true });
  // The first chapter is showing before any scroll, so start its clip now.
  activate(activeIndex);
  updateProgress();
})();

// Sections rise in as they arrive; the feature cards follow one another.
(function () {
  var items = Array.prototype.slice.call(document.querySelectorAll(".reveal"));
  if (!("IntersectionObserver" in window)) { items.forEach(function (el) { el.classList.add("is-in"); }); return; }
  document.querySelectorAll(".cat-card").forEach(function (card, k) { card.style.setProperty("--reveal-order", k % 4); });
  var observer = new IntersectionObserver(function (entries) {
    entries.forEach(function (entry) {
      if (!entry.isIntersecting) return;
      entry.target.classList.add("is-in");
      observer.unobserve(entry.target);
    });
  }, { rootMargin: "0px 0px -8% 0px" });
  items.forEach(function (el) { observer.observe(el); });
})();

// Feature filters, and a soft glow that follows the pointer over a card.
(function () {
  var buttons = Array.prototype.slice.call(document.querySelectorAll(".filters button"));
  var cards = Array.prototype.slice.call(document.querySelectorAll(".cat-card"));
  var grid = document.getElementById("cat-grid");
  buttons.forEach(function (button) {
    button.addEventListener("click", function () {
      var filter = button.dataset.filter;
      buttons.forEach(function (b) { b.setAttribute("aria-pressed", b === button ? "true" : "false"); });
      cards.forEach(function (card) {
        card.hidden = filter !== "all" && card.dataset.cat !== filter;
        card.classList.add("is-in");
      });
    });
  });
  if (!grid) return;
  grid.addEventListener("pointermove", function (event) {
    var card = event.target.closest(".cat-card");
    if (!card) return;
    var box = card.getBoundingClientRect();
    card.style.setProperty("--glow-x", (event.clientX - box.left) + "px");
    card.style.setProperty("--glow-y", (event.clientY - box.top) + "px");
  });
})();

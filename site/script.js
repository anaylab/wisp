// Hero stage: a tab strip that swaps the real captures and types the matching request into the notch.
(function () {
  var scenes = [
    { prompt: "Where is the pi button?", src: "assets/shots/feature-pointing.jpg", alt: "A labelled marker on the pi button in Calculator", cap: "A marker lands on the exact control in about a tenth of a second." },
    { prompt: "Walk me through making this bold and centered", src: "assets/shots/feature-walkthrough.jpg", alt: "A numbered checklist in the notch and a box on the Bold button", cap: "Numbered steps on your real screen, one boxed control at a time." },
    { prompt: "Solve this, step by step", src: "assets/shots/feature-math.jpg", alt: "Handwritten working beside 3x + 7 = 22, ending in x = 5", cap: "Handwritten working on the page, one line at a time." },
    { prompt: "Put Dictionary on the left and TextEdit on the right", src: "assets/shots/feature-windows.jpg", alt: "Two windows tiled side by side", cap: "Windows tiled by voice, with no model call." },
    { prompt: "Open Wikipedia and search for the Enigma machine", src: "assets/shots/feature-browser.jpg", alt: "Chrome on the Enigma machine article", cap: "Your real browser, in its own tab, and an honest summary of where it landed." },
    { prompt: "Draft an email about moving Friday's review", src: "assets/shots/feature-email.jpg", alt: "An editable email draft with Send and Discard", cap: "An editable draft. Nothing is sent until you press Send." }
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

// Scroll-driven scenes. Each pinned scene turns the scroll position into a 0–1 progress
// value; that value is eased toward its target every frame, so motion follows through after
// the wheel stops, and the clips are scrubbed to it instead of playing on their own.
// Phones, coarse pointers and Reduce Motion get a flat page with the same content.
(function () {
  var root = document.documentElement;
  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var smallOrTouch = window.matchMedia("(max-width: 900px), (pointer: coarse)").matches;
  var isFlat = reduceMotion || smallOrTouch;
  if (isFlat) root.classList.add("flat");

  function clamp(value, low, high) { return Math.min(high, Math.max(low, value)); }
  function mix(from, to, amount) { return from + (to - from) * amount; }
  function easeOut(amount) { return 1 - Math.pow(1 - amount, 3); }

  // Clips show their first frame as an image until the video can paint.
  var videos = Array.prototype.slice.call(document.querySelectorAll("video[data-scrub]"));
  videos.forEach(function (video) {
    video.addEventListener("loadeddata", function () { video.classList.add("ready"); }, { once: true });
    video.addEventListener("error", function () { video.remove(); }, { once: true });
  });

  // The reel's clips play while their card is mostly on screen, in either layout.
  var flowVideos = Array.prototype.slice.call(document.querySelectorAll("video[data-flow]"));
  if (!reduceMotion && "IntersectionObserver" in window) {
    var flowObserver = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        var video = entry.target;
        if (entry.isIntersecting) {
          // Starting playback is what loads the clip, so nothing downloads before it's needed.
          video.play().catch(function () {});
        } else {
          video.pause();
        }
      });
    }, { threshold: 0.6 });
    flowVideos.forEach(function (video) {
      video.addEventListener("playing", function () { video.classList.add("ready"); }, { once: true });
      flowObserver.observe(video);
    });
  }

  function scrub(video, seconds) {
    if (!video.duration || video.readyState < 1 || video.seeking) return;
    var target = clamp(seconds, 0, video.duration - 0.05);
    if (Math.abs(video.currentTime - target) > 0.015) video.currentTime = target;
  }

  if (isFlat) {
    // No scrubbing: clips play while on screen, unless motion is reduced (then posters stay).
    if (!reduceMotion && "IntersectionObserver" in window) {
      var playObserver = new IntersectionObserver(function (entries) {
        entries.forEach(function (entry) {
          var video = entry.target;
          if (entry.isIntersecting) { video.loop = true; video.play().catch(function () {}); }
          else video.pause();
        });
      }, { threshold: 0.4 });
      videos.forEach(function (video) { playObserver.observe(video); });
    }
    return;
  }

  // Split the statement into words that light up one by one.
  var wordsHost = document.querySelector("[data-words]");
  var words = [];
  if (wordsHost) {
    wordsHost.innerHTML = wordsHost.textContent.trim().split(/\s+/).map(function (word) {
      return '<span class="w">' + word + "</span>";
    }).join(" ");
    words = Array.prototype.slice.call(wordsHost.querySelectorAll(".w"));
  }

  var heroCopy = document.querySelector("[data-hero-copy]");
  var heroDevice = document.querySelector("[data-hero-device]");
  var nav = document.querySelector(".nav");
  var cinema = document.querySelector(".cinema");
  var reelTrack = document.querySelector("[data-track]");
  var pipeline = document.querySelector("[data-pipeline]");
  var pipeFill = document.querySelector("[data-pipe-fill]");

  var scenes = Array.prototype.slice.call(document.querySelectorAll("[data-scene]")).map(function (element) {
    return {
      element: element,
      kind: element.dataset.scene,
      video: element.querySelector("video[data-scrub]"),
      device: element.querySelector(".device.dark"),
      bar: element.querySelector("[data-bar]"),
      clock: element.querySelector("[data-clock]"),
      captions: Array.prototype.slice.call(element.querySelectorAll("[data-captions] li")),
      top: 0, height: 0, target: 0, eased: 0, activeCaption: -1, litWords: -1
    };
  });

  var viewportHeight = window.innerHeight;
  var reelOverflow = 0;

  function measure() {
    viewportHeight = window.innerHeight;
    if (reelTrack) {
      var reelScene = reelTrack.closest("[data-scene]");
      reelOverflow = Math.max(0, reelTrack.scrollWidth - window.innerWidth + 40);
      // One pixel of scroll moves the reel one pixel, with a little room either side.
      reelScene.style.height = (viewportHeight + reelOverflow + viewportHeight * 0.6) + "px";
    }
    scenes.forEach(function (scene) {
      var box = scene.element.getBoundingClientRect();
      scene.top = box.top + window.scrollY;
      scene.height = scene.element.offsetHeight;
    });
  }

  function readTargets() {
    var scrollTop = window.scrollY;
    scenes.forEach(function (scene) {
      var travel = Math.max(1, scene.height - viewportHeight);
      scene.target = clamp((scrollTop - scene.top) / travel, 0, 1);
    });
  }

  function render(scene) {
    var progress = scene.eased;
    if (scene.kind === "hero") {
      var copyFade = clamp(progress / 0.22, 0, 1);
      heroCopy.style.opacity = String(1 - copyFade);
      heroCopy.style.transform = "translateY(" + (-progress * 260).toFixed(1) + "px) scale(" + (1 - copyFade * 0.04).toFixed(3) + ")";
      var rise = easeOut(clamp(progress / 0.38, 0, 1));
      var deviceHeight = heroDevice.offsetHeight;
      var startY = viewportHeight * 0.64;
      var endY = Math.max(72, (viewportHeight - deviceHeight) / 2 + 18);
      heroDevice.style.transform = "translate(-50%, " + mix(startY, endY, rise).toFixed(1) + "px) perspective(1800px) rotateX(" +
        mix(16, 0, rise).toFixed(2) + "deg) scale(" + mix(0.86, 1, rise).toFixed(3) + ")";
      if (scene.video) scrub(scene.video, clamp((progress - 0.12) / 0.86, 0, 1) * scene.video.duration);
    } else if (scene.kind === "words") {
      var lit = Math.round(clamp((progress - 0.08) / 0.78, 0, 1) * words.length);
      if (lit !== scene.litWords) {
        words.forEach(function (word, index) { word.classList.toggle("lit", index < lit); });
        scene.litWords = lit;
      }
    } else if (scene.kind === "film") {
      if (scene.bar) scene.bar.style.transform = "scaleX(" + progress.toFixed(4) + ")";
      if (scene.device) {
        var arrive = easeOut(clamp(progress / 0.12, 0, 1));
        scene.device.style.transform = "scale(" + mix(0.92, 1, arrive).toFixed(3) + ")";
      }
      if (scene.video) scrub(scene.video, clamp(progress / 0.96, 0, 1) * scene.video.duration);
      var active = 0;
      scene.captions.forEach(function (caption, index) {
        if (progress >= parseFloat(caption.dataset.at)) active = index;
      });
      if (active !== scene.activeCaption) {
        scene.captions.forEach(function (caption, index) { caption.classList.toggle("on", index === active); });
        if (scene.clock) scene.clock.textContent = scene.captions[active].dataset.clockText;
        scene.activeCaption = active;
      }
    } else if (scene.kind === "reel") {
      var travelled = clamp((progress - 0.08) / 0.84, 0, 1);
      reelTrack.style.transform = "translate3d(" + (-travelled * reelOverflow).toFixed(1) + "px, 0, 0)";
    }
  }

  function renderPage() {
    if (nav && cinema) {
      var cinemaBox = cinema.getBoundingClientRect();
      nav.classList.toggle("on-dark", cinemaBox.top <= 56 && cinemaBox.bottom > 56);
    }
    if (pipeline && pipeFill) {
      var pipeBox = pipeline.getBoundingClientRect();
      var drawn = clamp((viewportHeight * 0.85 - pipeBox.top) / (viewportHeight * 0.45), 0, 1);
      pipeFill.style.transform = "scaleX(" + drawn.toFixed(3) + ")";
    }
  }

  var running = false;
  var lastFrame = 0;
  function frame(now) {
    var elapsed = lastFrame ? Math.min(64, now - lastFrame) : 16.7;
    lastFrame = now;
    // About 12% of the remaining distance per 60 Hz frame, the same at any refresh rate.
    var follow = 1 - Math.pow(1 - 0.12, elapsed / 16.7);
    readTargets();
    var settled = true;
    scenes.forEach(function (scene) {
      var gap = scene.target - scene.eased;
      if (Math.abs(gap) > 0.0004) { scene.eased += gap * follow; settled = false; }
      else scene.eased = scene.target;
      render(scene);
    });
    renderPage();
    if (settled) { running = false; lastFrame = 0; return; }
    window.requestAnimationFrame(frame);
  }
  function wake() {
    if (running) return;
    running = true;
    window.requestAnimationFrame(frame);
  }

  measure();
  readTargets();
  scenes.forEach(function (scene) { scene.eased = scene.target; render(scene); });
  renderPage();
  window.addEventListener("scroll", wake, { passive: true });
  window.addEventListener("resize", function () { measure(); wake(); });
  window.addEventListener("load", function () { measure(); wake(); });
  // A clip that finishes loading late still needs drawing at the current position.
  videos.forEach(function (video) { video.addEventListener("loadedmetadata", wake); });
})();

// Sections rise in as they arrive; counters run up once.
(function () {
  var items = Array.prototype.slice.call(document.querySelectorAll(".reveal"));
  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  function countUp(element) {
    var goal = parseInt(element.dataset.count, 10);
    if (!goal || reduceMotion) return;
    var start = performance.now();
    function step(now) {
      var amount = Math.min(1, (now - start) / 1200);
      element.textContent = String(Math.round(goal * (1 - Math.pow(1 - amount, 3))));
      if (amount < 1) window.requestAnimationFrame(step);
    }
    element.textContent = "0";
    window.requestAnimationFrame(step);
  }
  if (!("IntersectionObserver" in window)) { items.forEach(function (el) { el.classList.add("is-in"); }); return; }
  var observer = new IntersectionObserver(function (entries) {
    entries.forEach(function (entry) {
      if (!entry.isIntersecting) return;
      entry.target.classList.add("is-in");
      entry.target.querySelectorAll("[data-count]").forEach(countUp);
      observer.unobserve(entry.target);
    });
  }, { rootMargin: "0px 0px -10% 0px" });
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
      cards.forEach(function (card) { card.hidden = filter !== "all" && card.dataset.cat !== filter; });
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

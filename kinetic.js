// Kinetic type. Headlines are split into letters that rise in one by one and lean toward the
// pointer; the hero's last word cycles; a giant band of type slides with the scroll.
// Reduce Motion leaves every heading as plain text.
(function () {
  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  if (reduceMotion) return;
  var finePointer = window.matchMedia("(hover: hover) and (pointer: fine)").matches;
  function clamp(value, low, high) { return Math.min(high, Math.max(low, value)); }

  // Wraps every letter of an element's text (skipping <br> and the cycling word) in
  // .k-w (a word, so lines break between words) > .k-ch (rises in) > i (reacts to the pointer).
  function splitLetters(root, startIndex) {
    var index = startIndex || 0;
    var letters = [];
    function walk(node) {
      Array.prototype.slice.call(node.childNodes).forEach(function (child) {
        if (child.nodeType === 3) {
          var fragment = document.createDocumentFragment();
          child.textContent.split(/(\s+)/).forEach(function (part) {
            if (!part) return;
            if (/^\s+$/.test(part)) { fragment.appendChild(document.createTextNode(" ")); return; }
            var word = document.createElement("span");
            word.className = "k-w";
            word.setAttribute("aria-hidden", "true");
            Array.from(part).forEach(function (character) {
              var outer = document.createElement("span");
              outer.className = "k-ch";
              outer.style.setProperty("--i", String(index++));
              var inner = document.createElement("i");
              inner.textContent = character;
              outer.appendChild(inner);
              word.appendChild(outer);
              letters.push(outer);
            });
            fragment.appendChild(word);
          });
          node.replaceChild(fragment, child);
        } else if (child.nodeType === 1 && child.tagName !== "BR" && !child.classList.contains("k-rot")) {
          walk(child);
        }
      });
    }
    walk(root);
    return letters;
  }

  // Spreads the lavender, teal and pink gradient across an emphasised word, letter by letter.
  var stops = [[194, 182, 255], [127, 230, 217], [255, 195, 223]];
  function paint(letters) {
    letters.forEach(function (letter, position) {
      var amount = letters.length > 1 ? position / (letters.length - 1) : 0;
      var scaled = amount * (stops.length - 1);
      var low = Math.min(stops.length - 2, Math.floor(scaled));
      var blend = scaled - low;
      var rgb = stops[low].map(function (channel, k) { return Math.round(channel + (stops[low + 1][k] - channel) * blend); });
      letter.firstChild.style.color = "rgb(" + rgb.join(",") + ")";
    });
  }

  var headings = Array.prototype.slice.call(document.querySelectorAll(".hero h1, .section-head h2, .reel-head h2, .get h2, .closing h2"));
  var split = headings.map(function (heading) {
    heading.setAttribute("aria-label", heading.textContent.replace(/\s+/g, " ").trim());
    var letters = splitLetters(heading, 0);
    Array.prototype.slice.call(heading.querySelectorAll("em")).forEach(function (emphasis) {
      emphasis.classList.add("k-split");
      paint(Array.prototype.slice.call(emphasis.querySelectorAll(".k-ch")));
    });
    return { heading: heading, letters: letters };
  });

  // Letters rise when their heading arrives; the hero's go as soon as the fonts are ready.
  function start(heading) { heading.classList.add("k-on"); }
  var hero = document.querySelector(".hero h1");
  var ready = document.fonts && document.fonts.ready ? document.fonts.ready : Promise.resolve();
  ready.then(function () { window.setTimeout(function () { if (hero) start(hero); }, 120); });
  if ("IntersectionObserver" in window) {
    var observer = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        start(entry.target);
        observer.unobserve(entry.target);
      });
    }, { threshold: 0.4 });
    headings.forEach(function (heading) { if (heading !== hero) observer.observe(heading); });
  } else {
    headings.forEach(start);
  }

  // The hero's last word: a new word wipes in every few seconds.
  var rotator = document.querySelector(".k-rot");
  if (rotator) {
    var words = rotator.dataset.words.split(",");
    rotator.textContent = "";
    var wordElements = words.map(function (word, position) {
      var holder = document.createElement("span");
      holder.className = "k-rot-w" + (position === 0 ? " is-on" : "");
      holder.textContent = word;
      var letters = splitLetters(holder, 0);
      holder.setAttribute("aria-hidden", "true");
      rotator.appendChild(holder);
      return { holder: holder, letters: letters };
    });
    var shown = 0;
    function widthOf(holder) { return holder.offsetWidth; }
    function sizeTo(position) { rotator.style.width = Math.ceil(widthOf(wordElements[position].holder)) + "px"; }
    ready.then(function () { sizeTo(0); });
    window.addEventListener("resize", function () { sizeTo(shown); });
    window.setInterval(function () {
      if (document.hidden) return;
      var leaving = wordElements[shown];
      shown = (shown + 1) % wordElements.length;
      var arriving = wordElements[shown];
      leaving.holder.classList.remove("is-on");
      leaving.holder.classList.add("is-off");
      arriving.holder.classList.add("is-on");
      sizeTo(shown);
      // Once it has gone, put the old word back below without animating it there.
      window.setTimeout(function () {
        leaving.holder.classList.add("k-reset");
        leaving.holder.classList.remove("is-off");
        void leaving.holder.offsetWidth;
        leaving.holder.classList.remove("k-reset");
      }, 1400);
    }, 2800);
  }

  // Letters near the pointer lift, swell and glow, for headings that are on screen.
  if (finePointer) {
    var pointerX = -9999, pointerY = -9999, queued = false;
    var reach = 150;
    function update() {
      queued = false;
      split.forEach(function (entry) {
        var box = entry.heading.getBoundingClientRect();
        if (box.bottom < -reach || box.top > window.innerHeight + reach) return;
        if (!entry.heading.classList.contains("k-on")) return;
        entry.letters.forEach(function (letter) {
          var rect = letter.getBoundingClientRect();
          var distance = Math.hypot(rect.left + rect.width / 2 - pointerX, rect.top + rect.height / 2 - pointerY);
          var closeness = clamp(1 - distance / reach, 0, 1);
          letter.firstChild.style.setProperty("--d", (closeness * closeness).toFixed(3));
        });
      });
    }
    window.addEventListener("pointermove", function (event) {
      pointerX = event.clientX; pointerY = event.clientY;
      if (!queued) { queued = true; window.requestAnimationFrame(update); }
    }, { passive: true });
    document.addEventListener("pointerleave", function () {
      pointerX = pointerY = -9999;
      window.requestAnimationFrame(update);
    });
  }

  // The giant band: each row slides with scroll, in opposite directions, and skews with speed.
  var rows = Array.prototype.slice.call(document.querySelectorAll(".k-row"));
  if (rows.length) {
    var lastScroll = window.scrollY, speed = 0, travel = 0, running = false;
    function tick() {
      var now = window.scrollY;
      var delta = now - lastScroll;
      lastScroll = now;
      speed += (delta - speed) * 0.12;
      travel += delta;
      rows.forEach(function (row) {
        var width = row.firstElementChild.getBoundingClientRect().width * row.children.length / 2;
        var direction = row.dataset.dir === "1" ? 1 : -1;
        var offset = (travel * 0.45 * direction) % width;
        if (direction < 0) offset -= 0; else offset -= width;
        row.style.transform = "translate3d(" + offset.toFixed(1) + "px,0,0) skewX(" + clamp(-speed * 0.18, -14, 14).toFixed(2) + "deg)";
      });
      if (Math.abs(speed) > 0.05) window.requestAnimationFrame(tick); else running = false;
    }
    function wake() { if (!running) { running = true; lastScroll = window.scrollY; window.requestAnimationFrame(tick); } }
    window.addEventListener("scroll", wake, { passive: true });
    tick();
  }
})();

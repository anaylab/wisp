// Interactive diagrams. Each one works with a mouse, a finger or the keyboard, plays itself
// while it is on screen until you take over, and stands still under Reduce Motion.
(function () {
  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var SVG_NS = "http://www.w3.org/2000/svg";

  function make(name, attributes, parent) {
    var element = document.createElementNS(SVG_NS, name);
    Object.keys(attributes || {}).forEach(function (key) { element.setAttribute(key, attributes[key]); });
    if (parent) parent.appendChild(element);
    return element;
  }

  // Calls start/stop as the element enters and leaves the viewport.
  function whileVisible(element, start, stop) {
    if (!("IntersectionObserver" in window)) { start(); return; }
    new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) { if (entry.isIntersecting) start(); else stop(); });
    }, { threshold: 0.35 }).observe(element);
  }

  // ---------- 1. How it works: the notch changes shape through three steps ----------
  (function howStage() {
    var stage = document.querySelector("[data-how-stage]");
    var steps = Array.prototype.slice.call(document.querySelectorAll(".how-step[data-step]"));
    if (!stage || !steps.length) return;
    var order = steps.map(function (step) { return step.dataset.step; });
    var dwell = 5200;
    var current = -1;
    var timer = 0;
    var paused = false;
    var userChose = false;

    function show(index) {
      current = index;
      stage.setAttribute("data-state", order[index]);
      steps.forEach(function (step, position) {
        step.classList.toggle("is-active", position === index);
        step.classList.remove("is-timing");
      });
      // Reading offsetWidth restarts the progress animation.
      void steps[index].offsetWidth;
      if (!reduceMotion && !userChose) {
        steps[index].style.setProperty("--dwell", dwell + "ms");
        steps[index].classList.add("is-timing");
      }
    }
    function schedule() {
      window.clearTimeout(timer);
      if (reduceMotion || userChose || paused) return;
      timer = window.setTimeout(function () { show((current + 1) % order.length); schedule(); }, dwell);
    }
    steps.forEach(function (step, index) {
      step.setAttribute("tabindex", "0");
      step.setAttribute("role", "button");
      function choose() { userChose = true; show(index); window.clearTimeout(timer); }
      step.addEventListener("click", choose);
      step.addEventListener("keydown", function (event) {
        if (event.key === "Enter" || event.key === " ") { event.preventDefault(); choose(); }
      });
    });
    show(0);
    whileVisible(stage, function () { paused = false; schedule(); }, function () { paused = true; window.clearTimeout(timer); });
  })();

  // ---------- 2. The buddy team as a living graph ----------
  (function buddyNetwork() {
    var host = document.querySelector("[data-net]");
    if (!host) return;
    var captionHost = document.querySelector("[data-net-caption]");

    var nodes = {
      calendar: { x: 110, y: 80, kind: "source", name: "Calendar", sub: "", title: "Your calendar", text: "Read on your Mac. Wisp only ever writes to its own “Wisp” calendar." },
      mail: { x: 110, y: 200, kind: "source", name: "Mail", sub: "", title: "Your mail", text: "Read from Mail.app on your Mac, and only after you switch the Inbox on." },
      canvas: { x: 110, y: 340, kind: "source", name: "Canvas feed", sub: "", title: "Your Canvas feed", text: "Fetched every hour with no model call. The link lives in your Keychain." },
      briefer: { x: 400, y: 140, kind: "buddy", name: "Briefer", sub: "9:00 every day", title: "The Briefer", text: "Reads the calendar and mail each morning and writes three lines on what matters. Then it hands the brief on." },
      planner: { x: 400, y: 320, kind: "buddy", name: "Planner", sub: "Every hour", title: "The Planner", text: "Syncs Canvas into a calendar of its own and builds today's checklist, rolling unfinished items over." },
      writer: { x: 680, y: 230, kind: "buddy", name: "Writer", sub: "Waits for both", title: "The Writer", text: "Gets the brief and the deadlines in one message, then turns them into a plan that fits around your day." },
      you: { x: 880, y: 230, kind: "you", name: "You", sub: "Approve", title: "And then you.", text: "Anything that sends, deletes or pays stops at an approval card first. Everything else stays quiet." }
    };
    var edges = [
      ["calendar", "briefer"], ["mail", "briefer"], ["canvas", "planner"],
      ["briefer", "writer"], ["planner", "writer"], ["writer", "you"]
    ];
    var tour = ["briefer", "writer", "you", "planner"];

    var svg = make("svg", { viewBox: "0 0 980 420", role: "group", "aria-label": "How buddies hand work to each other" }, host);
    var edgeLayer = make("g", {}, svg);
    var nodeLayer = make("g", {}, svg);

    function halfWidth(node) { return node.kind === "buddy" ? 80 : node.kind === "you" ? 40 : 62; }
    var edgeGroups = edges.map(function (pair, index) {
      var from = nodes[pair[0]], to = nodes[pair[1]];
      var startX = from.x + halfWidth(from), endX = to.x - halfWidth(to);
      var bend = (endX - startX) * 0.55;
      var path = "M" + startX + " " + from.y + " C" + (startX + bend) + " " + from.y + " " + (endX - bend) + " " + to.y + " " + endX + " " + to.y;
      var group = make("g", { "class": "edge-g" }, edgeLayer);
      make("path", { d: path, "class": "edge" }, group);
      if (!reduceMotion) {
        [0, 1].forEach(function (copy) {
          var dot = make("circle", { r: 4, "class": "pulse" }, group);
          make("animateMotion", { dur: "2.6s", repeatCount: "indefinite", begin: (-copy * 1.3 - index * 0.2) + "s", path: path }, dot);
        });
      }
      return { group: group, line: group.firstChild, from: pair[0], to: pair[1] };
    });

    var nodeElements = {};
    Object.keys(nodes).forEach(function (id) {
      var node = nodes[id];
      var group = make("g", { "class": "node " + node.kind, tabindex: 0, role: "button", "aria-label": node.title, transform: "translate(" + node.x + " " + node.y + ")" }, nodeLayer);
      var inner = make("g", { "class": "node-in" }, group);
      if (node.kind === "you") {
        make("circle", { r: 40, "class": "body" }, inner);
        make("text", { "class": "name", "text-anchor": "middle", y: 2 }, inner).textContent = node.name;
        make("text", { "class": "sub", "text-anchor": "middle", y: 22 }, inner).textContent = node.sub;
      } else if (node.kind === "buddy") {
        make("rect", { x: -80, y: -34, width: 160, height: 68, rx: 20, "class": "body" }, inner);
        make("text", { "class": "name", "text-anchor": "middle", y: 2 }, inner).textContent = node.name;
        make("text", { "class": "sub", "text-anchor": "middle", y: 22 }, inner).textContent = node.sub;
      } else {
        make("rect", { x: -62, y: -20, width: 124, height: 40, rx: 20, "class": "body" }, inner);
        make("text", { "class": "name", "text-anchor": "middle", y: 5 }, inner).textContent = node.name;
      }
      nodeElements[id] = group;
    });

    var pinned = null, hovered = null, tourIndex = 0, tourTimer = 0, visible = false;

    function show(activeId) {
      Object.keys(nodeElements).forEach(function (id) {
        var related = edges.some(function (pair) { return (pair[0] === activeId && pair[1] === id) || (pair[1] === activeId && pair[0] === id); });
        var element = nodeElements[id];
        element.classList.toggle("is-active", id === activeId);
        element.classList.toggle("is-neighbor", related);
        element.classList.toggle("is-dim", id !== activeId && !related);
        element.setAttribute("aria-pressed", id === pinned ? "true" : "false");
      });
      edgeGroups.forEach(function (edge) {
        var connected = edge.from === activeId || edge.to === activeId;
        edge.group.classList.toggle("on", connected);
        edge.line.classList.toggle("on", connected);
        edge.line.classList.toggle("dim", !connected);
      });
      if (captionHost) {
        var info = nodes[activeId];
        if (captionHost.dataset.shown !== activeId) {
          captionHost.classList.add("swap");
          window.setTimeout(function () {
            captionHost.querySelector("h3").textContent = info.title;
            captionHost.querySelector("p").textContent = info.text;
            captionHost.dataset.shown = activeId;
            captionHost.classList.remove("swap");
          }, 180);
        }
      }
    }
    function currentId() { return pinned || hovered || tour[tourIndex]; }
    function schedule() {
      window.clearTimeout(tourTimer);
      if (reduceMotion || pinned || hovered || !visible) return;
      tourTimer = window.setTimeout(function () { tourIndex = (tourIndex + 1) % tour.length; show(currentId()); schedule(); }, 3400);
    }

    Object.keys(nodeElements).forEach(function (id) {
      var element = nodeElements[id];
      element.addEventListener("pointerenter", function () { hovered = id; show(currentId()); schedule(); });
      element.addEventListener("pointerleave", function () { hovered = null; show(currentId()); schedule(); });
      element.addEventListener("focus", function () { hovered = id; show(currentId()); });
      element.addEventListener("blur", function () { hovered = null; show(currentId()); schedule(); });
      function toggle() { pinned = pinned === id ? null : id; show(currentId()); schedule(); }
      element.addEventListener("click", toggle);
      element.addEventListener("keydown", function (event) {
        if (event.key === "Enter" || event.key === " ") { event.preventDefault(); toggle(); }
      });
    });

    show(tour[0]);
    whileVisible(host, function () { visible = true; schedule(); }, function () { visible = false; window.clearTimeout(tourTimer); });
  })();

  // ---------- 3. Privacy: flip between "stays here" and "your own cloud key" ----------
  (function privacyRoute() {
    var diagram = document.querySelector("[data-priv]");
    if (!diagram) return;
    var buttons = Array.prototype.slice.call(diagram.querySelectorAll(".toggle button"));
    var caption = diagram.querySelector("[data-priv-caption]");
    var copy = {
      local: ["Nothing leaves.", "Your voice, your screen and the model's answer never leave this Mac. There is no route out, so there is nothing to switch off."],
      cloud: ["Only what you chose, and it says so.", "With your own key, your words and a screenshot go to the provider you picked, clearly labelled first. Switch back at any time."]
    };
    function setMode(mode) {
      diagram.setAttribute("data-mode", mode);
      buttons.forEach(function (button) { button.setAttribute("aria-pressed", button.dataset.mode === mode ? "true" : "false"); });
      caption.classList.add("swap");
      window.setTimeout(function () {
        caption.querySelector("h3").textContent = copy[mode][0];
        caption.querySelector("p").textContent = copy[mode][1];
        caption.classList.remove("swap");
      }, 180);
    }
    buttons.forEach(function (button) { button.addEventListener("click", function () { setMode(button.dataset.mode); }); });
    // A gentle demonstration once, when it first scrolls into view, then it is yours to flip.
    var touched = false;
    buttons.forEach(function (button) { button.addEventListener("click", function () { touched = true; }); });
    if (!reduceMotion && "IntersectionObserver" in window) {
      var once = new IntersectionObserver(function (entries) {
        if (!entries[0].isIntersecting) return;
        once.disconnect();
        window.setTimeout(function () { if (!touched) setMode("cloud"); }, 2200);
        window.setTimeout(function () { if (!touched) setMode("local"); }, 6200);
      }, { threshold: 0.6 });
      once.observe(diagram);
    }
  })();
})();

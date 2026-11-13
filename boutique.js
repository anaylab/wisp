// Depth that answers the pointer and the scroll. Purely decorative: it only sets CSS
// variables (boutique.css reads them), and does nothing on touch screens or with Reduce Motion.
(function () {
  var reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var touchOrSmall = window.matchMedia("(max-width: 900px), (pointer: coarse)").matches;
  if (reduceMotion || touchOrSmall) return;

  function clamp(value, low, high) { return Math.min(high, Math.max(low, value)); }

  // Hero: the window and its chips drift a few degrees toward the pointer, eased each frame.
  var hero = document.querySelector("[data-hero-device]");
  var pointerX = 0, pointerY = 0, easedX = 0, easedY = 0, heroRunning = false;
  function heroFrame() {
    easedX += (pointerX - easedX) * 0.08;
    easedY += (pointerY - easedY) * 0.08;
    hero.style.setProperty("--px", easedX.toFixed(4));
    hero.style.setProperty("--py", easedY.toFixed(4));
    if (Math.abs(pointerX - easedX) > 0.001 || Math.abs(pointerY - easedY) > 0.001) {
      window.requestAnimationFrame(heroFrame);
    } else {
      heroRunning = false;
    }
  }
  if (hero) {
    window.addEventListener("pointermove", function (event) {
      pointerX = clamp((event.clientX / window.innerWidth) * 2 - 1, -1, 1);
      pointerY = clamp((event.clientY / window.innerHeight) * 2 - 1, -1, 1);
      if (!heroRunning) { heroRunning = true; window.requestAnimationFrame(heroFrame); }
    }, { passive: true });
  }

  // Cards: tilt up to 5 degrees toward the pointer while it is over them.
  var cardSelector = ".tile, .cat-card, .cards3 article, .how-stage";
  document.addEventListener("pointermove", function (event) {
    var card = event.target.closest && event.target.closest(cardSelector);
    if (!card) return;
    var box = card.getBoundingClientRect();
    var x = (event.clientX - box.left) / box.width - 0.5;
    var y = (event.clientY - box.top) / box.height - 0.5;
    card.classList.add("is-tilting");
    // The glass highlight follows the pointer across the card.
    card.style.setProperty("--mx", (event.clientX - box.left).toFixed(0) + "px");
    card.style.setProperty("--my", (event.clientY - box.top).toFixed(0) + "px");
    card.style.setProperty("--ry", (x * 7).toFixed(2) + "deg");
    card.style.setProperty("--rx", (-y * 7).toFixed(2) + "deg");
  }, { passive: true });
  document.addEventListener("pointerout", function (event) {
    var card = event.target.closest && event.target.closest(cardSelector);
    if (!card || card.contains(event.relatedTarget)) return;
    card.classList.remove("is-tilting");
    card.style.removeProperty("--rx");
    card.style.removeProperty("--ry");
    card.style.removeProperty("--mx");
    card.style.removeProperty("--my");
  }, { passive: true });

  // Reel: each card swings on a hinge by how far it sits from the middle of the screen.
  var reelCards = Array.prototype.slice.call(document.querySelectorAll(".reel-card"));
  var reelScene = document.querySelector(".reel");
  var swingQueued = false;
  function swing() {
    swingQueued = false;
    var sceneBox = reelScene.getBoundingClientRect();
    if (sceneBox.bottom < 0 || sceneBox.top > window.innerHeight) return;
    var middle = window.innerWidth / 2;
    reelCards.forEach(function (card) {
      var box = card.getBoundingClientRect();
      var offset = ((box.left + box.width / 2) - middle) / (window.innerWidth * 0.6);
      card.style.setProperty("--swing", clamp(offset, -1.3, 1.3).toFixed(3));
    });
  }
  if (reelScene && reelCards.length) {
    var settleTimer = 0;
    window.addEventListener("scroll", function () {
      if (!swingQueued) {
        swingQueued = true;
        window.requestAnimationFrame(swing);
      }
      // The reel keeps easing for a moment after the wheel stops, so measure once more after it.
      window.clearTimeout(settleTimer);
      settleTimer = window.setTimeout(swing, 450);
    }, { passive: true });
    window.addEventListener("resize", swing);
    swing();
  }
})();

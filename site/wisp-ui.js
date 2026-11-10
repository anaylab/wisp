// The pieces every live replica on the page draws Wisp with: the buddy characters, the
// single-stroke icons, the ribbon mark, sidebar rows, the window's rail, a pointer, and
// the rule that keeps a fixed-size canvas sharp at whatever size its frame is.
(function () {
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


  function sidebarRow(entry) {
    return '<div class="wa-row" data-row="' + entry.id + '">' +
      '<span class="wa-av">' + buddy(entry.shape, 38) + '<span class="wa-ring"></span></span>' +
      '<span class="wa-row-body"><span class="wa-row-top"><b>' + entry.name + "</b>" +
      (entry.role ? '<span class="wa-chip">' + entry.role + "</span>" : "") +
      '<span class="wa-time">' + (entry.time || "") + '</span><span class="wa-unread"></span></span>' +
      '<span class="wa-row-text">' + entry.text + "</span></span></div>";
  }

  ICONS.play = '<path d="M8 5.5v13l10-6.5-10-6.5Z" fill="currentColor" stroke="none"/>';
  ICONS.more = '<circle cx="5" cy="12" r="1.3" fill="currentColor"/><circle cx="12" cy="12" r="1.3" fill="currentColor"/><circle cx="19" cy="12" r="1.3" fill="currentColor"/>';
  ICONS.panel = '<rect x="3" y="4" width="18" height="16" rx="3"/><path d="M15 4v16"/>';
  ICONS.send = '<path d="M12 19V5M6 11l6-6 6 6"/>';
  ICONS.copy = '<rect x="8" y="8" width="12" height="12" rx="2.5"/><path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2"/>';
  ICONS.retry = '<path d="M20 12a8 8 0 1 1-2.3-5.6M20 4v5h-5"/>';
  ICONS.share = '<path d="M14 5l6 6-6 6M20 11H9a5 5 0 0 0-5 5v2"/>';
  ICONS.flag = '<path d="M5 21V4M5 4h11l-2 4 2 4H5"/>';
  ICONS.right = '<path d="m9 6 6 6-6 6"/>';
  ICONS.bubble = '<path d="M5 5h14a2 2 0 0 1 2 2v8a2 2 0 0 1-2 2H10l-5 4v-4a2 2 0 0 1-2-2V7a2 2 0 0 1 2-2Z"/>';
  ICONS.cloud = '<path d="M7 18h10a4 4 0 0 0 .5-8A6 6 0 0 0 6 9a4.5 4.5 0 0 0 1 9Z"/><path d="M12 11v5M9.5 13.5 12 11l2.5 2.5"/>';
  ICONS.layers = '<path d="M12 3 3 8l9 5 9-5-9-5ZM3 13l9 5 9-5"/>';
  ICONS.bell = '<path d="M6 16V11a6 6 0 0 1 12 0v5l1.5 2h-15L6 16ZM10 20.5a2 2 0 0 0 4 0"/>';
  ICONS.x = '<path d="M6 6l12 12M18 6 6 18"/>';
  ICONS.card = '<rect x="3" y="5" width="18" height="14" rx="3"/><path d="M3 10h18"/>';
  ICONS.flask = '<path d="M9 3h6M10 3v6l-5 9a2 2 0 0 0 1.8 3h10.4A2 2 0 0 0 19 18l-5-9V3"/>';
  ICONS.back = '<path d="m15 6-6 6 6 6"/>';
  ICONS.reload = '<path d="M19 12a7 7 0 1 1-2-4.9M19 4v4h-4"/>';
  ICONS.star = '<path d="m12 4 2.4 5 5.4.6-4 3.7 1.1 5.4L12 16l-4.9 2.7L8.2 13.3l-4-3.7 5.4-.6L12 4Z"/>';
  ICONS.sparkle = '<path d="M12 3v4M12 17v4M3 12h4M17 12h4M6 6l2.5 2.5M15.5 15.5 18 18M18 6l-2.5 2.5M8.5 15.5 6 18"/>';

  // The window's left rail, with the current page lit.
  function rail(activeName) {
    return ["people", "sun", "chat", "bolt", "flow", "cap", "timer", "brain", "spark", "history", "plug"].map(function (name) {
      return '<span class="wa-rail-ic' + (name === activeName ? " on" : "") + '">' + icon(name, 19) + "</span>";
    }).join("") + '<span class="wa-rail-ic wa-rail-gear">' + icon("gear", 19) + "</span>";
  }

  // The macOS pointer, drawn so it stays sharp at any zoom.
  var POINTER = '<svg class="ui-pointer" width="26" height="34" viewBox="0 0 26 34" aria-hidden="true"><path d="M2 2v26l7-6.5 4.6 10 4.2-1.9-4.5-9.8H23L2 2Z" fill="#111" stroke="#fff" stroke-width="2" stroke-linejoin="round"/></svg>';

  function clamp(value, low, high) { return Math.min(high, Math.max(low, value)); }
  function between(progress, start, end) { return clamp((progress - start) / (end - start), 0, 1); }
  function smooth(amount) { return amount * amount * amount * (amount * (amount * 6 - 15) + 10); }

  // Where something is along a path of [progress, x, y] stops, easing between them.
  function along(stops, progress) {
    if (progress <= stops[0][0]) return [stops[0][1], stops[0][2]];
    for (var index = 0; index < stops.length - 1; index++) {
      var from = stops[index], to = stops[index + 1];
      if (progress <= to[0]) {
        var amount = smooth(between(progress, from[0], to[0]));
        return [from[1] + (to[1] - from[1]) * amount, from[2] + (to[2] - from[2]) * amount];
      }
    }
    var last = stops[stops.length - 1];
    return [last[1], last[2]];
  }

  // Keep a fixed-size canvas at its design size and scale it to its frame. zoom lays text out
  // at its real size, so it stays sharp; transform is the fallback.
  var canZoom = window.CSS && CSS.supports("zoom", "0.5");
  function fitCanvas(canvas, designWidth) {
    function fit() {
      var scale = canvas.parentElement.clientWidth / designWidth;
      if (canZoom) canvas.style.zoom = String(scale);
      else canvas.style.transform = "scale(" + scale + ")";
    }
    fit();
    if ("ResizeObserver" in window) new ResizeObserver(fit).observe(canvas.parentElement);
    else window.addEventListener("resize", fit);
  }

  // Text revealed character by character, cut at a word boundary while it streams.
  function streamed(text, amount) {
    if (amount >= 1) return text;
    return text.slice(0, Math.round(text.length * amount));
  }

  window.WispUI = { SHAPES: SHAPES, buddy: buddy, icon: icon, RIBBON: RIBBON, sidebarRow: sidebarRow, rail: rail, POINTER: POINTER,
    clamp: clamp, between: between, smooth: smooth, along: along, fitCanvas: fitCanvas, streamed: streamed };
})();

// Runs work after the page has loaded and the browser is idle, so heavy setup (building the
// live app replicas) never delays the first paint. Falls back to a timeout where there is no idle callback.
window.wispWhenIdle = function (work) {
  function schedule() {
    if ("requestIdleCallback" in window) window.requestIdleCallback(work, { timeout: 2000 });
    else window.setTimeout(work, 50);
  }
  if (document.readyState === "complete") schedule();
  else window.addEventListener("load", schedule);
};

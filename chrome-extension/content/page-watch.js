// Wisp Tabs — watches one page for a change and reports it (phase 08).
//
// "Tell me when this tab says Deployed", "when the price drops below $80",
// "when this page stops changing". Wisp's screen watcher can only see what is
// on screen, read back from pixels every few seconds; this runs inside the tab
// itself, so it sees the page's own text, below the fold and in a background
// tab, the moment it changes (a MutationObserver) — and costs nothing while the
// page is still.
//
// Injected on demand by handlers/page-watchers.js with
// `chrome.scripting.executeScript({files: ["content/page-watch.js"]})`, which
// runs it as a classic script in the extension's isolated world. It defines
// `globalThis.wispPageWatch`; the handler then calls `install(watch)` with a
// second `executeScript({func})`. Injecting it again is harmless: the first
// definition stays, with its watches.
//
// What a watch has learned so far (the evaluator's `state`) is sent to the
// service worker whenever it changes, and handed back on every install. So a
// reload — the page loading again after a navigation, or a reloading watch's
// interval — continues the watch instead of starting over: "Succeeded" that
// was already on the page before the user asked still doesn't count.
//
// Never reads secrets (contracts.md §6): the text is the page's rendered text
// (`innerText`), which holds no form-field values, and anything inside
// `[data-wisp-ignore]` is left out.
//
// The conditions mirror Wisp's `ScreenWatchCondition` (ScreenWatcher.swift) so
// a spoken "tell me when …" means the same thing on the screen and in a tab.
// Every function that decides takes plain values, so the tests run them with
// no browser.

(() => {
  if (globalThis.wispPageWatch) return;

  // At most one evaluation per second, however busy the page is: a page
  // streaming a build log can mutate hundreds of times a second.
  const MINIMUM_MILLISECONDS_BETWEEN_EVALUATIONS = 1000;
  // pageSettlesAfterChange: the page's text changed, then stayed the same this
  // long. A little shorter than the screen watcher's ~12s, because a mutation
  // arrives the moment it happens instead of on a 3-second poll.
  const SETTLE_QUIET_MILLISECONDS = 10000;
  // textDisappears: evaluations in a row without the text before it counts as
  // gone, so a page re-rendering a list (briefly empty) isn't taken as it.
  const ABSENT_EVALUATIONS_TO_DISAPPEAR = 2;
  const DISAPPEAR_RECHECK_MILLISECONDS = 1500;
  // A huge page is read in part rather than making every evaluation slow.
  const MAXIMUM_PAGE_LINES = 5000;
  const MAXIMUM_PAGE_CHARACTERS = 200000;
  const MAXIMUM_REPORTED_TEXT_CHARACTERS = 500;
  // numberCrosses: how far after the line naming it a number may be ("Price"
  // on one line, "$79.99" on the next).
  const NUMBER_SEARCH_FOLLOWING_LINE_COUNT = 2;

  // MARK: - Text matching (mirrors ScreenWatchTextMatching)

  // Lowercased, accents folded, punctuation turned into spaces, runs of
  // whitespace collapsed. "** BUILD SUCCEEDED **" → "build succeeded".
  function normalizedText(rawText) {
    if (typeof rawText !== "string") return "";
    return rawText
      .normalize("NFKD")
      .replace(/\p{M}+/gu, "")
      .toLowerCase()
      .replace(/[^\p{L}\p{N}]+/gu, " ")
      .trim();
  }

  // Whether one line holds the target as whole words, so "done" doesn't
  // match "abandoned".
  function lineContainsTarget(lineText, targetText) {
    const normalizedTarget = normalizedText(targetText);
    if (!normalizedTarget) return false;
    return ` ${normalizedText(lineText)} `.includes(` ${normalizedTarget} `);
  }

  // MARK: - Numbers

  // A number as written on a page: grouped thousands first ("1,299.99",
  // "1.299,99", "1 299"), else plain digits with an optional decimal part
  // ("79.99", "79,99", "12345"). Currency signs are simply not part of it.
  const NUMBER_TOKEN_PATTERN = /[-−]?(?:\d{1,3}(?:[,.'   ]\d{3})+(?:[.,]\d+)?|\d+(?:[.,]\d+)?)/g;

  // "$1,299.99" → 1299.99, "1.299,99 €" → 1299.99, "79,99" → 79.99,
  // "1,299" → 1299. Null when there is no number.
  function parseNumberText(numberText) {
    if (typeof numberText !== "string") return null;
    const tokenMatch = numberText.match(new RegExp(NUMBER_TOKEN_PATTERN.source));
    if (!tokenMatch) return null;
    let digitsText = tokenMatch[0].replace("−", "-").replace(/['   ]/g, "");

    const lastCommaIndex = digitsText.lastIndexOf(",");
    const lastDotIndex = digitsText.lastIndexOf(".");
    if (lastCommaIndex >= 0 && lastDotIndex >= 0) {
      // Both kinds: whichever comes last is the decimal point.
      const decimalSeparator = lastCommaIndex > lastDotIndex ? "," : ".";
      const groupingSeparator = decimalSeparator === "," ? "." : ",";
      digitsText = digitsText.split(groupingSeparator).join("").replace(decimalSeparator, ".");
    } else if (lastCommaIndex >= 0 || lastDotIndex >= 0) {
      const separator = lastCommaIndex >= 0 ? "," : ".";
      const parts = digitsText.split(separator);
      const integerPart = parts[0].replace("-", "");
      const isGrouping = parts.length > 2 || (parts[1].length === 3 && integerPart !== "0");
      digitsText = isGrouping ? parts.join("") : `${parts[0]}.${parts[1]}`;
    }
    const parsedNumber = Number(digitsText);
    return Number.isFinite(parsedNumber) ? parsedNumber : null;
  }

  // The first number in a piece of text, as `{value, text}`, or null.
  function firstNumberIn(text) {
    if (typeof text !== "string") return null;
    for (const tokenMatch of text.matchAll(NUMBER_TOKEN_PATTERN)) {
      const value = parseNumberText(tokenMatch[0]);
      if (value !== null) return { value, text: tokenMatch[0].trim() };
    }
    return null;
  }

  // The number "near" some text: after it on the first line that names it,
  // else anywhere on that line, else on the next line or two. The line's own
  // text is kept for the report ("Price: $79.99").
  function findNumberNearText(pageLines, nearText) {
    if (!normalizedText(nearText)) return null;
    for (let lineIndex = 0; lineIndex < pageLines.length; lineIndex += 1) {
      const lineText = pageLines[lineIndex];
      if (!lineContainsTarget(lineText, nearText)) continue;

      const nearTextPosition = lineText.toLowerCase().indexOf(String(nearText).trim().toLowerCase());
      const textAfterNearText = nearTextPosition >= 0
        ? lineText.slice(nearTextPosition + String(nearText).trim().length)
        : "";
      const numberOnLine = firstNumberIn(textAfterNearText) ?? firstNumberIn(lineText);
      if (numberOnLine) return { ...numberOnLine, lineText };

      const lastFollowingIndex = Math.min(pageLines.length - 1, lineIndex + NUMBER_SEARCH_FOLLOWING_LINE_COUNT);
      for (let followingIndex = lineIndex + 1; followingIndex <= lastFollowingIndex; followingIndex += 1) {
        const numberOnFollowingLine = firstNumberIn(pageLines[followingIndex]);
        if (numberOnFollowingLine) return { ...numberOnFollowingLine, lineText: `${lineText} ${pageLines[followingIndex]}` };
      }
    }
    return null;
  }

  // MARK: - Reading the page

  function elementText(element) {
    if (!element) return "";
    const renderedText = typeof element.innerText === "string" ? element.innerText : element.textContent;
    return typeof renderedText === "string" ? renderedText : "";
  }

  function splitIntoLines(text) {
    return text.split(/\r?\n/).map((line) => line.replace(/\s+/g, " ").trim()).filter((line) => line.length > 0);
  }

  // The page's rendered text as lines, without `[data-wisp-ignore]` regions,
  // capped so one evaluation stays cheap.
  function readPageLines(pageDocument) {
    const pageBody = pageDocument?.body;
    if (!pageBody) return [];
    let pageLines = splitIntoLines(elementText(pageBody).slice(0, MAXIMUM_PAGE_CHARACTERS));

    // innerText can't leave a subtree out, so an ignored region's lines are
    // taken back out, one occurrence each.
    const ignoredElements = typeof pageBody.querySelectorAll === "function"
      ? [...pageBody.querySelectorAll("[data-wisp-ignore]")]
      : [];
    for (const ignoredElement of ignoredElements) {
      for (const ignoredLine of splitIntoLines(elementText(ignoredElement))) {
        const ignoredLineIndex = pageLines.indexOf(ignoredLine);
        if (ignoredLineIndex >= 0) pageLines.splice(ignoredLineIndex, 1);
      }
    }
    if (pageLines.length > MAXIMUM_PAGE_LINES) pageLines = pageLines.slice(0, MAXIMUM_PAGE_LINES);
    return pageLines;
  }

  // A short, stable fingerprint of the page's text, so "has it changed" is a
  // string comparison and the state sent to the worker stays small.
  function textSignature(pageLines) {
    let hash = 2166136261;
    const joinedText = pageLines.map(normalizedText).filter(Boolean).join("\n");
    for (let characterIndex = 0; characterIndex < joinedText.length; characterIndex += 1) {
      hash ^= joinedText.charCodeAt(characterIndex);
      hash = Math.imul(hash, 16777619) >>> 0;
    }
    return `${joinedText.length}:${hash.toString(16)}`;
  }

  // What one evaluation needs from the page for a condition — nothing more,
  // so the evaluator itself never touches the DOM.
  function observePage(condition, pageDocument) {
    const pageLines = readPageLines(pageDocument);
    switch (condition.kind) {
      case "textAppears": {
        const matchingLines = pageLines.filter((lineText) => lineContainsTarget(lineText, condition.text));
        return { matchingLineCount: matchingLines.length, lastMatchingLine: matchingLines.at(-1) ?? null };
      }
      case "textDisappears":
        return { isPresent: pageLines.some((lineText) => lineContainsTarget(lineText, condition.text)) };
      case "pageSettlesAfterChange":
        return { signature: textSignature(pageLines) };
      case "numberCrosses": {
        let foundNumber = null;
        if (condition.selector) {
          let selectedElement = null;
          try {
            selectedElement = pageDocument.querySelector(condition.selector);
          } catch (error) {
            selectedElement = null;
          }
          if (selectedElement && !selectedElement.closest?.("[data-wisp-ignore]")) {
            const selectedText = elementText(selectedElement).replace(/\s+/g, " ").trim();
            const numberInElement = firstNumberIn(selectedText);
            if (numberInElement) foundNumber = { ...numberInElement, lineText: selectedText };
          }
        }
        if (!foundNumber && condition.nearText) {
          foundNumber = findNumberNearText(pageLines, condition.nearText);
        }
        return foundNumber
          ? { value: foundNumber.value, numberText: foundNumber.text, lineText: foundNumber.lineText }
          : { value: null };
      }
      default:
        return {};
    }
  }

  // MARK: - Deciding (mirrors ScreenWatchEvaluator)

  // One step of a watch: the condition, what it has learned so far, and what
  // the page shows now → the new state, whether the condition is met, and
  // when to look again even if the page doesn't change.
  //   → { state, met, matchedText, recheckAfterMilliseconds }
  function evaluateObservation(condition, previousState, observation, nowMilliseconds) {
    const state = { ...(previousState ?? {}) };
    const waiting = (recheckAfterMilliseconds = null) => ({ state, met: false, matchedText: null, recheckAfterMilliseconds });
    switch (condition.kind) {
      case "textAppears": {
        const matchingLineCount = observation.matchingLineCount ?? 0;
        const previousCount = state.previousMatchingLineCount;
        state.previousMatchingLineCount = matchingLineCount;
        // The first reading is the baseline: whatever matches already was there
        // before the user asked. More matches than the fewest seen = it appeared
        // (again), even after the old one scrolled or was replaced.
        if (state.fewestMatchingLineCount === undefined || state.fewestMatchingLineCount === null) {
          state.fewestMatchingLineCount = matchingLineCount;
          return waiting();
        }
        if (matchingLineCount > state.fewestMatchingLineCount) {
          return { state, met: true, matchedText: observation.lastMatchingLine ?? condition.text, recheckAfterMilliseconds: null };
        }
        // A lower count becomes the baseline only once two readings agree, so
        // one half-rendered moment can't lower it and let the next look new.
        const countConfirmedByTwoReadings = Math.max(matchingLineCount, previousCount ?? matchingLineCount);
        state.fewestMatchingLineCount = Math.min(state.fewestMatchingLineCount, countConfirmedByTwoReadings);
        return waiting();
      }
      case "textDisappears": {
        if (observation.isPresent) {
          state.hasSeenText = true;
          state.consecutiveAbsentCount = 0;
          return waiting();
        }
        // Text that was never there can't go away.
        if (!state.hasSeenText) return waiting();
        state.consecutiveAbsentCount = (state.consecutiveAbsentCount ?? 0) + 1;
        if (state.consecutiveAbsentCount >= ABSENT_EVALUATIONS_TO_DISAPPEAR) {
          return { state, met: true, matchedText: null, recheckAfterMilliseconds: null };
        }
        return waiting(DISAPPEAR_RECHECK_MILLISECONDS);
      }
      case "pageSettlesAfterChange": {
        if (state.signature === undefined || state.signature === null) {
          state.signature = observation.signature;
          return waiting();
        }
        if (observation.signature !== state.signature) {
          state.signature = observation.signature;
          state.hasSeenChange = true;
          state.lastChangeAt = nowMilliseconds;
          return waiting(SETTLE_QUIET_MILLISECONDS);
        }
        // Settling only means something after the page was seen working.
        if (!state.hasSeenChange) return waiting();
        const quietMilliseconds = nowMilliseconds - (state.lastChangeAt ?? nowMilliseconds);
        if (quietMilliseconds >= SETTLE_QUIET_MILLISECONDS) {
          return { state, met: true, matchedText: null, recheckAfterMilliseconds: null };
        }
        return waiting(SETTLE_QUIET_MILLISECONDS - quietMilliseconds);
      }
      case "numberCrosses": {
        if (typeof observation.value !== "number") return waiting();
        state.lastValue = observation.value;
        const isPastThreshold = condition.direction === "below"
          ? observation.value < condition.threshold
          : observation.value > condition.threshold;
        if (isPastThreshold) {
          return { state, met: true, matchedText: observation.lineText || observation.numberText || String(observation.value), recheckAfterMilliseconds: null };
        }
        return waiting();
      }
      default:
        return waiting();
    }
  }

  // MARK: - Watching a live page

  const installedWatches = new Map();

  function capText(text) {
    if (typeof text !== "string") return null;
    return text.length > MAXIMUM_REPORTED_TEXT_CHARACTERS ? text.slice(0, MAXIMUM_REPORTED_TEXT_CHARACTERS) : text;
  }

  function defaultReport(report) {
    try {
      // Fire-and-forget: the worker wakes for it; nothing waits on a reply.
      const sendResult = chrome.runtime.sendMessage(report);
      sendResult?.catch?.(() => {});
    } catch (error) {
      // The extension was reloaded or removed; this page's watch is orphaned
      // and the next install replaces it.
    }
  }

  // Starts watching. `watch` is `{watchId, condition, state}`; `options` lets
  // the tests pass a document, timers, a clock and a report function.
  function install(watch, options = {}) {
    if (!watch || typeof watch.watchId !== "string" || !watch.condition) return { installed: false };
    if (installedWatches.has(watch.watchId)) return { installed: true, alreadyInstalled: true };

    const pageDocument = options.document ?? globalThis.document;
    const setTimer = options.setTimeout ?? globalThis.setTimeout.bind(globalThis);
    const clearTimer = options.clearTimeout ?? globalThis.clearTimeout.bind(globalThis);
    const now = options.now ?? (() => Date.now());
    const report = options.report ?? defaultReport;
    const MutationObserverImplementation = options.MutationObserver ?? globalThis.MutationObserver;

    const installedWatch = {
      watchId: watch.watchId,
      condition: watch.condition,
      state: watch.state ?? {},
      lastReportedStateJSON: JSON.stringify(watch.state ?? {}),
      lastEvaluatedAt: -Infinity,
      pendingTimerID: null,
      pendingTimerFiresAt: null,
      observer: null,
      hasMet: false,
    };

    function evaluateNowForWatch() {
      if (installedWatch.hasMet) return "met";
      installedWatch.lastEvaluatedAt = now();
      const observation = observePage(installedWatch.condition, pageDocument);
      const evaluation = evaluateObservation(installedWatch.condition, installedWatch.state, observation, installedWatch.lastEvaluatedAt);
      installedWatch.state = evaluation.state;

      const stateJSON = JSON.stringify(evaluation.state);
      if (evaluation.met) {
        installedWatch.hasMet = true;
        uninstall(installedWatch.watchId);
        report({ type: "wisp.pageWatch.report", watchId: installedWatch.watchId, state: evaluation.state, met: true, matchedText: capText(evaluation.matchedText) });
        return "met";
      }
      if (stateJSON !== installedWatch.lastReportedStateJSON) {
        installedWatch.lastReportedStateJSON = stateJSON;
        report({ type: "wisp.pageWatch.report", watchId: installedWatch.watchId, state: evaluation.state, met: false, matchedText: null });
      }
      if (evaluation.recheckAfterMilliseconds !== null) {
        scheduleEvaluation(evaluation.recheckAfterMilliseconds);
      }
      return "waiting";
    }

    // Runs an evaluation after `delayMilliseconds`, but never sooner than a
    // second after the last one; an earlier pending one wins.
    function scheduleEvaluation(delayMilliseconds) {
      const earliestAllowedAt = installedWatch.lastEvaluatedAt + MINIMUM_MILLISECONDS_BETWEEN_EVALUATIONS;
      const firesAt = Math.max(now() + Math.max(0, delayMilliseconds), earliestAllowedAt);
      if (installedWatch.pendingTimerID !== null) {
        if (installedWatch.pendingTimerFiresAt <= firesAt) return;
        clearTimer(installedWatch.pendingTimerID);
      }
      installedWatch.pendingTimerFiresAt = firesAt;
      installedWatch.pendingTimerID = setTimer(() => {
        installedWatch.pendingTimerID = null;
        installedWatch.pendingTimerFiresAt = null;
        if (installedWatches.has(installedWatch.watchId)) evaluateNowForWatch();
      }, Math.max(0, firesAt - now()));
    }

    installedWatch.evaluateNow = evaluateNowForWatch;
    installedWatch.stop = () => {
      installedWatch.observer?.disconnect();
      if (installedWatch.pendingTimerID !== null) clearTimer(installedWatch.pendingTimerID);
      installedWatch.pendingTimerID = null;
    };
    installedWatches.set(installedWatch.watchId, installedWatch);

    if (typeof MutationObserverImplementation === "function" && pageDocument?.documentElement) {
      installedWatch.observer = new MutationObserverImplementation(() => scheduleEvaluation(0));
      installedWatch.observer.observe(pageDocument.documentElement, { childList: true, subtree: true, characterData: true });
    }
    // The first reading sets the baseline (or, after a reload, continues
    // from the state the worker handed back).
    const firstResult = evaluateNowForWatch();
    return { installed: firstResult !== "met", met: firstResult === "met" };
  }

  function uninstall(watchId) {
    const installedWatch = installedWatches.get(watchId);
    if (!installedWatch) return { uninstalled: false };
    installedWatch.stop();
    installedWatches.delete(watchId);
    return { uninstalled: true };
  }

  // The worker's once-a-minute nudge: background tabs throttle timers hard
  // (to once a minute after five hidden minutes), so a settle or disappear
  // check that is waiting on a timer is also run from here.
  function evaluateNow(watchId) {
    const installedWatch = installedWatches.get(watchId);
    return installedWatch ? installedWatch.evaluateNow() : "notInstalled";
  }

  function installedWatchIDs() {
    return [...installedWatches.keys()];
  }

  globalThis.wispPageWatch = {
    normalizedText,
    lineContainsTarget,
    parseNumberText,
    firstNumberIn,
    findNumberNearText,
    readPageLines,
    textSignature,
    observePage,
    evaluateObservation,
    install,
    uninstall,
    evaluateNow,
    installedWatchIDs,
    SETTLE_QUIET_MILLISECONDS,
    MINIMUM_MILLISECONDS_BETWEEN_EVALUATIONS,
  };
})();

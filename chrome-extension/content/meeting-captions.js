// Wisp Tabs — keeps the last 30 minutes of a meeting's captions (phase 10).
//
// "What did I miss?" in a Google Meet (or Zoom web) call: when the user has
// turned captions on, this script copies the caption text out of the page into
// a rolling buffer, so Wisp can summarize the part they missed. Wisp fetches it
// with `getMeetingCaptions({tabId, lastMinutes})`.
//
// Privacy is the point of the design:
//   - No audio is captured. Only the caption text Meet already shows on screen
//     is read, and only once the user has turned captions on.
//   - The buffer lives in this page's memory only: never sent anywhere unasked,
//     never written to disk or extension storage, capped at 30 minutes, and gone
//     when the tab closes or navigates.
//
// Registered with `chrome.scripting.registerContentScripts` for the meeting
// hosts once `pages.read` is allowed (events/site-helpers.js), and injected on
// demand by handlers/site-helpers.js for a call that was already running.
//
// Caption markup is undocumented and changes often, so every selector is in
// one table below, and missing captions fail soft: the reply says how to turn
// them on instead of erroring. Classic script (content scripts can't be
// modules); the pure parts are on `globalThis.wispMeetingCaptions` for tests.

(() => {
  // Injected twice (registered, then on demand): the first copy keeps the buffer.
  if (globalThis.wispMeetingCaptions) return;

  const BUFFER_LIMIT_MILLISECONDS = 30 * 60 * 1000;
  // An entry is closed after a minute so "the last 5 minutes" can be cut
  // between entries instead of returning a whole long monologue.
  const SEGMENT_MILLISECONDS = 60 * 1000;
  // A speaker's caption block that Meet rebuilt within this long still
  // continues the same entry.
  const REBUILT_BLOCK_CONTINUATION_MILLISECONDS = 5000;
  const MAXIMUM_BLOCK_TEXT_CHARACTERS = 40000;
  const MAXIMUM_REPLY_CHARACTERS = 20000;
  const MAXIMUM_REPLY_ENTRIES = 500;
  const MAXIMUM_SPEAKER_CHARACTERS = 80;
  // Captions that vanish for this long count as turned off.
  const CAPTIONS_GONE_MILLISECONDS = 30 * 1000;
  const READ_DEBOUNCE_MILLISECONDS = 500;
  const BACKSTOP_READ_INTERVAL_MILLISECONDS = 2000;

  // Every caption selector, per site, most specific first. When a site
  // changes its markup, this table is the one place to fix.
  const CAPTION_SITE_SELECTORS = {
    meet: {
      hostPattern: /^meet\.google\.com$/i,
      regions: [
        "[role='region'][aria-label='Captions']",
        "[role='region'][aria-label*='aption' i]",
        "div[jsname='dsyhDe']",
        ".a4cQT",
      ],
      blocks: [".nMcdL", ".TBMuR", "[jsname='tgaKEf']"],
      speakers: [".NWpY1d", ".KcIKyf", ".zs7s8d"],
      texts: [".ygicle", ".iTTPOb", "[jsname='YSxPC']", ".bh44bd"],
    },
    zoom: {
      hostPattern: /(^|\.)zoom\.us$/i,
      regions: ["#live-transcription-subtitle", ".live-transcription-subtitle__box", "[class*='live-transcription-subtitle']"],
      blocks: [".live-transcription-subtitle__item"],
      speakers: [],
      texts: [],
    },
  };

  const NEVER_READ_SELECTOR = "input, textarea, select, button, script, style, [data-wisp-ignore]";

  function collapsedWhitespace(text) {
    return String(text ?? "").replace(/\s+/g, " ").trim();
  }

  function safeText(element) {
    if (!element || element.closest?.("[data-wisp-ignore]")) return "";
    const clonedElement = element.cloneNode(true);
    for (const unreadableElement of clonedElement.querySelectorAll(NEVER_READ_SELECTOR)) {
      unreadableElement.remove();
    }
    return collapsedWhitespace(clonedElement.textContent);
  }

  function firstMatch(rootNode, selectors) {
    for (const selector of selectors) {
      const element = rootNode.querySelector(selector);
      if (element) return element;
    }
    return null;
  }

  function siteForHost(hostname) {
    for (const [siteName, siteSelectors] of Object.entries(CAPTION_SITE_SELECTORS)) {
      if (siteSelectors.hostPattern.test(hostname ?? "")) return siteName;
    }
    return null;
  }

  // What the caption area shows right now: `{regionFound, blocks}`, each block
  // `{key, speaker, text}` where `key` is the block's element (the same element
  // keeps growing while one person talks).
  function readCaptionBlocks(pageDocument, siteName) {
    const siteSelectors = CAPTION_SITE_SELECTORS[siteName];
    if (!siteSelectors) return { regionFound: false, blocks: [] };
    const regionElement = firstMatch(pageDocument, siteSelectors.regions);
    if (!regionElement) return { regionFound: false, blocks: [] };

    let blockElements = [];
    for (const blockSelector of siteSelectors.blocks) {
      blockElements = [...regionElement.querySelectorAll(blockSelector)];
      if (blockElements.length > 0) break;
    }
    // Markup the table doesn't know: each child of the region is a block,
    // and a child with a short first part and a longer rest is "name, words".
    const usesFallbackBlocks = blockElements.length === 0;
    if (usesFallbackBlocks) blockElements = [...regionElement.children];

    const blocks = [];
    for (const blockElement of blockElements) {
      const speakerElement = firstMatch(blockElement, siteSelectors.speakers);
      const textElement = firstMatch(blockElement, siteSelectors.texts);
      let speaker = safeText(speakerElement);
      let text = textElement ? safeText(textElement) : "";
      if (!textElement) {
        const childTexts = [...blockElement.children].map((childElement) => safeText(childElement)).filter(Boolean);
        if (!speakerElement && childTexts.length >= 2 && childTexts[0].length <= MAXIMUM_SPEAKER_CHARACTERS) {
          speaker = childTexts[0];
          text = childTexts.slice(1).join(" ");
        } else {
          text = safeText(blockElement);
          if (speaker && text.startsWith(speaker)) text = text.slice(speaker.length).trim();
        }
      }
      if (!text) continue;
      blocks.push({ key: blockElement, speaker: speaker.slice(0, MAXIMUM_SPEAKER_CHARACTERS), text });
    }
    return { regionFound: true, blocks };
  }

  function comparableWord(word) {
    return word.toLowerCase().replace(/[^\p{L}\p{N}']/gu, "");
  }

  // A caption block's text a moment ago and now → the whole text so far, or
  // null when the new text doesn't continue the old one.
  //
  // Captions change three ways while someone talks: words are added at the
  // end, the last few words are revised ("shud" → "should go"), and old lines
  // scroll out at the front. So the new text is anchored where its opening
  // words appear in the old text (at least three in a row, or running to the
  // old text's end), the old text before that point is kept, and the new
  // text replaces the rest.
  function mergeCaptionText(previousText, currentText) {
    const previousWords = collapsedWhitespace(previousText).split(" ").filter(Boolean);
    const currentWords = collapsedWhitespace(currentText).split(" ").filter(Boolean);
    if (currentWords.length === 0) return previousWords.join(" ");
    if (previousWords.length === 0) return currentWords.join(" ");
    const previousComparable = previousWords.map(comparableWord);
    const currentComparable = currentWords.map(comparableWord);

    let bestStartIndex = -1;
    let bestMatchLength = 0;
    for (let startIndex = 0; startIndex < previousComparable.length; startIndex += 1) {
      let matchLength = 0;
      while (
        startIndex + matchLength < previousComparable.length &&
        matchLength < currentComparable.length &&
        previousComparable[startIndex + matchLength] === currentComparable[matchLength]
      ) {
        matchLength += 1;
      }
      if (matchLength === 0) continue;
      const runsToPreviousEnd = startIndex + matchLength === previousComparable.length;
      const isLongEnoughAnchor = matchLength >= 3;
      const coversAllOfCurrent = matchLength === currentComparable.length;
      if (!runsToPreviousEnd && !isLongEnoughAnchor && !coversAllOfCurrent) continue;
      // The longest anchor wins; on a tie the later one, so text that
      // repeats a phrase isn't cut back to its first occurrence.
      if (matchLength >= bestMatchLength) {
        bestStartIndex = startIndex;
        bestMatchLength = matchLength;
      }
    }
    if (bestStartIndex < 0) return null;

    // The new text is wholly inside the old (a momentary partial view):
    // nothing was said that isn't already kept.
    const isContainedInPrevious = bestMatchLength === currentComparable.length &&
      bestStartIndex + bestMatchLength < previousComparable.length;
    if (isContainedInPrevious) return previousWords.join(" ");

    return [...previousWords.slice(0, bestStartIndex), ...currentWords].join(" ");
  }

  function createCaptionBuffer(now) {
    return {
      entries: [],
      // block element → {fullText, segmentStartOffset, entry, speaker}
      blockStates: new WeakMap(),
      lastTouchedBlockState: null,
      startedAt: now,
    };
  }

  function startEntry(captionBuffer, speaker, text, now) {
    const newEntry = { speaker, text, firstSeenAt: now, lastUpdatedAt: now };
    captionBuffer.entries.push(newEntry);
    return newEntry;
  }

  // Folds one reading of the caption area into the buffer.
  function recordCaptionReading(captionBuffer, blocks, now) {
    for (const block of blocks) {
      let blockState = captionBuffer.blockStates.get(block.key);
      let mergedText = blockState ? mergeCaptionText(blockState.fullText, block.text) : null;

      if (mergedText === null) {
        // A new element: Meet sometimes rebuilds the current speaker's block,
        // so it carries on the last entry when the words continue it.
        const recentState = captionBuffer.lastTouchedBlockState;
        const recentMergedText = recentState &&
          recentState.speaker === block.speaker &&
          now - recentState.entry.lastUpdatedAt < REBUILT_BLOCK_CONTINUATION_MILLISECONDS
          ? mergeCaptionText(recentState.fullText, block.text)
          : null;
        if (recentMergedText !== null) {
          blockState = recentState;
          mergedText = recentMergedText;
        } else {
          blockState = {
            fullText: block.text,
            segmentStartOffset: 0,
            speaker: block.speaker,
            entry: startEntry(captionBuffer, block.speaker, block.text, now),
          };
          captionBuffer.blockStates.set(block.key, blockState);
          captionBuffer.lastTouchedBlockState = blockState;
          continue;
        }
        captionBuffer.blockStates.set(block.key, blockState);
      }

      captionBuffer.lastTouchedBlockState = blockState;
      if (mergedText === blockState.fullText) continue;
      blockState.fullText = mergedText;
      if (blockState.fullText.length > MAXIMUM_BLOCK_TEXT_CHARACTERS) {
        const cutCharacterCount = blockState.fullText.length - MAXIMUM_BLOCK_TEXT_CHARACTERS / 2;
        blockState.fullText = blockState.fullText.slice(cutCharacterCount);
        blockState.segmentStartOffset = Math.max(0, blockState.segmentStartOffset - cutCharacterCount);
      }

      const segmentText = blockState.fullText.slice(Math.min(blockState.segmentStartOffset, blockState.fullText.length)).trim();
      const currentEntry = blockState.entry;
      const isSegmentFull = now - currentEntry.firstSeenAt >= SEGMENT_MILLISECONDS;
      if (isSegmentFull && segmentText.startsWith(currentEntry.text) && segmentText.length > currentEntry.text.length) {
        // Close this minute's entry; the new words start the next one.
        const newWords = segmentText.slice(currentEntry.text.length).trim();
        blockState.segmentStartOffset = blockState.fullText.length - newWords.length;
        blockState.entry = startEntry(captionBuffer, blockState.speaker, newWords, now);
      } else if (segmentText !== currentEntry.text) {
        currentEntry.text = segmentText;
        currentEntry.lastUpdatedAt = now;
      }
    }
    pruneCaptionBuffer(captionBuffer, now);
  }

  // Drops everything older than 30 minutes.
  function pruneCaptionBuffer(captionBuffer, now) {
    const oldestKeptTime = now - BUFFER_LIMIT_MILLISECONDS;
    const firstKeptIndex = captionBuffer.entries.findIndex((entry) => entry.lastUpdatedAt >= oldestKeptTime);
    if (firstKeptIndex < 0) {
      captionBuffer.entries = [];
    } else if (firstKeptIndex > 0) {
      captionBuffer.entries = captionBuffer.entries.slice(firstKeptIndex);
    }
  }

  // The entries touched in the last `lastMinutes` (1–30, default 30), oldest
  // first, capped to the newest 20,000 characters and 500 entries.
  function captionEntriesWithin(captionBuffer, lastMinutes, now) {
    const requestedMinutes = Number.isFinite(lastMinutes) ? Math.min(Math.max(Math.round(lastMinutes), 1), 30) : 30;
    const oldestIncludedTime = now - requestedMinutes * 60 * 1000;
    const windowEntries = captionBuffer.entries.filter((entry) => entry.lastUpdatedAt >= oldestIncludedTime && entry.text);

    const keptEntries = [];
    let keptCharacterCount = 0;
    let truncated = false;
    for (let entryIndex = windowEntries.length - 1; entryIndex >= 0; entryIndex -= 1) {
      const entry = windowEntries[entryIndex];
      if (keptEntries.length >= MAXIMUM_REPLY_ENTRIES || keptCharacterCount + entry.text.length > MAXIMUM_REPLY_CHARACTERS) {
        truncated = true;
        break;
      }
      keptCharacterCount += entry.text.length;
      keptEntries.unshift({
        speaker: entry.speaker,
        text: entry.text,
        startedAt: entry.firstSeenAt,
        endedAt: entry.lastUpdatedAt,
      });
    }
    return { requestedMinutes, entries: keptEntries, truncated };
  }

  // MARK: - Running in a meeting tab

  const pageState = {
    siteName: null,
    captionBuffer: null,
    captionsVisible: false,
    captionsLastSeenAt: 0,
    pendingReadTimer: null,
  };

  function announceCaptionsAvailable() {
    try {
      globalThis.chrome?.runtime?.sendMessage?.({ type: "wisp.site.meetingCaptionsAvailable" });
    } catch (error) {
      // The extension was reloaded under this page; nothing to tell.
    }
  }

  function readCaptionsNow() {
    pageState.pendingReadTimer = null;
    if (!pageState.siteName) return;
    const now = Date.now();
    const reading = readCaptionBlocks(document, pageState.siteName);
    if (reading.regionFound && reading.blocks.length > 0) {
      recordCaptionReading(pageState.captionBuffer, reading.blocks, now);
      pageState.captionsLastSeenAt = now;
      if (!pageState.captionsVisible) {
        pageState.captionsVisible = true;
        announceCaptionsAvailable();
      }
    } else if (pageState.captionsVisible && now - pageState.captionsLastSeenAt > CAPTIONS_GONE_MILLISECONDS) {
      pageState.captionsVisible = false;
    }
    pruneCaptionBuffer(pageState.captionBuffer, now);
  }

  function scheduleCaptionRead() {
    if (pageState.pendingReadTimer !== null) return;
    pageState.pendingReadTimer = setTimeout(readCaptionsNow, READ_DEBOUNCE_MILLISECONDS);
  }

  // What `getMeetingCaptions` returns, read from this page's own buffer.
  function readBuffer(lastMinutes) {
    const now = Date.now();
    if (!pageState.siteName || !pageState.captionBuffer) {
      return { site: "", captionsFound: false, captionsVisible: false, entries: [], requestedMinutes: 0, bufferStartedAt: 0, truncated: false };
    }
    readCaptionsNow();
    const windowed = captionEntriesWithin(pageState.captionBuffer, lastMinutes, now);
    return {
      site: pageState.siteName,
      captionsFound: windowed.entries.length > 0 || pageState.captionsVisible,
      captionsVisible: pageState.captionsVisible,
      entries: windowed.entries,
      requestedMinutes: windowed.requestedMinutes,
      bufferStartedAt: pageState.captionBuffer.startedAt,
      truncated: windowed.truncated,
    };
  }

  function startWatchingCaptions() {
    if (typeof document === "undefined" || typeof location === "undefined") return;
    const siteName = siteForHost(location.hostname);
    if (!siteName) return;
    pageState.siteName = siteName;
    pageState.captionBuffer = createCaptionBuffer(Date.now());
    // Mutations (not throttled in a background tab) schedule a read; the
    // interval is a backstop for a caption area that appears without one.
    new MutationObserver(scheduleCaptionRead).observe(document.documentElement, {
      subtree: true,
      childList: true,
      characterData: true,
    });
    setInterval(readCaptionsNow, BACKSTOP_READ_INTERVAL_MILLISECONDS);
    readCaptionsNow();
  }

  globalThis.wispMeetingCaptions = {
    readBuffer,
    siteForHost,
    readCaptionBlocks,
    mergeCaptionText,
    createCaptionBuffer,
    recordCaptionReading,
    pruneCaptionBuffer,
    captionEntriesWithin,
    CAPTION_SITE_SELECTORS,
  };

  // Only in a real meeting tab; the tests import this file with no page.
  if (globalThis.chrome?.runtime?.id) {
    startWatchingCaptions();
  }
})();

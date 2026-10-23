// Wisp Tabs — reads a Canvas assignment page (phase 10, site helpers).
//
// On an assignment page (`/courses/<id>/assignments/<id>`) this reads what a
// student needs to plan the work: the title, due date, points, the rubric's
// criteria and the description. Wisp then says whether it's already on today's
// checklist, adds it there, or proposes study blocks for it.
//
// Two ways in:
//   - Registered with `chrome.scripting.registerContentScripts` once the user
//     allows `pages.read` (events/site-helpers.js). Then it runs by itself on
//     every page whose path looks like an assignment, checks the page really is
//     Canvas (Canvas runs on many school domains, so the host alone can't tell),
//     and tells the service worker the assignment opened. Wisp decides whether
//     the host is one it trusts as Canvas (`*.instructure.com`, or the host of
//     the user's saved Canvas feed); the extension never sees that feed.
//   - Injected on demand by handlers/site-helpers.js, which then calls
//     `globalThis.wispCanvasAssignment.readAssignment(document, url)`.
//
// Classic script (content scripts can't be modules), run in the extension's
// isolated world. Every reading function takes the document as a parameter, so
// the tests run them against fixture HTML with no browser.
//
// Never reads secrets (contracts.md §6): form controls and `[data-wisp-ignore]`
// are dropped before any text is read.

(() => {
  // Injected twice (registered, then on demand): the first copy stays.
  if (globalThis.wispCanvasAssignment) return;

  const MAXIMUM_DESCRIPTION_CHARACTERS = 8000;
  const MAXIMUM_TITLE_CHARACTERS = 300;
  const MAXIMUM_RUBRIC_CRITERIA = 40;
  const MAXIMUM_CRITERION_CHARACTERS = 200;

  // Every selector this script relies on, in one place: Canvas's markup
  // changes between releases and between the classic and the newer student
  // view, so each field lists what to try, most specific first.
  const CANVAS_SELECTORS = {
    // Either is only on Canvas pages.
    canvasPageMarkers: ["#application.ic-app", "body[class*='context-course_']"],
    title: [
      "#assignment_show h1.title",
      ".assignment-title h1",
      "[data-testid='assignment-student-header'] h1",
      "[data-testid='title']",
      "#content h1",
    ],
    // The classic student view: <li><span class="title">Due</span><span class="value">…</span></li>.
    overviewRows: ["ul.student-assignment-overview > li", ".assignment_dates tr"],
    overviewRowLabel: [".title", "th"],
    overviewRowValue: [".value", "td"],
    // The newer student view puts the due date in its header.
    dueDateFallbacks: [
      "[data-testid='assignment-student-header-date-title']",
      "[data-testid='due-date']",
      ".assignment-date-due",
    ],
    pointsFallbacks: ["[data-testid='assignment-student-header-points']", ".points_possible"],
    description: ["#assignment_show .description.user_content", "#assignment_show .description", ".description.user_content", "[data-testid='assignments-2-assignment-description']"],
    rubricCriteria: ["#rubrics tr.criterion:not(.blank)", ".rubric_table tr.criterion:not(.blank)", "[data-testid='rubric-criterion']"],
    rubricCriterionName: [".description_title", ".criterion_description .description", "[data-testid='criterion-description']"],
    rubricCriterionPoints: [".criterion_points", ".points_form", "[data-testid='criterion-points']"],
    rubricTotal: [".rubric_total", "[data-testid='rubric-total']"],
    courseName: ["#breadcrumbs li:nth-child(2) a span", "#breadcrumbs li:nth-child(2) a"],
    // Dropped before reading any text, so a field's value is never read.
    neverRead: "input, textarea, select, option, button, script, style, noscript, template, [data-wisp-ignore], [contenteditable='true']",
  };

  const ASSIGNMENT_PATH_PATTERN = /^\/courses\/(\d+)\/assignments\/(\d+)(?:\/|$)/;

  const MONTH_INDEX_BY_NAME = {
    jan: 0, january: 0, feb: 1, february: 1, mar: 2, march: 2, apr: 3, april: 3, may: 4,
    jun: 5, june: 5, jul: 6, july: 6, aug: 7, august: 7, sep: 8, sept: 8, september: 8,
    oct: 9, october: 9, nov: 10, november: 10, dec: 11, december: 11,
  };

  function firstMatch(rootNode, selectors) {
    for (const selector of selectors) {
      const element = rootNode.querySelector(selector);
      if (element) return element;
    }
    return null;
  }

  function allMatches(rootNode, selectors) {
    for (const selector of selectors) {
      const elements = [...rootNode.querySelectorAll(selector)];
      if (elements.length > 0) return elements;
    }
    return [];
  }

  function collapsedWhitespace(text) {
    return String(text ?? "").replace(/\s+/g, " ").trim();
  }

  // The element's visible-ish text with form controls and ignored regions
  // removed: read from a clone so the page itself is never changed.
  function safeText(element) {
    if (!element) return "";
    if (element.closest("[data-wisp-ignore]")) return "";
    const clonedElement = element.cloneNode(true);
    for (const unreadableElement of clonedElement.querySelectorAll(CANVAS_SELECTORS.neverRead)) {
      unreadableElement.remove();
    }
    return clonedElement.textContent ?? "";
  }

  // Description text keeps paragraph breaks; everything else is one line.
  function safeParagraphText(element) {
    if (!element || element.closest("[data-wisp-ignore]")) return "";
    const clonedElement = element.cloneNode(true);
    for (const unreadableElement of clonedElement.querySelectorAll(CANVAS_SELECTORS.neverRead)) {
      unreadableElement.remove();
    }
    const paragraphs = [];
    const blockElements = clonedElement.querySelectorAll("p, li, h1, h2, h3, h4, h5, h6, pre, blockquote, tr");
    if (blockElements.length === 0) {
      return collapsedWhitespace(clonedElement.textContent);
    }
    for (const blockElement of blockElements) {
      // A block nested in another block is read with its parent. The clone
      // is detached, so `closest` never reaches past it into the page.
      if (blockElement.parentElement?.closest("p, li, pre, blockquote, tr")) {
        continue;
      }
      const blockText = collapsedWhitespace(blockElement.textContent);
      if (!blockText) continue;
      const tagName = blockElement.tagName.toLowerCase();
      paragraphs.push(tagName === "li" ? `- ${blockText}` : blockText);
    }
    return paragraphs.join("\n");
  }

  function capped(text, maximumCharacters) {
    if (text.length <= maximumCharacters) return { text, truncated: false };
    return { text: text.slice(0, maximumCharacters), truncated: true };
  }

  // "Oct 25 at 11:59pm", "Oct 25, 2026 11:59pm", "Due: Sat Oct 25, 2026 by 11:59 PM",
  // "October 25" → a local Date, or null. Canvas leaves the year out when the
  // date is this year, so the year is the one that puts the date nearest `now`.
  function parseCanvasDueText(dueText, now = new Date()) {
    const text = collapsedWhitespace(dueText).toLowerCase();
    const datePattern =
      /\b(jan(?:uary)?|feb(?:ruary)?|mar(?:ch)?|apr(?:il)?|may|june?|july?|aug(?:ust)?|sept?(?:ember)?|oct(?:ober)?|nov(?:ember)?|dec(?:ember)?)\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?(?:\s*(?:at|by|,)?\s*(\d{1,2})(?::(\d{2}))?\s*(am|pm|a\.m\.|p\.m\.))?/;
    const dateMatch = text.match(datePattern);
    if (!dateMatch) return null;

    const monthIndex = MONTH_INDEX_BY_NAME[dateMatch[1]];
    const dayOfMonth = Number(dateMatch[2]);
    if (monthIndex === undefined || dayOfMonth < 1 || dayOfMonth > 31) return null;

    let hour = 23;
    let minute = 59;
    if (dateMatch[4]) {
      hour = Number(dateMatch[4]) % 12;
      minute = dateMatch[5] ? Number(dateMatch[5]) : 0;
      if (dateMatch[6].startsWith("p")) hour += 12;
      if (hour > 23 || minute > 59) return null;
    }

    const buildDate = (year) => new Date(year, monthIndex, dayOfMonth, hour, minute, 0, 0);
    if (dateMatch[3]) {
      const explicitDate = buildDate(Number(dateMatch[3]));
      return explicitDate.getDate() === dayOfMonth ? explicitDate : null;
    }
    const halfYearMilliseconds = 183 * 24 * 3600 * 1000;
    let candidateDate = buildDate(now.getFullYear());
    if (candidateDate.getTime() < now.getTime() - halfYearMilliseconds) {
      candidateDate = buildDate(now.getFullYear() + 1);
    } else if (candidateDate.getTime() > now.getTime() + halfYearMilliseconds) {
      candidateDate = buildDate(now.getFullYear() - 1);
    }
    return candidateDate.getDate() === dayOfMonth ? candidateDate : null;
  }

  function isCanvasPage(pageDocument) {
    return CANVAS_SELECTORS.canvasPageMarkers.some((selector) => pageDocument.querySelector(selector));
  }

  // `{courseId, assignmentId}` from an assignment page's path, or null.
  function assignmentPathIDs(pageURL) {
    let parsedURL;
    try {
      parsedURL = new URL(pageURL);
    } catch (error) {
      return null;
    }
    const pathMatch = parsedURL.pathname.match(ASSIGNMENT_PATH_PATTERN);
    return pathMatch ? { courseId: pathMatch[1], assignmentId: pathMatch[2] } : null;
  }

  // Label → value rows of the classic overview list ("Due", "Points", "Submitting").
  function overviewValues(pageDocument) {
    const valuesByLabel = {};
    for (const rowElement of allMatches(pageDocument, CANVAS_SELECTORS.overviewRows)) {
      const labelText = collapsedWhitespace(safeText(firstMatch(rowElement, CANVAS_SELECTORS.overviewRowLabel))).toLowerCase();
      const valueElement = firstMatch(rowElement, CANVAS_SELECTORS.overviewRowValue);
      if (!labelText || !valueElement) continue;
      valuesByLabel[labelText] = { text: collapsedWhitespace(safeText(valueElement)), element: valueElement };
    }
    return valuesByLabel;
  }

  function dueDetails(pageDocument, overview, now) {
    const dueValue = overview["due"] ?? overview["due date"];
    const dueElement = dueValue?.element ?? firstMatch(pageDocument, CANVAS_SELECTORS.dueDateFallbacks);
    if (!dueElement) return { dueText: "", dueAt: "" };
    // A machine-readable time wins over reading the words.
    const timeElement = dueElement.matches?.("time[datetime]") ? dueElement : dueElement.querySelector("time[datetime]");
    const dueText = collapsedWhitespace(safeText(dueElement)).replace(/^due:?\s*/i, "");
    if (timeElement) {
      const machineDate = new Date(timeElement.getAttribute("datetime"));
      if (!Number.isNaN(machineDate.getTime())) return { dueText, dueAt: machineDate.toISOString() };
    }
    const parsedDate = parseCanvasDueText(dueText, now);
    return { dueText, dueAt: parsedDate ? parsedDate.toISOString() : "" };
  }

  function pointsText(pageDocument, overview) {
    const pointsValue = overview["points"] ?? overview["points possible"];
    const rawText = pointsValue?.text ?? collapsedWhitespace(safeText(firstMatch(pageDocument, CANVAS_SELECTORS.pointsFallbacks)));
    const numberMatch = rawText.match(/\d+(?:\.\d+)?/);
    return numberMatch ? numberMatch[0] : "";
  }

  function rubricDetails(pageDocument) {
    const criteria = [];
    for (const criterionElement of allMatches(pageDocument, CANVAS_SELECTORS.rubricCriteria)) {
      if (criteria.length >= MAXIMUM_RUBRIC_CRITERIA) break;
      const criterionName = collapsedWhitespace(safeText(firstMatch(criterionElement, CANVAS_SELECTORS.rubricCriterionName)));
      if (!criterionName) continue;
      const pointsMatch = collapsedWhitespace(safeText(firstMatch(criterionElement, CANVAS_SELECTORS.rubricCriterionPoints))).match(/\d+(?:\.\d+)?/);
      criteria.push({
        criterion: capped(criterionName, MAXIMUM_CRITERION_CHARACTERS).text,
        points: pointsMatch ? pointsMatch[0] : "",
      });
    }
    const totalMatch = collapsedWhitespace(safeText(firstMatch(pageDocument, CANVAS_SELECTORS.rubricTotal))).match(/\d+(?:\.\d+)?/);
    return { rubric: criteria, rubricTotal: totalMatch ? totalMatch[0] : "" };
  }

  // Everything the page says about the assignment. `isCanvasPage: false` when
  // it isn't Canvas or isn't an assignment page, and then nothing else is read.
  function readAssignment(pageDocument, pageURL, now = new Date()) {
    const pathIDs = assignmentPathIDs(pageURL);
    if (!pathIDs || !isCanvasPage(pageDocument)) {
      return { isCanvasPage: false };
    }
    const overview = overviewValues(pageDocument);
    const titleElement = firstMatch(pageDocument, CANVAS_SELECTORS.title);
    const titleText = collapsedWhitespace(safeText(titleElement)) || collapsedWhitespace(pageDocument.title);
    const { dueText, dueAt } = dueDetails(pageDocument, overview, now);
    const { rubric, rubricTotal } = rubricDetails(pageDocument);
    const description = capped(safeParagraphText(firstMatch(pageDocument, CANVAS_SELECTORS.description)), MAXIMUM_DESCRIPTION_CHARACTERS);
    const submittingValue = overview["submitting"];

    return {
      isCanvasPage: true,
      courseId: pathIDs.courseId,
      assignmentId: pathIDs.assignmentId,
      title: capped(titleText, MAXIMUM_TITLE_CHARACTERS).text,
      courseName: capped(collapsedWhitespace(safeText(firstMatch(pageDocument, CANVAS_SELECTORS.courseName))), MAXIMUM_TITLE_CHARACTERS).text,
      dueText: capped(dueText, 200).text,
      dueAt,
      pointsPossible: pointsText(pageDocument, overview),
      submissionTypes: capped(submittingValue?.text ?? "", 200).text,
      rubric,
      rubricTotal,
      description: description.text,
      truncated: description.truncated,
    };
  }

  globalThis.wispCanvasAssignment = { readAssignment, parseCanvasDueText, isCanvasPage, assignmentPathIDs, CANVAS_SELECTORS };

  // Running as a registered content script in a real tab: tell the service
  // worker an assignment opened (it adds the tab id and passes it to Wisp).
  // Only the title and due date travel; the rest is read when Wisp asks.
  const runtimeAPI = globalThis.chrome?.runtime;
  if (runtimeAPI?.id && typeof document !== "undefined" && typeof location !== "undefined") {
    const assignmentDetails = readAssignment(document, location.href);
    if (assignmentDetails.isCanvasPage) {
      try {
        runtimeAPI.sendMessage({
          type: "wisp.site.canvasAssignmentOpened",
          title: assignmentDetails.title,
          dueAt: assignmentDetails.dueAt,
        });
      } catch (error) {
        // The extension was reloaded under this page; nothing to tell.
      }
    }
  }
})();

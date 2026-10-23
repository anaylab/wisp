// Wisp Tabs — site helpers: Canvas assignment pages and meeting captions (phase 10).
//
//   getCanvasAssignmentDetails({tabId?})
//     The assignment a Canvas tab shows: title, due date, points, rubric
//     criteria, description. Wisp checks it against today's checklist and the
//     "Wisp" calendar, adds it to today, or plans study blocks for it.
//   getMeetingCaptions({tabId?, lastMinutes?})
//     The captions a Google Meet (or Zoom web) tab has shown in the last
//     `lastMinutes` (1–30), from the page's own rolling buffer. "What did I
//     miss" summarizes them. Never audio: only caption text the user turned on.
//
// The reading itself is in content/canvas-assignment.js and
// content/meeting-captions.js. Both are registered to run on their pages once
// `pages.read` is allowed (events/site-helpers.js), and injected here too, so a
// tab opened before the permission was granted still works. Injecting twice is
// a no-op: each script keeps its first copy (and the captions keep their buffer).
//
// Needs the `pages.read` capability. Refuses incognito tabs and pages the
// extension must never read (contracts.md §6), like page reading does.

import { computeCapabilities, CAPABILITY_PAGES_READ } from "../lib/capabilities.js";
import { truncateText, capList } from "../lib/limits.js";
import { forbiddenPageReason } from "./page-reading.js";

export const CANVAS_ASSIGNMENT_SCRIPT_FILE = "content/canvas-assignment.js";
export const MEETING_CAPTIONS_SCRIPT_FILE = "content/meeting-captions.js";
export const MISSING_PAGES_READ_ERROR = `missing capability ${CAPABILITY_PAGES_READ}`;

const CANVAS_ASSIGNMENT_PATH_PATTERN = /^\/courses\/\d+\/assignments\/\d+(?:\/|$)/;
// A Meet call's address is its code ("abc-defg-hij"); the landing page isn't a call.
const MEET_CALL_PATH_PATTERN = /^\/[a-z]{3,}-[a-z]{3,}-[a-z]{3,}(?:[/?#]|$)/i;
const ZOOM_WEB_CLIENT_PATH_PATTERN = /^\/wc\//i;

export function isCanvasAssignmentURL(pageURL) {
  try {
    const parsedURL = new URL(pageURL);
    return parsedURL.protocol === "https:" && CANVAS_ASSIGNMENT_PATH_PATTERN.test(parsedURL.pathname);
  } catch (error) {
    return false;
  }
}

// "meet", "zoom" or null: whether a tab's address is a call whose captions
// Wisp can read.
export function meetingSiteForURL(pageURL) {
  let parsedURL;
  try {
    parsedURL = new URL(pageURL);
  } catch (error) {
    return null;
  }
  if (parsedURL.protocol !== "https:") return null;
  const hostname = parsedURL.hostname.toLowerCase();
  if (hostname === "meet.google.com" && MEET_CALL_PATH_PATTERN.test(parsedURL.pathname)) return "meet";
  if ((hostname === "zoom.us" || hostname.endsWith(".zoom.us")) && ZOOM_WEB_CLIENT_PATH_PATTERN.test(parsedURL.pathname)) return "zoom";
  return null;
}

async function requirePagesReadCapability() {
  const capabilities = await computeCapabilities(chrome);
  if (!capabilities.includes(CAPABILITY_PAGES_READ)) {
    throw new Error(MISSING_PAGES_READ_ERROR);
  }
}

async function showingTab() {
  const lastFocusedWindow = await chrome.windows.getLastFocused({ windowTypes: ["normal"] });
  const activeTabs = await chrome.tabs.query({ active: true, windowId: lastFocusedWindow.id });
  return activeTabs.find((tab) => tab.active && tab.windowId === lastFocusedWindow.id) ?? null;
}

async function requestedTab(tabId) {
  if (!Number.isInteger(tabId)) {
    throw new Error("tabId must be a tab id");
  }
  return chrome.tabs.get(tabId);
}

function refuseUnreadableTab(tab) {
  if (tab.incognito) {
    throw new Error("wisp doesn't read incognito tabs");
  }
  // Both helpers only ever read https pages, so file:// access never applies.
  const refusalReason = forbiddenPageReason(tab.url || tab.pendingUrl || "", { isFileSchemeAccessAllowed: false });
  if (refusalReason) {
    throw new Error(refusalReason);
  }
}

// Injects a helper script (a no-op when it's already there) and calls one of
// its functions in the tab's top frame.
async function runHelperInTab(tab, scriptFile, globalName, functionName, functionArguments) {
  let injectionResults;
  try {
    await chrome.scripting.executeScript({ target: { tabId: tab.id }, files: [scriptFile] });
    injectionResults = await chrome.scripting.executeScript({
      target: { tabId: tab.id },
      // Serialised by Chrome and run in the isolated world where the file
      // above defined the helper. It closes over nothing.
      func: (helperGlobalName, helperFunctionName, helperArguments) => {
        const helper = globalThis[helperGlobalName];
        if (!helper) return null;
        if (helperFunctionName === "readAssignment") return helper.readAssignment(document, location.href);
        return helper[helperFunctionName](...helperArguments);
      },
      args: [globalName, functionName, functionArguments ?? []],
    });
  } catch (error) {
    throw new Error(`couldn't read the page: ${String(error?.message ?? error)}`);
  }
  const helperResult = injectionResults?.[0]?.result;
  if (!helperResult || typeof helperResult !== "object") {
    throw new Error("couldn't read the page: it returned nothing");
  }
  return helperResult;
}

function cappedString(value, maximumCharacters) {
  return truncateText(typeof value === "string" ? value : "", maximumCharacters).text;
}

// The meeting tab to read when Wisp didn't name one: the showing tab if it's
// a call, else an audible call, else the call used most recently.
async function findMeetingTab() {
  const currentlyShowingTab = await showingTab();
  if (currentlyShowingTab && !currentlyShowingTab.incognito && meetingSiteForURL(currentlyShowingTab.url)) {
    return currentlyShowingTab;
  }
  const meetingTabs = (await chrome.tabs.query({})).filter((tab) => !tab.incognito && meetingSiteForURL(tab.url));
  meetingTabs.sort((firstTab, secondTab) => {
    if (Boolean(firstTab.audible) !== Boolean(secondTab.audible)) return firstTab.audible ? -1 : 1;
    return (secondTab.lastAccessed ?? 0) - (firstTab.lastAccessed ?? 0);
  });
  return meetingTabs[0] ?? null;
}

export const siteHelperHandlers = {
  async getCanvasAssignmentDetails({ tabId } = {}) {
    await requirePagesReadCapability();
    const tab = tabId === undefined || tabId === null ? await showingTab() : await requestedTab(tabId);
    if (!tab) {
      throw new Error("there's no tab showing in chrome");
    }
    refuseUnreadableTab(tab);
    if (!isCanvasAssignmentURL(tab.url)) {
      throw new Error("this tab isn't a canvas assignment page");
    }

    const assignment = await runHelperInTab(tab, CANVAS_ASSIGNMENT_SCRIPT_FILE, "wispCanvasAssignment", "readAssignment", []);
    if (!assignment.isCanvasPage) {
      throw new Error("this tab isn't a canvas assignment page");
    }
    const cappedRubric = capList(
      (Array.isArray(assignment.rubric) ? assignment.rubric : [])
        .filter((criterion) => criterion && typeof criterion.criterion === "string")
        .map((criterion) => ({ criterion: cappedString(criterion.criterion, 200), points: cappedString(criterion.points, 20) })),
      40
    );
    const cappedDescription = truncateText(typeof assignment.description === "string" ? assignment.description : "", 8000);
    return {
      tabId: tab.id,
      windowId: tab.windowId,
      url: cappedString(tab.url, 2000),
      courseId: cappedString(assignment.courseId, 20),
      assignmentId: cappedString(assignment.assignmentId, 20),
      title: cappedString(assignment.title, 300),
      courseName: cappedString(assignment.courseName, 300),
      dueText: cappedString(assignment.dueText, 200),
      dueAt: cappedString(assignment.dueAt, 40),
      pointsPossible: cappedString(assignment.pointsPossible, 20),
      submissionTypes: cappedString(assignment.submissionTypes, 200),
      rubric: cappedRubric.items,
      rubricTotal: cappedString(assignment.rubricTotal, 20),
      description: cappedDescription.text,
      truncated: Boolean(assignment.truncated) || cappedDescription.truncated || cappedRubric.truncated,
    };
  },

  async getMeetingCaptions({ tabId, lastMinutes } = {}) {
    await requirePagesReadCapability();
    const tab = tabId === undefined || tabId === null ? await findMeetingTab() : await requestedTab(tabId);
    if (!tab) {
      throw new Error("there's no google meet or zoom call open in chrome");
    }
    refuseUnreadableTab(tab);
    const site = meetingSiteForURL(tab.url);
    if (!site) {
      throw new Error("that tab isn't a google meet or zoom call");
    }

    const requestedMinutes = Number.isFinite(lastMinutes) ? lastMinutes : 30;
    const buffer = await runHelperInTab(tab, MEETING_CAPTIONS_SCRIPT_FILE, "wispMeetingCaptions", "readBuffer", [requestedMinutes]);
    const cappedEntries = capList(
      (Array.isArray(buffer.entries) ? buffer.entries : [])
        .filter((entry) => entry && typeof entry.text === "string" && entry.text.length > 0)
        .map((entry) => ({
          speaker: cappedString(entry.speaker, 80),
          text: cappedString(entry.text, 20000),
          startedAt: Number.isFinite(entry.startedAt) ? entry.startedAt : 0,
          endedAt: Number.isFinite(entry.endedAt) ? entry.endedAt : 0,
        }))
    );
    return {
      tabId: tab.id,
      windowId: tab.windowId,
      url: cappedString(tab.url, 2000),
      title: cappedString(tab.title, 300),
      site,
      captionsFound: Boolean(buffer.captionsFound),
      captionsVisible: Boolean(buffer.captionsVisible),
      entries: cappedEntries.items,
      requestedMinutes: Number.isFinite(buffer.requestedMinutes) ? buffer.requestedMinutes : 0,
      bufferStartedAt: Number.isFinite(buffer.bufferStartedAt) ? buffer.bufferStartedAt : 0,
      truncated: Boolean(buffer.truncated) || cappedEntries.truncated,
    };
  },
};

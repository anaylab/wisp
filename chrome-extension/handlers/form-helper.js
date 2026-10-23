// Wisp Tabs — the form helper (phase 12).
//
// `describeForm` lists a form's fields (never their values) so Wisp can propose
// what to type from what it knows about the user; `fillFormFields` types the
// values the user allowed on Wisp's card. The page work is in
// content/form-helper.js, which rides on content/dom-agent.js for its element
// ids and React-safe setter; both are injected on demand into the top frame.
//
// What this file adds on top of the content script's own refusals:
//  * the page rules (lib/page-access.js): only ordinary web pages, never
//    incognito, never Chrome's own pages, never file://;
//  * `fillFormFields` refuses when the tab has moved to another page since Wisp
//    looked (`expectedUrl`), so values the user allowed for one site are never
//    typed into another;
//  * the request's shape: top-frame `e` ids only, plain strings, capped.
//
// Nothing here clicks, submits or presses a key. The user presses the page's
// own button.

import { truncateText } from "../lib/limits.js";
import { PAGE_ACCESS_ACT, pageAccessForURL } from "../lib/page-access.js";
import { DOM_AGENT_FILE } from "./dom-controller.js";

export const FORM_HELPER_FILE = "content/form-helper.js";
export const MAXIMUM_FILL_VALUES = 60;
export const MAXIMUM_FILL_VALUE_CHARACTERS = 2000;

const TOP_FRAME_ELEMENT_ID_PATTERN = /^e\d{1,9}$/;

// Runs inside the page (serialised by executeScript), so it must be
// self-contained. NOT_INSTALLED is the cue to inject both scripts and ask again.
function invokeWispFormHelperMethod(methodName, methodArguments) {
  const formHelper = window.__wispFormHelper;
  if (!window.__wispAgent || !formHelper || typeof formHelper[methodName] !== "function") {
    return { status: "NOT_INSTALLED" };
  }
  try {
    return formHelper[methodName](methodArguments);
  } catch (error) {
    return { status: "FAILED", detail: String((error && error.message) || error) };
  }
}

// The page a URL shows, for "is this still the page Wisp described": origin and
// path, ignoring the hash and query (a form that writes its state into the
// query string is still the same form).
export function samePage(firstURL, secondURL) {
  try {
    const first = new URL(firstURL);
    const second = new URL(secondURL);
    return first.origin === second.origin && first.pathname === second.pathname;
  } catch (error) {
    return false;
  }
}

// The values Wisp asked to type, cleaned; anything malformed is dropped rather
// than guessed at, and reported back as such.
export function validatedFillValues(values) {
  if (!Array.isArray(values)) return { accepted: [], rejected: [] };
  const accepted = [];
  const rejected = [];
  const seenElementIDs = new Set();
  for (const entry of values.slice(0, MAXIMUM_FILL_VALUES)) {
    const elementId = typeof entry?.elementId === "string" ? entry.elementId.trim() : "";
    const value = typeof entry?.value === "string" ? entry.value : null;
    if (!TOP_FRAME_ELEMENT_ID_PATTERN.test(elementId) || seenElementIDs.has(elementId) ||
        value === null || value.trim() === "" || value.length > MAXIMUM_FILL_VALUE_CHARACTERS) {
      rejected.push({ elementId: elementId || String(entry?.elementId ?? ""), status: "badRequest" });
      continue;
    }
    seenElementIDs.add(elementId);
    accepted.push({ elementId, value });
  }
  return { accepted, rejected };
}

export function createFormHelperHandlers({ chromeAPI = () => globalThis.chrome } = {}) {
  async function resolveTargetTab(tabId) {
    const chrome = chromeAPI();
    let tab;
    if (Number.isInteger(tabId)) {
      tab = await chrome.tabs.get(tabId);
    } else {
      const activeTabs = await chrome.tabs.query({ active: true, lastFocusedWindow: true, windowType: "normal" });
      tab = activeTabs[0];
      if (!tab) throw new Error("no chrome tab is open");
    }
    if (tab.incognito) throw new Error("wisp never reads or acts in incognito tabs");
    return tab;
  }

  // Forms are filled on ordinary web pages only: never Chrome's own pages,
  // the Web Store, local files or a blank tab.
  function requireFillablePage(tab) {
    if (pageAccessForURL(tab.url ?? tab.pendingUrl ?? "") !== PAGE_ACCESS_ACT) {
      throw new Error("wisp only fills forms on ordinary web pages");
    }
  }

  async function callFormHelper(tabId, methodName, methodArguments) {
    const chrome = chromeAPI();
    if (!chrome.scripting?.executeScript) {
      throw new Error("missing capability pages.read — open the wisp tabs options and allow reading pages");
    }
    const target = { tabId, frameIds: [0] };
    const invoke = async () => {
      const injectionResults = await chrome.scripting.executeScript({
        target,
        func: invokeWispFormHelperMethod,
        args: [methodName, methodArguments ?? {}],
      });
      return injectionResults?.[0]?.result;
    };
    let helperResult = await invoke();
    if (helperResult?.status === "NOT_INSTALLED") {
      await chrome.scripting.executeScript({ target, files: [DOM_AGENT_FILE, FORM_HELPER_FILE] });
      helperResult = await invoke();
    }
    return helperResult ?? { status: "NO_RESULT" };
  }

  return {
    // The fields of the form in front of the user (or the form holding
    // `formElementId`): id, label, kind, autocomplete, required, options, and
    // whether something is typed in it — never what.
    async describeForm({ tabId, formElementId } = {}) {
      const tab = await resolveTargetTab(tabId);
      requireFillablePage(tab);
      if (formElementId !== undefined && formElementId !== null &&
          !(typeof formElementId === "string" && TOP_FRAME_ELEMENT_ID_PATTERN.test(formElementId))) {
        throw new Error("that isn't a form wisp can see");
      }
      const description = await callFormHelper(tab.id, "describeForm", { formElementId: formElementId ?? null });
      if (description.status === "MISSING" || description.status === "NOT_A_FORM") {
        throw new Error("that isn't a form wisp can see");
      }
      if (description.status !== "OK") throw new Error("couldn't read the form on this page");
      const result = {
        tabId: tab.id,
        windowId: tab.windowId,
        url: truncateText(description.url ?? tab.url ?? "").text,
        title: truncateText(description.title ?? tab.title ?? "").text,
        formId: description.formId ?? null,
        formLabel: description.formLabel ?? "",
        fields: description.fields ?? [],
      };
      if (description.truncated) result.truncated = true;
      return result;
    },

    // Types the allowed values in. Refuses outright if the tab now shows
    // another page than `expectedUrl`; per field, the content script refuses
    // secrets and anything not a plain text field or select.
    async fillFormFields({ tabId, values, expectedUrl, onlyIntoEmptyFields = true } = {}) {
      if (!Number.isInteger(tabId)) throw new Error("wisp needs the tab the form is in");
      const tab = await resolveTargetTab(tabId);
      requireFillablePage(tab);
      if (typeof expectedUrl !== "string" || !samePage(expectedUrl, tab.url ?? "")) {
        throw new Error("that tab moved to another page since wisp looked at the form, so nothing was filled");
      }
      const { accepted, rejected } = validatedFillValues(values);
      if (accepted.length === 0) {
        return { tabId: tab.id, results: rejected, filledCount: 0 };
      }
      const fillResult = await callFormHelper(tab.id, "fillFields", {
        values: accepted,
        onlyIntoEmptyFields: onlyIntoEmptyFields !== false,
      });
      if (fillResult.status !== "OK") throw new Error("couldn't fill the form on this page");
      return {
        tabId: tab.id,
        results: [...(fillResult.results ?? []), ...rejected],
        filledCount: fillResult.filledCount ?? 0,
      };
    },
  };
}

export const formHelperHandlers = createFormHelperHandlers();

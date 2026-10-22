// The permissions page. Chrome only shows a permission prompt after a click
// inside an extension page, which is why this page exists: Wisp's Settings
// button opens it (`openPermissionsPage`), and the user clicks Allow here.
//
// Granting or removing fires chrome.permissions.onAdded / onRemoved, which the
// service worker turns into a `capabilities` message for Wisp, so Wisp's
// Settings card updates on its own.

import {
  CAPABILITY_DOWNLOADS,
  CAPABILITY_PAGES_READ,
  OPTIONAL_CAPABILITY_PERMISSIONS,
  computeCapabilities,
} from "./lib/capabilities.js";

const OPTIONAL_CAPABILITY_DESCRIPTIONS = [
  {
    capability: CAPABILITY_PAGES_READ,
    name: "Read pages",
    detail:
      "Read the text of a page when you ask about it, so Wisp can summarize or answer without a screenshot. Never password or payment fields, and never incognito.",
  },
  {
    capability: CAPABILITY_DOWNLOADS,
    name: "Downloads",
    detail: "Notice when a download finishes, so Wisp can offer to rename it, file it or add it to your brain.",
  },
];

const capabilityList = document.getElementById("capabilityList");

function renderCapabilities(grantedCapabilities) {
  capabilityList.replaceChildren(
    ...OPTIONAL_CAPABILITY_DESCRIPTIONS.map((description) =>
      capabilityRow(description, grantedCapabilities.includes(description.capability))
    )
  );
}

function capabilityRow({ capability, name, detail }, isGranted) {
  const row = document.createElement("div");
  row.className = "capability";

  const textColumn = document.createElement("div");
  textColumn.className = "capability-text";

  const nameLine = document.createElement("div");
  nameLine.className = "capability-name";
  nameLine.append(name);
  const stateLabel = document.createElement("span");
  stateLabel.className = isGranted ? "capability-state granted" : "capability-state";
  stateLabel.textContent = isGranted ? "Allowed" : "Off";
  nameLine.append(stateLabel);

  const detailLine = document.createElement("p");
  detailLine.className = "capability-detail";
  detailLine.textContent = detail;
  textColumn.append(nameLine, detailLine);

  const toggleButton = document.createElement("button");
  toggleButton.textContent = isGranted ? "Remove" : "Allow";
  toggleButton.className = isGranted ? "" : "allow";
  toggleButton.addEventListener("click", async () => {
    toggleButton.disabled = true;
    const requiredPermissions = OPTIONAL_CAPABILITY_PERMISSIONS[capability];
    try {
      if (isGranted) {
        await chrome.permissions.remove(requiredPermissions);
      } else {
        // Must run inside this click: Chrome refuses the prompt otherwise.
        await chrome.permissions.request(requiredPermissions);
      }
    } finally {
      await refreshCapabilities();
    }
  });

  row.append(textColumn, toggleButton);
  return row;
}

async function refreshCapabilities() {
  renderCapabilities(await computeCapabilities(chrome));
}

// Also catches changes made in Chrome's own extension settings.
chrome.permissions.onAdded.addListener(refreshCapabilities);
chrome.permissions.onRemoved.addListener(refreshCapabilities);

refreshCapabilities();

// Shows whether the service worker currently holds a connection to Wisp.

const statusDot = document.getElementById("statusDot");
const statusTitle = document.getElementById("statusTitle");
const statusDetail = document.getElementById("statusDetail");
const reconnectButton = document.getElementById("reconnectButton");

function renderConnectionStatus(isConnectedToWisp) {
  statusDot.classList.toggle("connected", isConnectedToWisp);
  statusTitle.textContent = isConnectedToWisp ? "Connected to Wisp" : "Wisp isn't connected";
  statusDetail.textContent = isConnectedToWisp
    ? "Ask Wisp to “organize my tabs”, “group my tabs by site” or “close duplicate tabs”."
    : "Make sure Wisp is running on this Mac. The extension retries every 30 seconds.";
  reconnectButton.hidden = isConnectedToWisp;
}

async function refreshConnectionStatus() {
  const { isConnectedToWisp } = await chrome.storage.session.get("isConnectedToWisp");
  renderConnectionStatus(Boolean(isConnectedToWisp));
}

reconnectButton.addEventListener("click", async () => {
  statusTitle.textContent = "Connecting…";
  await chrome.runtime.sendMessage({ type: "reconnect" });
  // The socket opens asynchronously; give it a moment before re-reading.
  setTimeout(refreshConnectionStatus, 800);
});

chrome.storage.session.onChanged.addListener((changes) => {
  if ("isConnectedToWisp" in changes) {
    renderConnectionStatus(Boolean(changes.isConnectedToWisp.newValue));
  }
});

refreshConnectionStatus();

// Wisp Tabs — asking about, and asking for, what the extension may do.

import { computeCapabilities } from "../lib/capabilities.js";

export const capabilityHandlers = {
  // The same list `hello` carries, for when Wisp wants to check again.
  async getCapabilities() {
    return { capabilities: await computeCapabilities(chrome) };
  },

  // Wisp can't grant a permission: Chrome only shows its prompt after a click
  // inside an extension page. So Wisp's Settings button lands the user on the
  // options page, where the Allow buttons are.
  async openPermissionsPage() {
    await chrome.runtime.openOptionsPage();
    return { opened: true };
  },
};

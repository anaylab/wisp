// The fixture page behind Tests/ChromeExtDOMController/snapshot-fixture.json.
// dom-agent.test.mjs checks the content script still produces exactly that
// JSON, and the Swift suite checks it decodes to the page text Wisp's
// planners and prompts expect — so the two halves can't drift apart.

import { FakeDocument, el, makeSelect } from "./fake-dom.mjs";

export function buildSnapshotFixturePage() {
  const fakeDocument = new FakeDocument({ title: "Checkout", url: "https://shop.example/checkout", viewportHeight: 800, scrollHeight: 2400 });
  const passwordField = el("input", { attributes: { type: "password", "aria-label": "Password" } });
  passwordField.storedValue = "never-read";
  const emailField = el("input", { attributes: { type: "email", "aria-label": "Email" }, required: true });
  emailField.storedValue = "ada@example.com";
  const termsBox = el("input", { attributes: { type: "checkbox", "aria-label": "Accept terms" }, checked: true });
  fakeDocument.body.append(
    el("main", {},
      el("h1", { text: "Checkout" }),
      emailField,
      passwordField,
      makeSelect({ "aria-label": "Shipping" }, ["Standard", "Express"], 1),
      termsBox,
      el("a", { attributes: { href: "https://shop.example/cart" }, text: "Back to cart" }),
      el("p", { text: "Review your order." })
    ),
    el("div", { attributes: { role: "dialog", "aria-label": "Save card?" }, rect: { left: 300, top: 300, width: 300, height: 150 } },
      el("button", { text: "Not now" }),
      el("button", { text: "Save", disabled: true })
    )
  );
  return fakeDocument;
}

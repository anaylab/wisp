# Browser extension: the hands-on checklist

Every phase brief listed manual checks, and none of the sessions could run them: they need you at the Mac, in
your real browser, with your Canvas and a Meet call. This is all of them in one place, in an order that works in
one sitting (about an hour). Tick them off here; anything that fails is worth a note with what you said and what
happened.

What the sessions did instead is under each heading, so you know what has only been tested against fakes.

## 0. Before you start

- [ ] Build and run the branch in Xcode (⌘R). Launch the built app with `open -a`, not its binary.
- [ ] `chrome://extensions` → the **Wisp Tabs** card → reload. Version **2.0.0**, and **Service worker** shows no
      errors (click "Inspect views" → Console).
- [ ] The toolbar popup says **Connected** and lists `tabs`.
- [ ] Wisp → Settings → Agent → **Browser** shows "Google Chrome · v2.0.0", one Allow… per missing capability, the
      four feature rows, and "What Wisp can do in your browser" opens.
- [ ] Click **Allow…** next to Read pages: Chrome comes forward on the permissions page. Allow it; the card's row
      turns to Allowed without reopening Settings. Remove it on the same page; the row goes back. Allow it again,
      and allow Downloads.
- [ ] Quit Wisp. The popup shows not connected, and reconnects within 30s of relaunching Wisp.

*Tested by the sessions:* the node suites against a fake `chrome`, and phases 01/03/04/05/09 against headless Edge
with a small Node server playing Wisp. Never against the real Wisp and real Chrome.

## 1. Tabs (phases 01, 04, 09)

- [ ] "organize my tabs", "close duplicate tabs" and "mute my tabs" work as before; pinned tabs and your own
      groups stay put.
- [ ] Make a window with 2 groups. "save this window as test session", close the window, "restore test session":
      the groups come back with their titles and colours.
- [ ] "clean up old tabs" with nothing older than 14 days says so and shows no card.
- [ ] "triage my tabs": the card's numbers (duplicates, old tabs, groups) match what happens after Allow.
- [ ] With session auto-approve on (Settings → Agent), ask the agent to "close all my youtube tabs": a card still
      appears.
- [ ] Three groups and a YouTube tab playing: "focus on my essay for 1 minute". Off-task groups collapse, YouTube
      mutes, nothing closes. After the minute everything is back as it was.
- [ ] Start a 5-minute focus, quit Wisp, relaunch: the tabs are restored.

## 2. Reading pages (phase 02)

- [ ] On a long article, "summarize this page": History's step says the tab's text was read instead of a
      screenshot, and the answer is right.
- [ ] "What color is the header?" still uses the screenshot.
- [ ] Remove Read pages: "summarize this page" falls back to the screenshot, and asking the agent to read a tab
      explains how to allow it. Allow it again.
- [ ] "Add this page to my brain" creates a source page with clean text (Brain → Pages).

## 3. Wisp's own tab (phase 03)

- [ ] "Open youtube and search for lofi": it runs in a background tab inside the purple **Wisp** group while you
      stay on your tab.
- [ ] A form task on a React page (a GitHub issue draft; stop before submitting) types correctly.
- [ ] With auto-approve on, a "buy" or "send" button still raises the card.
- [ ] Remove Read pages mid-session: the next task uses AppleScript, no crash. Allow it again.
- [ ] A Safari task works as before.

## 4. Pointing in the page (phase 05)

- [ ] On a GitHub repo page, "where is the settings button?" draws a ring in the page; scrolling keeps it on the
      button.
- [ ] A 3-step walkthrough across two GitHub pages completes on your real clicks.
- [ ] In a non-browser app, pointing is unchanged.

## 5. Ask Wisp about this (phase 06)

With Wisp running, then again with Wisp quit (expect the toolbar's "!" badge):

- [ ] Right-click a selection → **Ask Wisp about "…"**: the composer opens with the "About: selected text" chip.
- [ ] Right-click an image → **Ask Wisp about this image**.
- [ ] Right-click a link → **Ask Wisp about this link**.
- [ ] Right-click the page → **Ask Wisp about this page** and **Add to Wisp brain**.
- [ ] Type `w what is this page about` in the address bar.
- [ ] Press ⌘⇧Y.
- [ ] Select text in a Google Doc and ask about it: a graceful "i couldn't read that selection" if the canvas
      hides it.
- [ ] Select text inside a form field and ask about it: Wisp reads it itself, or says it couldn't (the menu's copy
      of field text is no longer passed on).

## 6. Downloads (phase 07)

- [ ] Download a PDF from arxiv.org: the notch offers a name from the page title. **File** it.
- [ ] Download an image and **Just brain** it.
- [ ] Undo a filing from the report card within 10 minutes.
- [ ] A `.dmg` gets no suggestion beyond the cleaned name.

## 7. Watching pages (phase 08)

- [ ] On a GitHub Actions run page, "tell me when this tab says completed", then switch to another tab: it fires
      when the run completes.
- [ ] A price watch on a product page ("tell me when the price drops below $…") fires once.
- [ ] "if I'm on youtube for 1 minute, remind me to study" drafts the automation correctly; save it and it fires.

## 8. Canvas and meetings (phase 10)

- [ ] On one of your real Canvas assignment pages: "is this on my checklist?", then "add this to today", then
      "plan this" (the study-block card).
- [ ] Open an assignment that isn't on today's list: the "Add to today?" chip appears once.
- [ ] A Google Meet test call with captions on (press C), talk for 2 minutes, "what did I miss?".

## 9. Research (phase 11)

- [ ] With the local model: "research the best budget mechanical keyboards". The report appears on the Chat
      page; a citation opens the right tab at the quoted passage.
- [ ] Same with a cloud model selected.
- [ ] "done": tabs you didn't touch close; ones you used ask first.

*Tested by the sessions:* fabricated quotes are dropped (the hostile-provider suite drives the real code with a
stub model).

## 10. Forms (phase 12)

- [ ] Serve `chrome-extension/tests/fixtures/form.html` from localhost (`python3 -m http.server` in that folder),
      "fill this form": the card shows each value (editable), the password and card fields as "Won't fill", and
      nothing is submitted.
- [ ] One real contact form, stopping before submit.

*Tested by the sessions:* the content script against the fixture in a real Chromium page.

## 11. Other browsers (phase 13)

- [ ] Load the extension in Arc or Edge as well (each needs Read pages allowed separately). The Browser card lists
      both, with the correct names, and marks the one in use.
- [ ] With Edge in front, "summarize this tab" reads Edge's tab; switch to Chrome and it reads Chrome's.
- [ ] Start "research …" in Chrome, then switch to Edge while it runs: it finishes in Chrome (the card keeps
      "In use" on Chrome until the research tabs are closed).
- [ ] Two Chrome profiles with the extension: both stay connected (no reconnect every 30 seconds in the log,
      `log stream --predicate 'process == "Wisp"' | grep "Chrome bridge"`).
- [ ] Quit the browser that's in use: the card drops it and the other takes over.

*Tested by the session:* the routing and naming rules in `Tests/ChromeExtBrowsers`, and a live check that the app
owning a loopback socket is found (it named the real Chrome connected to the running Wisp as Google Chrome). Not
tested: Arc, Brave, Vivaldi, Opera, Chrome Canary, or two browsers connected to one Wisp at once.

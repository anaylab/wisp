# Product Hunt launch kit: Wisp for Mac

Everything for the launch in one place. Written 2026-11-10. Items marked **[you]** can only be done by the
owner (accounts, money, your own words); the rest is ready to paste. Delete this file after launch.

## Launch gates: don't post until all of these are true

Product Hunt visitors click "Visit" and expect to try the product in minutes. A launch with a broken or
missing download wastes the one day that counts. Postponing a week costs nothing.

- [ ] **A downloadable build exists.** The terminal installer (`site/install.sh`, no Apple account needed) is
  built and tested; what's left is the release itself. Make the signing certificate once
  (`scripts/make-signing-identity.sh`), build with `scripts/build-terminal-release.sh --publish v0.1` **[you]**,
  then run the install command on a second Mac. Details in `docs/terminal-install.md`. A notarized `Wisp.dmg`
  (paid Apple Developer Program, PR #64) can replace this later.
- [ ] **Updates work.** Cut 0.1, then 0.2, and watch 0.1 update itself on a clean user account. Nothing else
  can stand in for this test.
- [ ] **First run works for a stranger without Xcode or a terminal.** Today the default model is Ollama, which a
  stranger won't have. See "Gaps for a stranger" in `docs/public-beta.md`: the model check, the first-run flow,
  "Move to Applications", the login item, the default agent folder and a Send Feedback item.
- [ ] **The site and README show the install command, once a release exists.** Replace the "Notarized downloads
  aren't published yet" wording in `README.md`, `docs/assets/readme/get-*.png` and `site/index.html` (the Get
  section and the "Why isn't there a download button?" answer) with:
  `curl -fsSL https://anaylab.github.io/wisp/install.sh | bash`.
- [ ] **5 to 10 real people have run it** on Macs that aren't yours, and their problems are fixed. Their honest
  words, with permission, are your first testimonials. Don't invent any.
- [ ] **You can answer for the whole day.** Block the day. Fast, human replies are the single biggest factor.

## Suggested date

**Tuesday, December 8, 2026.** Tuesday to Thursday are the strongest days, and Product Hunt days start at
12:01 AM Pacific. December 1 is possible if every gate above is closed by November 24; the week of Thanksgiving
(November 23 to 27) is a poor week to launch.

## The listing

**Name:** Wisp for Mac. Use "Wisp for Mac" everywhere: "Wisp" alone collides with other products.

**Tagline** (60 characters maximum). Pick one:

1. **The private AI that lives in your Mac's notch** (45 characters)
2. **Hold a key, say it: your Mac does the busywork** (46 characters)
3. **On-device AI in your notch that does the busywork** (49 characters)

**Description** (260 characters maximum, 225 used):

> Wisp lives in your Mac's notch. Hold ⌃⌥ and say it: it drafts the email, runs the browser errand, tidies your windows and shows you where to click. Speech, voice and the model run on your Mac by default. Free and open source.

**Links:** website `https://anaylab.github.io/wisp/` (a custom domain is better when you have one),
GitHub `https://github.com/anaylab/wisp`, demo video `https://www.youtube.com/watch?v=MulzCTJU8-Y`.

**Topics** (check the exact names on Product Hunt when you create the post): Mac, Artificial Intelligence,
Productivity, Open Source, Menu Bar Apps.

**Pricing:** Free, open source (MIT).

**Gallery** (1270 by 760, in `docs/assets/producthunt/`), in this order:

1. `1-hero.jpg`: "The busywork, handled."
2. `2-your-day.jpg`: "Your day, already planned"
3. `3-points.jpg`: "Ask about any part of your screen"
4. `4-approval.jpg`: "Asks before anything leaves"
5. `5-buddies.jpg`: "A team that works on a schedule"
6. `6-browser.jpg`: "Runs the errand in its own tab"

**Thumbnail:** `thumbnail-240.png` (240 by 240, the app icon).

**Video:** the 2:55 demo is long for Product Hunt. Cut a 60 to 90 second version that shows the strongest
moment in the first five seconds (hold the keys, say a request, the notch answers). Keep the long one for the
website. **[you]**

## Maker's first comment (draft)

Post this yourself the moment the listing goes live. The two bracketed sentences are yours to fill in; keep
them true and specific.

> Hi Product Hunt, I'm Anay. [One or two sentences on why you built Wisp: what annoyed you, what you wanted.]
>
> Wisp lives in your Mac's notch. Hold Control and Option, say what you need, and it answers there. It can look
> at your screen and point at what it's talking about, draft an email (nothing sends until you press Send), run a
> browser errand in its own tab, tile your windows, and keep small "buddies" working on a schedule.
>
> The part I care most about is privacy. Out of the box, speech recognition, the voice and the model all run on
> your Mac, and anything that sends, deletes or pays shows an approval card first. A cloud model is opt-in, with
> your own key, and clearly labelled as leaving your machine.
>
> It's free and open source (MIT). It needs an Apple-silicon Mac on macOS 26 or later, because the notch uses
> Liquid Glass. [One honest limitation or rough edge you want feedback on.]
>
> I'd love to hear what you'd use it for and what breaks. I'm here all day.

## Questions to have answers ready for

- **Is it really private? What leaves my Mac?** By default, nothing from your voice, screen or text. The only
  default network use is a one-time download of the speech models, an optional once-a-day update check in release
  builds (GitHub sees the IP address and version; it can be switched off), and live card data like weather, which
  sends only a place name or query and can be turned off. Cloud models are opt-in and labelled. **[confirm the
  update-check wording against the merged PR #64 before posting]**
- **Do I need Ollama? / How do I set up the model?** **[answer after the first-run fixes land]** Today the
  default is a local Ollama model (`qwen2.5vl:3b`). Apple's on-device model and bring-your-own-key cloud models
  are alternatives in Settings → Model.
- **Why macOS 26 and Apple silicon only?** The notch uses Liquid Glass (macOS 26), and the speech models run on
  the Neural Engine.
- **How is it different from Siri, the ChatGPT or Claude apps, or Raycast?** It lives in the notch, sees and
  points at your real screen, runs locally by default, asks before anything irreversible, and is open source.
  Say what it does, not what others can't.
- **Can it do something I didn't want?** Anything that sends, deletes, pays, posts, invites or runs a command
  shows a card first, even with auto-approve on. Browser tasks run in Wisp's own tab, never yours.
- **Is it free forever?** **[decide and answer honestly; don't promise what you haven't decided]**
- **Windows or Intel Mac?** No. Mac only, Apple silicon.
- **What's next?** **[your real next two or three things]**

## Launch day

- **12:01 AM Pacific:** the listing goes live. Post your first comment. Check the download from a second Mac.
- **Morning:** tell people who actually use or know Wisp, in your own words, with the link: friends, testers,
  classmates, the communities you already belong to. Ask for honest feedback. Don't ask for upvotes, don't buy
  or trade them, and don't mass-message: Product Hunt discounts and removes that.
- **All day:** answer every comment within the hour, thank people by name, fix quick bugs live and say so.
- **Evening:** post an update comment with what you fixed or learned.
- **Next day:** thank everyone who tried it, collect issues into GitHub, and send testers a note.

## Before-launch checklist for the website and repo

- [x] Site speed and layout stability (this PR).
- [x] "Wisp for Mac" title, preview tags, structured data, sitemap (this PR).
- [ ] Download button live (after the first release).
- [ ] A short privacy page that matches the README and FAQ.
- [ ] A custom domain (the `github.io` address works, but a short domain reads as a real product).
- [ ] GitHub: pin the repo, add topics, a release with notes, issue templates, Discussions on.

# Wisp — Congressional App Challenge submission

## What it is
Wisp is a macOS app that lives in the notch. Hold Control+Option, ask a question, and Wisp
looks at your screen, answers, and points at or draws on exactly what it means. Everything
runs on the Mac: speech recognition, the AI model and the voice. Nothing is sent anywhere.

## The problem
<!-- FILL IN: ONE problem, one sentence, with one cited statistic.
     Example angle: students who get stuck on homework or software and can't get help that
     is private, free and works inside the app they are already using. -->

## Who it helps
<!-- FILL IN: who you tested with (number of people, grade levels) and one real quote. -->

## What I built vs. what I started from
Wisp began as a fork of the open-source project Clicky (github.com/farzaa/clicky, MIT license).
I am keeping that history visible. My own work, from the git history (225 of ~245 commits), includes:

<!-- FILL IN with things YOU can explain. Candidates from the code:
     - on-device speech (Parakeet) and voice (Kokoro) pipeline
     - pointing at on-screen elements using the accessibility tree + OCR
     - "Ask About a Part": drag-select part of the screen and ask about it
     - handwritten worked-solution notes drawn over the screen, saved as an image
     - confirmation cards that always ask before sending, deleting or paying
     - Canvas calendar sync + daily checklist
-->

AI tools: <!-- FILL IN honestly how you used Claude/AI while coding, and which parts you wrote and can explain. -->

## Try it
Requires a Mac with macOS 26+ and [Ollama](https://ollama.com).

1. `ollama pull qwen2.5vl:3b && ollama serve`
2. Open `leanring-buddy.xcodeproj` in Xcode, choose the `leanring-buddy` scheme, press Run.
3. Grant Microphone, Accessibility and Screen Recording when asked, then hold Control+Option.

No account and no API key are needed. A demo video is linked in the submission form.

## Privacy
Speech, AI and voice all run locally. Cloud models are optional, off by default, and need
your own key. No analytics.

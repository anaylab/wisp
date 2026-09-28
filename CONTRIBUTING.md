# Contributing to Wisp

Thanks for helping make Wisp better. A few things keep the project healthy.

## Before you start

- Read [`AGENTS.md`](AGENTS.md). It's the architecture reference and the house style guide.
- For anything bigger than a bug fix, open an issue first so we can agree on the approach.
- **Local-first is non-negotiable.** Don't add a cloud dependency to the default path, and
  don't make a cloud provider the default. Opt-in cloud features must say clearly that data
  leaves the Mac.

## Building

```bash
ollama pull qwen2.5vl:3b
open leanring-buddy.xcodeproj
```

Build and run the `leanring-buddy` scheme from Xcode.

- **Don't rename** the Xcode project, target or scheme. The `leanring` typo is legacy and
  intentional; only the app is called Wisp.
- **Don't run `xcodebuild`** from the terminal. It re-signs the app and resets its privacy
  permissions.
- **Don't launch the binary directly.** Use `open -a Wisp` so LaunchServices can attribute
  permission requests to the app.
- The Swift 6 concurrency warnings and the deprecated `onChange` warning are known. Leave them.

## Code style

- Clear over clever. Long, specific names (`originalQuestionLastAnsweredDate`, not `orig`).
- SwiftUI first, AppKit only where SwiftUI can't do it. UI state on `@MainActor`, async/await.
- Use the design tokens in `DesignSystem/` — no hardcoded hex colours.
- Comments explain *why*.
- Anything that sends, deletes, pays, posts or executes must go through the confirmation flow.

## Tests

```bash
./Tests/ModelProviderContract/run.sh
./Tests/AgentRuntimeIntegration/run.sh
```

Plus the unit tests in Xcode (<kbd>⌘</kbd><kbd>U</kbd>). Add tests for pure logic such as
parsers, matchers and schedulers.

## Pull requests

- Branch as `feature/…` or `fix/…`.
- Commit messages in the imperative mood that explain *why*.
- Keep PRs focused. Update `AGENTS.md` if you change architecture or add files.
- Include a screenshot or short recording for UI changes.

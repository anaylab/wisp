# Security policy

Wisp can see your screen, hear your voice, and act in your apps, so we take security
reports seriously.

## Reporting a vulnerability

Please **don't open a public issue**. Report it privately through GitHub's
[private vulnerability reporting](../../security/advisories/new) instead.

Include what you found, how to reproduce it, and what an attacker could do with it. You'll
get an acknowledgement within a few days.

## In scope

- Anything that sends screenshots, audio, transcripts or keys off the Mac without the user
  opting in
- Bypasses of the tool confirmation flow (sending, deleting, paying, running commands)
- The Wisp Tabs WebSocket bridge on `127.0.0.1:47823` accepting connections it shouldn't
- Prompt injection from on-screen or web content that leads to unconfirmed actions
- Keys leaking out of the Keychain into logs, files or requests

## Supported versions

Only the latest `main` gets security fixes.

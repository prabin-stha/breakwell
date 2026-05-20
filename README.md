# BreakWell

A quiet macOS menu-bar app that reminds you to take breaks — without nagging.

BreakWell sits in your menu bar and gently surfaces a short pause every work interval. It's aware of what you're doing: meetings, audio playback, screen recordings, and idle time pause the timer automatically, so a break never interrupts a call or pops up while you're away from your desk. A 30-second heads-up gives you time to finish your thought; one click snoozes the break by 5, 10, or 15 minutes. A small floating clock in the corner shows when the next break is coming. When it's time, a calm full-screen overlay takes over for a few minutes, then steps out of the way.

No accounts. No network calls. No analytics. Sandboxed, with no access to your microphone, camera, or other apps' content.

## Installation

Paste this into your Terminal and press Enter:

```bash
curl -fsSL https://raw.githubusercontent.com/prabin-stha/breakwell/main/scripts/install.sh | bash
```

That's it. The script handles everything — no manual steps required.

> **Note:** macOS may prompt for your password to install into `/Applications`. This is expected.

## What the installer does

1. **Checks your system** — confirms you're on macOS and have the required tools (`curl`, `unzip`)
2. **Detects your architecture** — picks the right build for Apple Silicon (arm64) or Intel (x86_64)
3. **Downloads the latest release** — fetches the `.zip` directly from GitHub Releases
4. **Installs to `/Applications`** — removes any previous version and copies the new one
5. **Sets correct permissions** — ensures the app is executable
6. **Removes Gatekeeper quarantine** — bypasses the *"unidentified developer"* warning that appears on unsigned apps

## Requirements

- macOS (Intel or Apple Silicon)
- `curl` and `unzip` — both are pre-installed on every Mac

## Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/prabin-stha/breakwell/main/scripts/uninstall.sh | bash
```

By default the uninstaller removes the app but keeps your settings, so a future reinstall picks up where you left off. To wipe everything — preferences, daily stats, caches — pass `--purge`:

```bash
curl -fsSL https://raw.githubusercontent.com/prabin-stha/breakwell/main/scripts/uninstall.sh | bash -s -- --purge
```

The uninstaller asks for confirmation before deleting anything. Add `-y` to skip the prompt if you're scripting it.

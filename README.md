# Claude Usage Widget

A native macOS menu bar app that shows your Claude.ai plan usage at a glance.

Two small rings in your menu bar show how much of your session and of your week is left, as a number inside each ring. A ring fills up as you use Claude and turns amber when you're getting close, red when you're almost out. Click it to see the full breakdown.

---

## What It Shows

- **Current session** usage with time until reset
- **Weekly usage** across all models
- **Per-model weekly buckets** (Opus, Sonnet) and **extra usage**, only when your plan has them
- Two rings with the number left inside: session on the left, week on the right. Hover for reset times
- The gear in the popover picks one ring or both, and turns on Open at Login

---

## Install (macOS only)

1. Go to [Releases](../../releases) and download the latest `.dmg`
2. Open the `.dmg` and drag **Claude Usage Widget** to your Applications folder
3. Open Terminal and run this command (required for unsigned apps):
   ```
   sudo xattr -cr /Applications/ClaudeUsageWidget.app
   ```
   Enter your Mac password when prompted.
4. Open the app. If Claude Code is installed, the widget asks once to read its sign-in and the numbers appear. Otherwise click **Sign in with your browser**: claude.ai opens in your browser, you approve, and the tab tells you to close it.

> **Why step 3?** macOS blocks apps that aren't signed with an Apple Developer certificate. This is a free, open-source app and isn't code-signed yet, so macOS flags it as "damaged." The command above tells macOS it's safe to run. You only need to do this once.

---

## Requirements

- macOS 13 (Ventura) or later

---

## Building from Source

Requires Xcode 15+.

```bash
git clone https://github.com/HQ-RSL-A/claude-usage-widget.git
cd claude-usage-widget
open ClaudeUsageWidget.xcodeproj
```

Build and run from Xcode, or via CLI:

```bash
xcodebuild -scheme ClaudeUsageWidget -configuration Release
```

---

## Privacy

This app talks only to Anthropic: `claude.com` and `platform.claude.com` for sign-in, `api.anthropic.com` for usage, and `claude.ai` for the old in-app sign-in. Its own token lives in your macOS Keychain; the in-app session uses the system's WebKit cookie store. Nothing is sent to any third-party server. No analytics. No telemetry.

---

## Signing in

Three ways, in the order the widget tries them:

1. **Claude Code's sign-in.** If Claude Code is installed, macOS asks once whether the widget may read its sign-in ("Claude Code-credentials"). Always Allow and you are done. The widget only reads the current token; it never changes anything in Claude Code.
2. **Your browser.** Click "Sign in with your browser". claude.ai opens in your default browser, where Google, passkeys and saved passwords all work. Approve, close the tab, done. The widget keeps its own token in your Keychain and refreshes it itself.
3. **Inside the app** (the old way). A small link opens the embedded sign-in window. Email code works; Google often does not inside an embedded window.

Sign Out forgets everything the widget holds and stops using Claude Code's sign-in until you choose it again.

The browser route uses Anthropic's OAuth as Claude Code does; Anthropic publishes no third-party registration for it, so if it ever stops working the other two routes remain.

---

## Status

v0.5.0 - what's left of your session and your week, right in the menu bar. macOS only.

---

## License

MIT

# Claude Usage Widget

A native macOS menu bar app that shows your Claude.ai plan usage at a glance.

A small ring in your menu bar fills up as you use Claude. It turns amber when you're getting close, red when you're almost out. Click it to see the full breakdown.

---

## What It Shows

- **Current session** usage with time until reset
- **Weekly usage** across all models
- **Weekly Sonnet usage** specifically
- Color-coded ring that changes as you approach your limits

---

## Install (macOS only)

1. Go to [Releases](../../releases) and download the latest `.dmg`
2. Open the `.dmg` and drag **Claude Usage Widget** to your Applications folder
3. Open Terminal and run this command (required for unsigned apps):
   ```
   sudo xattr -cr /Applications/ClaudeUsageWidget.app
   ```
   Enter your Mac password when prompted.
4. Open the app. A login window will appear - sign in to Claude once, and the app stays signed in.

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

This app only communicates with `claude.ai`. Your session is stored locally using the system's standard WebKit cookie store (same as Safari). Nothing is sent to any third-party server. No analytics. No telemetry.

---

## Login Notes

The login window uses an embedded WebView. Email/password login works reliably. Google OAuth works in most cases but can occasionally stall on the final redirect step for unsigned apps - if that happens, use email/password instead.

---

## Status

v0.2.0 - functional, running daily. Built for personal use. macOS only.

---

## License

MIT

# Claude Usage Widget

A native macOS menu bar app that shows how much of your AI plans is left: Claude, Grok Bot and Codex, in one panel.

Your menu bar shows one logo and one number, like "40% remain": the limit closest to running out across the services you show. A small dot on the logo turns amber when you're getting close and red when you're almost out. Click it to see every service with its logo, what's left of each limit and when it resets.

---

## What It Shows

- **Claude:** the current session and the week across all models, plus per-model weekly limits (Opus, Sonnet) and extra usage when your plan has them
- **Grok Bot:** its weekly usage, read from the file the Grok Bot Mac app saves. It is only as fresh as that app's last refresh, so the panel says how old the reading is
- **Codex:** its 5 hour session and weekly usage, shown only when Codex is set up on this Mac (its sign-in file is there). It needs a ChatGPT sign-in, not an API key
- **The menu bar:** the logo of the service that is lowest and its number. Hover for every limit and its reset time
- **The "..." menu in the panel:** Refresh, what the menu bar shows (the lowest limit, or one service you pick), which services to show, Open at Login, Sign Out of Claude and Quit

---

## Install (macOS only)

1. Go to [Releases](../../releases) and download the latest `.dmg`
2. Open the `.dmg` and drag **Claude Usage Widget** to your Applications folder
3. Open Terminal and run this command (required for unsigned apps):
   ```
   sudo xattr -cr /Applications/ClaudeUsageWidget.app
   ```
   Enter your Mac password when prompted.
4. Open the app. If Claude Code is installed, the numbers appear. Otherwise click **Sign in with your browser**: claude.ai opens in your browser, you approve, and the tab tells you to close it. Grok Bot and Codex show up by themselves when their apps are set up on your Mac.

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

This app talks to Anthropic: `claude.com` and `platform.claude.com` for sign-in, `api.anthropic.com` for usage, and `claude.ai` for the old in-app sign-in. When Codex is signed in on your Mac, it also sends Codex's own sign-in token to `chatgpt.com` to read your Codex usage, the way Codex itself does. It only reads that token, never renews, changes or keeps it. Grok Bot is read from a file on your Mac and nothing is sent anywhere for it. The widget's own Claude token lives in your macOS Keychain; the in-app sign-in (the old way) keeps its cookies in the system's WebKit cookie store. The app's own network requests leave nothing on disk. No analytics. No telemetry.

---

## Signing in

Three ways, in the order the widget tries them:

1. **Claude Code's sign-in.** If Claude Code is installed, the widget reads its current token ("Claude Code-credentials") and you are done, with no password prompt. It never changes anything in Claude Code.
2. **Your browser.** Click "Sign in with your browser". claude.ai opens in your default browser, where Google, passkeys and saved passwords all work. Approve, close the tab, done. The widget keeps its own token in your Keychain and refreshes it itself.
3. **Inside the app** (the old way). A small link opens the embedded sign-in window. Email code works; Google often does not inside an embedded window.

Sign Out forgets everything the widget holds and stops using Claude Code's sign-in until you choose it again.

The browser route uses Anthropic's OAuth as Claude Code does; Anthropic publishes no third-party registration for it, so if it ever stops working the other two routes remain.

---

## Status

v0.6.0 - every AI's usage in one panel, with the lowest limit in your menu bar. macOS only.

Third-party notices (the Claude and Codex logos): [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)

---

## License

MIT

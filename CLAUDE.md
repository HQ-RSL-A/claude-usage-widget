# CLAUDE.md - claude-usage-widget

## What This Is

Native macOS menu bar app (Swift + AppKit) showing Claude.ai plan usage at a glance. Circular ring progress indicator in the menu bar, click to expand full usage details. Part of `~/Developer/my-business/internal-tools/`.

- **GitHub:** `HQ-RSL-A/claude-usage-widget`
- **Distribution:** `.dmg` via GitHub Releases (GitHub Actions)
- **Target:** macOS 13+ (Ventura and later)
- **Current version:** v0.4.2

## Stack

- Swift + AppKit (no SwiftUI)
- Anthropic OAuth token for auth (own token in the Keychain, or Claude Code's token read from its Keychain item); WKWebView login kept as a fallback
- Core Graphics for ring drawing
- xcodegen for project management (`project.yml` -> `.xcodeproj`)

## Rules

- **Never hand-edit `.xcodeproj`** - edit `project.yml`, run `xcodegen generate`
- **Never use `exportArchive`** for DMG builds - it strips Resources from unsigned apps. Copy `.app` directly from `.xcarchive`
- **`main.swift` is intentional** - `@main` doesn't wire `NSApp.delegate` without a nib file
- `setupStatusItem()` must run before any WebKit object exists (`ClaudeAPIClient`, login window): WebKit IPC interferes with NSStatusBar on Sonoma
- Use `callAsyncJavaScript` not `evaluateJavaScript` for fetch() calls (Promise handling)
- **Signed in means a 2xx from `/api/organizations`**, never cookie presence. `ClaudeAPIError.classify` is the only place HTTP status is interpreted
- **Signed-out signal is HTTP 403 with `error_code: account_session_invalid`** (or 401). A bare 403 is a per-org permission problem (the API console org), never a sign-out
- **Only `chat`-capable orgs may be selected** (`Organization.pickChatOrg`); console orgs always 403 on usage
- **Every OAuth request carries** `anthropic-beta: oauth-2025-04-20` and `User-Agent: ClaudeUsageWidget/<version> (macOS)`; Cloudflare in front of `platform.claude.com` rejects anonymous-looking clients
- **OAuth `state` is 32 random bytes (43 characters).** A 16-byte state loads the consent page but is refused at Authorize with "Invalid request format" (v0.4.0 bug). A URL that loads the consent page proves nothing about the Authorize step
- **Never use Claude Code's refresh token.** Read its access token, nothing else; refreshing it would break Claude Code
- **Tokens live in the Keychain or memory**, never UserDefaults, logs or files. Tests touch only `io.rsla.ClaudeUsageWidget.tests*` Keychain services
- **Never tag a release before the built app has been driven through the changed flow.** v0.4.0 was tagged before its manual pass and shipped a broken browser sign-in; green unit tests and a consent page that loads did not catch it. `brain.md` Testing says how to drive the popover for real

## Commands

```bash
open ClaudeUsageWidget.xcodeproj     # Open in Xcode
xcodegen generate                     # Regenerate project from project.yml
swift makeIcon.swift                  # Regenerate app icon PNGs
xcodebuild -scheme ClaudeUsageWidget -configuration Release  # CLI build
xcodebuild test -scheme ClaudeUsageWidget -destination platform=macOS CODE_SIGNING_ALLOWED=NO  # Unit tests
```

## Known Issues

- WebContent sandbox errors in Xcode console are expected noise (unsigned WKWebView)
- `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` must be set in `project.yml` target settings
- Finder caches old app icons - `killall Dock` to refresh
- Downloaded DMG triggers Gatekeeper error - users must run `sudo xattr -cr /Applications/ClaudeUsageWidget.app`
- Google sign-in fails inside the embedded login window (unsigned WKWebView). Use **Sign in with your browser**, where it works

See `brain.md` for architecture details, auth flow, API shape, and ring color states.

# GEMINI.md — claudeUsageWidget

## What This Is

Native macOS menu bar app (Swift + AppKit) showing Claude.ai plan usage at a glance. Circular ring progress indicator in the menu bar, click to expand full usage details. Part of `~/lalia/myBusiness/internalTools/`.

- **GitHub:** `rahullalia/claude-usage-widget`
- **Distribution:** `.dmg` via GitHub Releases (GitHub Actions)
- **Target:** macOS 13+ (Ventura and later)
- **Current version:** v0.2.1

## Stack

- Swift + AppKit (no SwiftUI)
- WKWebView for auth (persistent data store, no Keychain)
- Core Graphics for ring drawing
- xcodegen for project management (`project.yml` -> `.xcodeproj`)

## Rules

- **Never hand-edit `.xcodeproj`** — edit `project.yml`, run `xcodegen generate`
- **Never use `exportArchive`** for DMG builds — it strips Resources from unsigned apps. Copy `.app` directly from `.xcarchive`
- **`main.swift` is intentional** — `@main` doesn't wire `NSApp.delegate` without a nib file
- `setupStatusItem()` must run before `setupWebView()` (WebKit IPC interferes with NSStatusBar on Sonoma)
- Use `callAsyncJavaScript` not `evaluateJavaScript` for fetch() calls (Promise handling)

## Commands

```bash
open ClaudeUsageWidget.xcodeproj     # Open in Xcode
xcodegen generate                     # Regenerate project from project.yml
swift makeIcon.swift                  # Regenerate app icon PNGs
xcodebuild -scheme ClaudeUsageWidget -configuration Release  # CLI build
```

## Known Issues

- WebContent sandbox errors in Xcode console are expected noise (unsigned WKWebView)
- `ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon` must be set in `project.yml` target settings
- Finder caches old app icons — `killall Dock` to refresh
- Downloaded DMG triggers Gatekeeper error — users must run `sudo xattr -cr /Applications/ClaudeUsageWidget.app`
- Google OAuth may fail in unsigned WKWebView apps — workaround: add email/password to Claude account

See `BRAIN.md` for architecture details, auth flow, API shape, and ring color states.

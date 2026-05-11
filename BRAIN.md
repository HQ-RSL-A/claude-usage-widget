# BRAIN.md — claudeUsageWidget

Reference material for the Claude Usage Widget. Rules live in `CLAUDE.md`.

## Folder Structure

```
claudeUsageWidget/
  ClaudeUsageWidget/
    AppDelegate.swift           # NSStatusItem, menu setup, app lifecycle
    UsageService.swift          # API fetching, polling timer, data models
    AuthManager.swift           # WKWebView login, persistent session, sign-out
    RingView.swift              # Core Graphics ring (NSView subclass)
    MenuView.swift              # Popover UI (progress bars, toggle, auth states)
    RefreshIcon.swift           # Teenyicons refresh SVG via CGPath
    Models.swift                # UsageData, UsageStat, RingColorState, RingMetricMode
    LoginWindowController.swift # WKWebView login window
    main.swift                  # App entry point (XCTest-aware)
  ClaudeUsageWidget.xcodeproj/
  docs/plans/                   # Design docs and implementation plans
  .github/workflows/build.yml   # GitHub Actions: build + package DMG
```

## Architecture Decisions

- **AppKit only** — lighter weight, better NSStatusItem control than SwiftUI
- **WKWebView with persistent data store** — `WKWebsiteDataStore.default()` keeps user signed in across restarts
- **Core Graphics ring** — custom `NSView`, no third-party libraries
- **5-minute polling** — `Timer.scheduledTimer` + manual refresh available
- **`main.swift` detects XCTest** — minimal `TestAppDelegate` avoids full UI launch during tests
- **Ring metric toggle** — `RingMetricMode` enum (`.session` / `.weekly`) persisted in `UserDefaults`
- **Auth-aware footer** — swaps Sign In / Sign Out based on auth state
- **Custom RefreshButton** — CGPath-drawn teenyicons SVG, adapts to light/dark

## Auth Flow

1. First launch: login window opens with WKWebView -> `claude.ai`
2. User logs in (supports 2FA, Google OAuth)
3. Login detected via `callAsyncJavaScript` calling `/api/organizations` every 2s
4. Session cookie persisted in `WKWebsiteDataStore.default()`
5. Sign Out: wipes session via `removeData(...)`
6. Three detection layers: URL KVO, didFinish delegate, API polling
7. Navigation delegate gates polling — `startPolling()` only after `webView(_:didFinish:)`

### Google OAuth Caveat

`SOAuthorizationCoordinator` can block Google sign-in in unsigned WKWebView apps. `WKUIDelegate` popup handler handles most cases, but Google may reject at the final redirect. Workaround: add email/password to Claude account.

## API

Usage endpoint identified from `claude.ai/settings/usage` network inspection. Auth via persistent WKWebView session cookie.

```swift
struct UsageData {
    let currentSession: UsageStat      // percentUsed, resetsInMinutes
    let weeklyAllModels: UsageStat     // percentUsed, resetsAt (Date)
    let weeklySonnetOnly: UsageStat    // percentUsed, resetsAt (Date)
}
```

## Ring Color States

| Usage % | Color |
|---------|-------|
| 0 to 59% | Monochrome (adapts to light/dark menu bar) |
| 60 to 84% | Amber (#F59E0B) |
| 85 to 100% | Red (#EF4444) |

Ring shows session usage by default, configurable via popover toggle.

## Distribution

- GitHub Actions builds DMG on tag pushes matching `v*`
- DMG attached to GitHub Release
- Users: download DMG, drag to Applications, run `sudo xattr -cr`, open
- `.app` copied directly from `.xcarchive/Products/Applications/` (not via `exportArchive`)

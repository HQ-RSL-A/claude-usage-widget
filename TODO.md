# ClaudeUsageWidget - TODO

Last updated: 2026-03-10

## High Priority

- [ ] **Fix login window not closing after login** - the login window stays open after successful authentication. Cookie-name polling (`sessionKey`/`lastActiveOrg`) was tried but may be fragile. API-based polling (`/api/organizations`) was built and reverted (user wanted to revisit later). Three detection layers exist (URL KVO, didFinish, cookie polling) but none reliably close the window. Needs investigation with NSLog `[LOGIN]` output in Xcode console to see which mechanism fires (or doesn't).
- [ ] **Add email/password to Claude account** (user action, not code) - go to claude.ai → Settings → Account → add password. Makes re-login reliable without depending on Google OAuth.

## Medium Priority

- [ ] **Launch at login** - add `SMAppService.mainApp.register()` (macOS 13+) so the widget starts automatically on boot without needing Xcode open
- [ ] **Handle auth expiry gracefully** - if the claude.ai session expires, the app currently shows an error in the popover but doesn't automatically prompt re-login. Should detect auth failure and open the login window.
- [ ] **Apple Developer Program** - $99/year, enables code signing + notarization. Removes Gatekeeper "damaged" error for all users downloading the DMG. Currently every user must run `sudo xattr -cr` manually.

## Low Priority / Nice to Have

- [ ] **Improve Google OAuth** - once signed, `com.apple.security.network.client` + proper entitlements may resolve `SOAuthorizationCoordinator` blocking. Research required.
- [ ] **Notification when usage hits 80%** - `UNUserNotificationCenter` one-time alert as usage crosses threshold
- [ ] **Menu bar tooltip** - show exact % on hover over the ring icon via `statusItem.button?.toolTip`

## Completed (v0.2.1, 2026-03-10)

- [x] DMG icon fix - `exportArchive` was stripping Resources folder; replaced with direct copy from `.xcarchive`
- [x] Install docs - added `sudo xattr -cr` instructions to README.md and GitHub Release notes
- [x] Login detection API polling - built then reverted (parked for later)

## Completed (v0.2.0, 2026-03-10)

- [x] Popover redesign - custom ProgressBarView, semantic colors, auto light/dark mode
- [x] Ring metric toggle - Session/Weekly segmented control, UserDefaults persistence
- [x] Auth-aware footer - Sign In/Sign Out swap based on auth state
- [x] Custom refresh icon - teenyicons SVG drawn via CGPath (replaced Unicode ↻)
- [x] Refresh button visible and working in popover
- [x] Dark/light mode popover adaptation - uses AppKit semantic colors throughout
- [x] Test runner fix - XCTest-aware main.swift prevents crash

## Completed (v0.1.x, 2026-03-07 to 2026-03-08)

- [x] Fixed `applicationDidFinishLaunching` never firing (`@main` → `main.swift`)
- [x] Fixed menu bar icon not appearing (reordered init: status item before webview)
- [x] Fixed Google OAuth popup blocked (implemented `WKUIDelegate` popup handler)
- [x] Fixed usage data not loading (`evaluateJavaScript` → `callAsyncJavaScript` for Promise handling)
- [x] Fixed polling before page loaded (gates `startPolling()` behind `WKNavigationDelegate.didFinish`)
- [x] App icon generated and compiling (`makeIcon.swift`, `ASSETCATALOG_COMPILER_APPICON_NAME`)
- [x] Menu bar shows real ring (replaced placeholder SF Symbol)
- [x] Removed all debug print statements
- [x] v0.1.2 tagged and pushed to GitHub

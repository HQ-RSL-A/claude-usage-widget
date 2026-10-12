# log.md - claude-usage-widget

Newest entry on top.

## 2026-10-12 15:23 PT

v0.3.0 review fix pass. A fresh whole-branch review found no Critical and four Important findings, all fixed with tests first: a poll finishing after sign-out could flip the app to "Session expired" (service identity guards, `sessionDidExpire()` ignored unless signed in); the API client never recovered after WebKit killed its content process (`webViewWebContentProcessDidTerminate`, reload after a bridge failure); no automatic retry from "unreachable" (now every 60 s); no tests on the popover rows (six added); tests touched the real cookie store (`.nonPersistent()` injected). 82 tests. Manual pass so far: Google OAuth popup stalls at its final redirect (known HQ-117, popup closed by hand); email code sign-in still to be run. Finding worth a decision: `api.anthropic.com/api/oauth/usage` returns the same buckets with the OAuth token Claude Code stores in Keychain, so a v0.4.0 could sign in through the real browser (autofill, passkeys) or reuse that token with no sign-in at all (Linear decision issue filed).

## 2026-10-12 15:03 PT

v0.3.0, sign-in for anyone (branch `v0.3.0-sign-in-for-anyone`, not yet merged or tagged). Auth is proven by `/api/organizations` instead of cookie presence; the chat org is picked by the `lastActiveOrg` cookie (API console orgs never selected); every usage bucket is optional and the popover builds rows from the response; the login window closes only on API confirmation (HQ-112); expiry is detected on the next poll and opens the login window once (HQ-115); version string is real (`MARKETING_VERSION`); unit tests run in CI (`.github/workflows/test.yml`, 71 tests). Verified live: a missing session is HTTP 403 with `error_code: account_session_invalid`, not 401. Spec: `docs/plans/2026-10-12-v0.3.0-sign-in-for-anyone-design.md`. Plan: `docs/plans/2026-10-12-v0.3.0-implementation-plan.md`. Linear: HQ-137 (In Progress), comments on HQ-112 and HQ-115. Manual pass (plan Task 8): pending Rahul. Pending Rahul: manual pass, merge, push, tag `v0.3.0`.

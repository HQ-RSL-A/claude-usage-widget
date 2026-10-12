# log.md - claude-usage-widget

Newest entry on top.

## 2026-10-12 15:03 PT

v0.3.0, sign-in for anyone (branch `v0.3.0-sign-in-for-anyone`, not yet merged or tagged). Auth is proven by `/api/organizations` instead of cookie presence; the chat org is picked by the `lastActiveOrg` cookie (API console orgs never selected); every usage bucket is optional and the popover builds rows from the response; the login window closes only on API confirmation (HQ-112); expiry is detected on the next poll and opens the login window once (HQ-115); version string is real (`MARKETING_VERSION`); unit tests run in CI (`.github/workflows/test.yml`, 71 tests). Verified live: a missing session is HTTP 403 with `error_code: account_session_invalid`, not 401. Spec: `docs/plans/2026-10-12-v0.3.0-sign-in-for-anyone-design.md`. Plan: `docs/plans/2026-10-12-v0.3.0-implementation-plan.md`. Linear: HQ-137 (In Progress), comments on HQ-112 and HQ-115. Manual pass (plan Task 8): pending Rahul. Pending Rahul: manual pass, merge, push, tag `v0.3.0`.

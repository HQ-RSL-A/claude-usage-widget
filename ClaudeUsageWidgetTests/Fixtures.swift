import Foundation
@testable import ClaudeUsageWidget

enum Fixtures {
    static func response(_ status: Int, _ json: String) -> APIResponse {
        APIResponse(status: status, body: Data(json.utf8))
    }

    // Verified live on 2026-10-12.
    static let sessionInvalid403 = response(403, #"{"type":"error","error":{"type":"permission_error","message":"Invalid authorization","details":{"error_visibility":"user_facing","error_code":"account_session_invalid"}},"request_id":"req_1"}"#)
    static let permissionDenied403 = response(403, #"{"type":"error","error":{"type":"permission_error","message":"Permission denied."},"request_id":"req_2"}"#)
    static let notFound404 = response(404, #"{"type":"error","error":{"type":"not_found_error","message":"Not found.","details":{"error_visibility":"user_facing"}},"request_id":"req_3"}"#)
    static let unauthorized401 = response(401, #"{"type":"error","error":{"type":"authentication_error","message":"Unauthorized"}}"#)
    static let server500 = response(500, "<html>Internal Server Error</html>")

    // Two orgs, console org first on purpose.
    static let twoOrgsJSON = #"""
    [
      {"uuid":"console-org","name":"API Console","capabilities":["api","api_individual","customer_terms:standard"],"rate_limit_tier":"auto_trust_tier_c","billing_type":"prepaid","plan_display_name":null},
      {"uuid":"chat-org","name":"Personal","capabilities":["claude_max","chat"],"rate_limit_tier":"default_claude_max_20x","billing_type":"stripe_subscription","plan_display_name":null}
    ]
    """#
    static let twoChatOrgsJSON = #"""
    [
      {"uuid":"chat-a","name":"Personal","capabilities":["claude_pro","chat"],"rate_limit_tier":"default_claude_pro"},
      {"uuid":"chat-b","name":"Acme Team","capabilities":["chat","claude_team"],"rate_limit_tier":"default_claude_team"}
    ]
    """#
    static let consoleOnlyJSON = #"[{"uuid":"console-org","name":"API Console","capabilities":["api","api_individual"],"rate_limit_tier":"auto_trust_tier_c"}]"#
    static let emptyOrgsJSON = "[]"

    // Real Max 20x shape (trimmed to the keys that matter, plus codenamed noise).
    static let usageMax20xJSON = #"""
    {
      "five_hour": {"utilization": 8, "resets_at": "2026-10-12T22:00:00.582425+00:00", "limit_dollars": null, "used_dollars": null, "remaining_dollars": null, "locked_reason": null},
      "seven_day": {"utilization": 73, "resets_at": "2026-10-16T16:00:00.582446+00:00", "limit_dollars": null, "used_dollars": null, "remaining_dollars": null, "locked_reason": null},
      "seven_day_oauth_apps": null, "seven_day_opus": null, "seven_day_sonnet": null, "seven_day_cowork": null,
      "tangelo": null,
      "iguana_necktie": {"utilization": 0, "resets_at": "2026-11-01T00:00:00+00:00", "limit_dollars": 250, "used_dollars": 0, "remaining_dollars": 250, "locked_reason": null},
      "extra_usage": {"is_enabled": false, "monthly_limit": null, "used_credits": null, "utilization": null, "currency": "USD", "decimal_places": 2},
      "limits": [], "spend": {"used": 0, "limit": null}, "member_dashboard_available": false
    }
    """#
    static let usageProLikeJSON = #"""
    {
      "five_hour": {"utilization": 42, "resets_at": "2026-10-12T22:00:00+00:00"},
      "seven_day": {"utilization": 67, "resets_at": "2026-10-16T16:00:00+00:00"},
      "seven_day_opus": {"utilization": 40, "resets_at": "2026-10-16T16:00:00+00:00"},
      "seven_day_sonnet": {"utilization": 12, "resets_at": "2026-10-16T16:00:00+00:00"},
      "extra_usage": {"is_enabled": true, "monthly_limit": 5000, "used_credits": 1750, "utilization": 35}
    }
    """#
    static let usageMinimalJSON = #"{"five_hour": {"utilization": 10, "resets_at": "2026-10-12T22:00:00+00:00"}, "seven_day": {"utilization": 20, "resets_at": "2026-10-16T16:00:00+00:00"}}"#
    static let usageNoSessionJSON = #"{"five_hour": null, "seven_day": {"utilization": 20, "resets_at": "2026-10-16T16:00:00+00:00"}}"#
    static let usageNullUtilizationJSON = #"{"five_hour": {"utilization": null, "resets_at": null}, "seven_day": {"utilization": 20, "resets_at": null}}"#

    // Token endpoint shape from the 2026-10-12 spike.
    static let tokenResponseJSON = #"{"access_token":"access-1","refresh_token":"refresh-1","expires_in":28800,"refresh_token_expires_in":2592000,"scope":"user:inference user:profile","token_type":"Bearer","token_uuid":"t-1","account":{"uuid":"a-1"},"organization":{"uuid":"o-1"}}"#
    static let refreshedTokenJSON = #"{"access_token":"access-2","refresh_token":"refresh-2","expires_in":28800,"scope":"user:inference user:profile","token_type":"Bearer"}"#
    static let tokenRefusedJSON = #"{"error":"invalid_grant","error_description":"The refresh token is invalid"}"#
    static let profileJSON = #"{"account":{"uuid":"a-1","full_name":"Test Person","display_name":"Test","email":"test@example.com","has_claude_max":true,"has_claude_pro":false},"organization":{"uuid":"o-1","name":"Test's Organization","organization_type":"claude_max","billing_type":"stripe_subscription","rate_limit_tier":"default_claude_max_20x"},"application":{"uuid":"app","name":"Claude Code","slug":"claude-code"},"enabled_plugins":[]}"#
    static let claudeCodeCredentialsJSON = #"{"claudeAiOauth":{"accessToken":"cc-access","refreshToken":"cc-refresh","expiresAt":4102444800000,"refreshTokenExpiresAt":4102444800000,"scopes":["user:inference","user:profile"],"subscriptionType":"max","rateLimitTier":"default_claude_max_20x"}}"#
    static let claudeCodeExpiredJSON = #"{"claudeAiOauth":{"accessToken":"cc-old","refreshToken":"cc-refresh","expiresAt":946684800000,"scopes":[],"subscriptionType":"pro"}}"#
}

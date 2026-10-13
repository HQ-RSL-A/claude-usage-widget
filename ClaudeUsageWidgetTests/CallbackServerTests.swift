import XCTest
@testable import ClaudeUsageWidget

@MainActor
final class CallbackServerTests: XCTestCase {

    private func hit(_ port: UInt16, _ query: String) async throws -> (Int, String) {
        let url = URL(string: "http://127.0.0.1:\(port)/callback?\(query)")!
        let (data, response) = try await URLSession.shared.data(from: url)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, String(decoding: data, as: UTF8.self))
    }

    func test_matchingState_yieldsCode_andServes200() async throws {
        let server = CallbackServer()
        let port = try await server.start(expectedState: "s1")
        XCTAssertGreaterThan(port, 0)
        async let waiting = server.waitForCode(timeout: 5)
        let (status, html) = try await hit(port, "code=abc123&state=s1")
        XCTAssertEqual(status, 200)
        XCTAssertTrue(html.contains("close this tab"), html)
        let code = try await waiting
        XCTAssertEqual(code, "abc123")
        server.stop()
    }

    func test_callbackBeforeWait_isKept() async throws {
        let server = CallbackServer()
        let port = try await server.start(expectedState: "s2")
        let (status, _) = try await hit(port, "code=early&state=s2")
        XCTAssertEqual(status, 200)
        let code = try await server.waitForCode(timeout: 1)
        XCTAssertEqual(code, "early")
        server.stop()
    }

    func test_wrongState_serves400_andKeepsWaitingUntilTimeout() async throws {
        let server = CallbackServer()
        let port = try await server.start(expectedState: "right")
        let (status, _) = try await hit(port, "code=evil&state=wrong")
        XCTAssertEqual(status, 400)
        do {
            _ = try await server.waitForCode(timeout: 0.3)
            XCTFail("expected a timeout")
        } catch {
            XCTAssertEqual(error as? ClaudeAPIError, .callbackTimeout)
        }
        server.stop()
    }

    func test_stop_whileWaiting_throwsCancelled() async throws {
        let server = CallbackServer()
        _ = try await server.start(expectedState: "s")
        Task { try? await Task.sleep(nanoseconds: 100_000_000); server.stop() }
        do {
            _ = try await server.waitForCode(timeout: 5)
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? ClaudeAPIError, .signInCancelled)
        }
    }
}

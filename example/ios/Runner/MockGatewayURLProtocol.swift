import Foundation

/// In-process stand-in for a real payment gateway backend, so this sample
/// app can exercise the SDK's full card and UPI flows in the simulator
/// without a live server.
///
/// Installed via `PgFlutterSdkPlugin.debugURLProtocolClasses` (see
/// `AppDelegate`) — the SDK's own `URLSession` routes
/// every gateway request through here instead of the network. This mirrors
/// the REST contract documented in `docs/API.md`; a real gateway integration
/// would delete this file entirely and just point `PGConfiguration.environment`
/// at the real API.
///
/// Test values:
/// - Card `4242 4242 4242 4242` → succeeds. Card `4000 0000 0000 0002` → declines.
///   Any other valid (Luhn-passing) number succeeds. Any future expiry, any CVV.
/// - UPI ID `success@upi` → succeeds. `failure@upi` → declines. Any other
///   valid-looking VPA succeeds after a short simulated delay.
final class MockGatewayURLProtocol: URLProtocol, @unchecked Sendable {

    private static let queue = DispatchQueue(label: "mock-gateway")
    private nonisolated(unsafe) static var attempts: [String: Attempt] = [:]

    private struct Attempt {
        let method: String
        var status: String
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "sandbox-api.example-pg.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.queue.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, let url = self.request.url else { return }
            let path = url.path
            let body = self.request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }

            let (status, json) = Self.handle(method: self.request.httpMethod ?? "GET", path: path, body: body ?? [:])
            self.respond(status: status, json: json)
        }
    }

    override func stopLoading() {}

    // MARK: Routing

    private static func handle(method: String, path: String, body: [String: Any]) -> (Int, [String: Any]) {
        if method == "POST", path == "/v1/payment_attempts" {
            return createAttempt(body: body)
        }
        if method == "GET", path.hasPrefix("/v1/payment_attempts/"), path.hasSuffix("/upi/intent") == false,
           path.hasSuffix("/upi/collect") == false, path.hasSuffix("/card/tokenize") == false,
           path.hasSuffix("/net_banking/initiate") == false {
            let id = path.replacingOccurrences(of: "/v1/payment_attempts/", with: "")
            return status(attemptId: id)
        }
        if method == "POST", path.hasSuffix("/upi/intent") {
            return upiIntent(path: path)
        }
        if method == "POST", path.hasSuffix("/upi/collect") {
            return upiCollect(path: path, body: body)
        }
        if method == "POST", path.hasSuffix("/card/tokenize") {
            return cardTokenize(path: path, body: body)
        }
        if method == "GET", path == "/v1/net_banking/banks" {
            return (200, ["banks": [
                ["id": "hdfc", "name": "HDFC Bank", "icon_url": NSNull()],
                ["id": "icici", "name": "ICICI Bank", "icon_url": NSNull()],
                ["id": "sbi", "name": "State Bank of India", "icon_url": NSNull()],
                ["id": "axis", "name": "Axis Bank", "icon_url": NSNull()]
            ]])
        }
        if method == "POST", path.hasSuffix("/net_banking/initiate") {
            return (200, ["redirect_url": "https://example.com/mock-bank-login"])
        }
        return (404, ["code": "not_found", "message": "No mock route for \(method) \(path)."])
    }

    private static func createAttempt(body: [String: Any]) -> (Int, [String: Any]) {
        let id = "att_\(UUID().uuidString.prefix(10))"
        let method = body["method"] as? String ?? "upi"
        attempts[id] = Attempt(method: method, status: "created")
        return (200, ["attempt_id": id, "order_token": body["order_token"] ?? "", "status": "created"])
    }

    private static func status(attemptId: String) -> (Int, [String: Any]) {
        guard let attempt = attempts[attemptId] else {
            return (404, ["code": "not_found", "message": "Unknown attempt \(attemptId)."])
        }
        var json: [String: Any] = [
            "attempt_id": attemptId,
            "order_token": "order",
            "status": attempt.status,
            "method": attempt.method
        ]
        if attempt.status == "succeeded" {
            json["verification_reference"] = "mock_ref_\(attemptId)"
        }
        if attempt.status == "failed" {
            json["failure_reason"] = "The mock gateway declined this attempt."
        }
        return (200, json)
    }

    private static func upiIntent(path: String) -> (Int, [String: Any]) {
        (200, ["intent_url": "upi://pay?pa=merchant@okbank&pn=PGSampleStore&am=499.00&cu=INR"])
    }

    private static func upiCollect(path: String, body: [String: Any]) -> (Int, [String: Any]) {
        guard let id = attemptId(fromSuffixedPath: path, suffix: "/upi/collect") else {
            return (404, ["code": "not_found", "message": "Unknown attempt."])
        }
        let vpa = (body["vpa"] as? String ?? "").lowercased()
        let outcome: String
        switch vpa {
        case "failure@upi": outcome = "failed"
        default: outcome = "succeeded" // includes "success@upi" and any other valid VPA
        }
        attempts[id]?.status = outcome
        // The collect call itself just acknowledges receipt; the real
        // outcome is picked up by the status poll immediately after.
        return (200, ["status": "pending"])
    }

    private static func cardTokenize(path: String, body: [String: Any]) -> (Int, [String: Any]) {
        guard let id = attemptId(fromSuffixedPath: path, suffix: "/card/tokenize") else {
            return (404, ["code": "not_found", "message": "Unknown attempt."])
        }
        let cardNumber = (body["card_number"] as? String ?? "").filter(\.isNumber)
        let outcome: String
        switch cardNumber {
        case "4000000000000002": outcome = "failed"
        default: outcome = "succeeded" // includes 4242 4242 4242 4242
        }
        attempts[id]?.status = outcome
        return (200, [
            "card_token": "tok_\(UUID().uuidString.prefix(10))",
            "three_d_s_redirect_url": NSNull(),
            "status": outcome
        ])
    }

    private static func attemptId(fromSuffixedPath path: String, suffix: String) -> String? {
        guard path.hasSuffix(suffix) else { return nil }
        let prefix = "/v1/payment_attempts/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count).dropLast(suffix.count))
    }

    // MARK: Response helper

    private func respond(status: Int, json: [String: Any]) {
        guard let url = request.url else { return }
        let data = (try? JSONSerialization.data(withJSONObject: json)) ?? Data()
        let response = HTTPURLResponse(
            url: url, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

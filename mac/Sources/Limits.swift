import Foundation

/// Fetches the real subscription limits, straight from Anthropic.
///
/// WHY THIS EXISTS
/// ---------------
/// Claude Code keeps the percentages in a cache in ~/.claude.json with a
/// 5-minute deadline. Except the cache does not refresh itself: it is
/// rewritten when an API response carries the limit headers. If you go days
/// without opening the usage panel, the number on disk sits still — measured,
/// three days.
///
/// Here we make the same call Claude Code makes. The endpoint came from
/// reading its own binary:
///
///     fetchUtilization: GET /api/oauth/usage
///
/// ABOUT THE CREDENTIAL
/// --------------------
/// The access token belongs to Claude Code and lives in the macOS keychain.
/// This app asks the system, and it is **macOS** that decides — showing a
/// dialog for you to authorize the first time. Without your explicit
/// authorization there is no read: the app falls back to the on-disk cache and
/// reports its age.
///
/// The token never leaves your machine. It goes in a header to
/// api.anthropic.com and nowhere else. The bridge never even sees it — what
/// travels to it is only the result, over 127.0.0.1.
enum Limits {

    /// The keychain item Claude Code creates when it authenticates.
    private static let service = "Claude Code-credentials"
    private static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    enum Failure: Error, Equatable {
        case noCredential(OSStatus)   // includes the "you declined" case
        case noToken
        /// The status and, when the server sends it, Retry-After in seconds.
        /// We keep the value because a 429 without a backoff becomes a
        /// permanent 429.
        case http(Int, TimeInterval?)
        case network(String)

        var description: String {
            switch self {
            case .noCredential(let s) where s == errSecUserCanceled:
                return "keychain access declined"
            case .noCredential(let s) where s == errSecItemNotFound:
                return "Claude Code credential not found"
            case .noCredential(let s):
                // The number matters: without it, "it did not work" is
                // undebuggable.
                return "keychain refused (status \(s))"
            case .noToken:
                return "credential has no access token"
            case .http(401, _), .http(403, _):
                return "credential expired — open Claude Code"
            case .http(let c, _):
                return "Anthropic answered \(c)"
            case .network(let m):
                return m
            }
        }
    }

    // MARK: - keychain

    private nonisolated static func token() throws -> String {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            throw Failure.noCredential(status)
        }
        guard let raw = try? JSONSerialization.jsonObject(with: data),
              let t = find(raw, key: "accessToken") else {
            throw Failure.noToken
        }
        return t
    }

    /// The credential format is undocumented and has already changed nesting
    /// level between versions. Searching for the key at any depth costs
    /// nothing and survives reorganisation.
    private static func find(_ node: Any, key: String) -> String? {
        if let d = node as? [String: Any] {
            for (k, v) in d {
                if k.caseInsensitiveCompare(key) == .orderedSame,
                   let s = v as? String, !s.isEmpty { return s }
                if let found = find(v, key: key) { return found }
            }
        }
        if let a = node as? [Any] {
            for v in a { if let found = find(v, key: key) { return found } }
        }
        return nil
    }

    // MARK: - fetching

    /// Returns the raw utilization object, exactly as Anthropic sent it.
    /// The bridge is what interprets it — it already knows the shape from the
    /// cache.
    static func fetch() async throws -> [String: Any] {
        // OFF the main actor, necessarily.
        //
        // SecItemCopyMatching is synchronous and, when macOS decides to ask for
        // your authorization, it only returns after you answer the dialog.
        // Called from the main actor, that freezes the entire interface while
        // the window waits — and the panel locks up at exactly the moment it
        // needs to explain what is going on.
        let t = try await Task.detached(priority: .userInitiated) {
            try token()
        }.value

        var req = URLRequest(url: endpoint)
        req.httpMethod = "GET"
        req.timeoutInterval = 10
        req.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let data: Data, resp: URLResponse
        do {
            (data, resp) = try await URLSession.shared.data(for: req)
        } catch {
            throw Failure.network(error.localizedDescription)
        }

        guard let http = resp as? HTTPURLResponse else { throw Failure.network("invalid response") }
        guard http.statusCode == 200 else {
            // Retry-After can arrive in seconds or as an HTTP date. We only
            // handle the first: it is what Anthropic sends, and guessing at the
            // second would mean inventing a backoff on a format we have not
            // seen.
            let ra = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw Failure.http(http.statusCode, ra)
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.network("response is not JSON")
        }
        return obj
    }

    /// Tells the bridge why it did not work, so the reason shows up in /app
    /// instead of staying trapped inside the app. Diagnosing "it is using the
    /// cache" without knowing the cause is guesswork.
    static func reportFailure(_ reason: String, port: Int) async {
        await post(["error": reason], port: port)
    }

    /// Hands it to the bridge, which then prefers this over the on-disk cache.
    static func deliver(_ utilization: [String: Any], port: Int) async {
        await post(utilization, port: port)
    }

    private static func post(_ bodyObj: [String: Any], port: Int) async {
        guard let body = try? JSONSerialization.data(withJSONObject: bodyObj) else { return }
        var req = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/limits")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 5
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = body
        _ = try? await URLSession.shared.data(for: req)
    }
}

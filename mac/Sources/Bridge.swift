import Foundation
import Combine

/// Owns the bridge process and the state polling.
///
/// TWO DECISIONS WORTH EXPLAINING
///
/// 1. It runs with /usr/bin/python3, the Python 3.9 that ships with macOS —
///    never the one from asdf. The bridge was written with the standard
///    library only and got `from __future__ import annotations` precisely so
///    it fits in 3.9. That way the app does not break the day you switch
///    versions.
///
/// 2. If a bridge is already up on the port, the app ADOPTS it instead of
///    trying to start another and failing with "address in use". Whoever
///    starts one from a terminal while developing keeps working with the app
///    open.
@MainActor
final class Bridge: ObservableObject {

    enum State: Equatable {
        case stopped
        case starting
        case running      // our process
        case adopted      // already up, not ours
        case failed(String)

        var description: String {
            switch self {
            case .stopped:         return "stopped"
            case .starting:        return "starting…"
            case .running:         return "running"
            case .adopted:         return "running (external)"
            case .failed(let m):   return "failed: \(m)"
            }
        }

        var alive: Bool {
            if case .running = self { return true }
            if case .adopted = self { return true }
            return false
        }
    }

    static let port = 4666

    /// Single instance. It exists so the NSApplication delegate can bring the
    /// bridge down on shutdown without the App having to hand it the reference
    /// — SwiftUI gives no good hook for that.
    static let shared = Bridge()

    @Published private(set) var state: State = .stopped
    @Published private(set) var data: AppState?
    /// Last polling failure, so the panel does not lie by staying silent.
    @Published private(set) var pollError: String?
    /// Last failure fetching the real limits. nil = it worked.
    @Published private(set) var limitsError: String?

    /// Fetch the limits straight from Anthropic (asks for keychain access).
    /// Turned off, the app falls back to Claude Code's on-disk cache only.
    @Published var fetchLimits: Bool = UserDefaults.standard
        .object(forKey: "fetchLimits") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(fetchLimits, forKey: "fetchLimits")
            if fetchLimits { Task { await fetchNow() } }
        }
    }

    /// A mascot loose on the desktop. On by default: it is the point of the
    /// project — a character you see without having to click.
    @Published var floating: Bool = UserDefaults.standard
        .object(forKey: "floating") as? Bool ?? true {
        didSet {
            UserDefaults.standard.set(floating, forKey: "floating")
            floating ? Floating.shared.show(self)
                     : Floating.shared.hide()
        }
    }

    // MARK: - when to ask for the limits
    //
    // The yardstick is not the clock, it is consumption. A limit only moves
    // when you spend, so the moment the answer can be different is right after
    // a task finishes. Asking every 5 minutes with an idle machine was
    // spending a request to confirm nothing had changed.
    //
    // FLOOR exists because "task" here means TURN, not session: Stop fires at
    // the end of every response, and in a fast iteration that is several per
    // minute. Without it the new design would ask far MORE than the old one —
    // the opposite of what you want when the server is already returning 429.
    private static let limitsFloor: TimeInterval = 600     // 10 min
    // CEILING covers the opposite case: nobody working, number ageing.
    private static let limitsCeiling: TimeInterval = 3600  // 1 h

    // 429 is the server saying "slow down". Repeating at the same rate is the
    // recipe for staying blocked — that is how the limits sat frozen at the
    // same value for 24h. Double on every refusal, and Retry-After takes
    // precedence over our guess whenever it arrives.
    private static let initialBackoff: TimeInterval = 900  // 15 min
    private static let maxBackoff: TimeInterval = 4 * 3600

    private var proc: Process?
    private var stopRequested = false
    private var timer: Timer?
    private var attempts = 0

    private var lastSeenDone = -1
    /// A task that finished INSIDE the floor. Kept, not discarded: otherwise
    /// the trigger is lost and the fetch would only return on the ceiling, an
    /// hour later.
    private var donePending = false
    private var lastLimitsFetch: Date?
    /// Backoff survives a relaunch, on purpose.
    ///
    /// It used to live only in memory, and that defeated it: every launch
    /// starts with `lastLimitsFetch == nil` and fires a request immediately.
    /// Eight app restarts in one afternoon — renames, redeploys — became eight
    /// immediate hits against a server that had asked us to wait, and the
    /// backoff never got past its first step. "Open at login" would do the
    /// same thing on any machine that reboots.
    ///
    /// A 429 is about the ACCOUNT, not about this process. Forgetting it on
    /// exit is forgetting something the server told us.
    private var blockedUntil: Date? {
        get { UserDefaults.standard.object(forKey: "limitsBlockedUntil") as? Date }
        set { UserDefaults.standard.set(newValue, forKey: "limitsBlockedUntil") }
    }
    private var backoff: TimeInterval {
        get { UserDefaults.standard.double(forKey: "limitsBackoff") }
        set { UserDefaults.standard.set(newValue, forKey: "limitsBackoff") }
    }

    private var base: URL { URL(string: "http://127.0.0.1:\(Self.port)")! }

    /// server.py travels inside the bundle: the app is self-contained and can
    /// be moved to /Applications without dragging the repository along.
    private var scriptURL: URL? {
        Bundle.main.resourceURL?
            .appendingPathComponent("bridge", isDirectory: true)
            .appendingPathComponent("server.py")
    }

    // MARK: - lifecycle

    func start() {
        stopRequested = false
        state = .starting

        Task {
            // Someone already serving? Then the process is theirs, not ours.
            if await responds() {
                state = .adopted
                startPolling()
                if floating { Floating.shared.show(self) }
                return
            }
            startProcess()
        }
    }

    private func startProcess() {
        guard let script = scriptURL,
              FileManager.default.fileExists(atPath: script.path) else {
            state = .failed("server.py did not ship in the bundle")
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [script.path, "\(Self.port)"]
        p.currentDirectoryURL = script.deletingLastPathComponent()
        // Do not inherit the terminal: the app can be launched from Finder.
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice

        // Safety net against orphans: the bridge watches this PID and shuts
        // itself down if the app disappears. Covers force-quit and crashes,
        // where none of our exit code gets to run.
        var env = ProcessInfo.processInfo.environment
        env["WISP_PARENT"] = "\(ProcessInfo.processInfo.processIdentifier)"
        p.environment = env

        p.terminationHandler = { [weak self] finished in
            Task { @MainActor in
                self?.processDied(status: finished.terminationStatus)
            }
        }

        do {
            try p.run()
            proc = p
            state = .running
            startPolling()
            if floating { Floating.shared.show(self) }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    private func processDied(status: Int32) {
        proc = nil
        stopPolling()

        if stopRequested {
            state = .stopped
            return
        }

        // It died on its own: try again, with a growing wait so we do not spin
        // in a tight loop if the fault is permanent.
        attempts += 1
        guard attempts <= 5 else {
            state = .failed("died \(attempts)x, giving up")
            return
        }
        let wait = Double(min(attempts * 2, 30))
        state = .failed("crashed (status \(status)), back in \(Int(wait))s")
        Task {
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            if !stopRequested { start() }
        }
    }

    func stop() {
        stopRequested = true
        stopPolling()
        // An adopted one is not ours to kill — whoever started it takes it down.
        if case .adopted = state {
            state = .stopped
            data = nil
            return
        }
        proc?.terminate()
        proc = nil
        state = .stopped
        data = nil
    }

    func toggle() {
        state.alive ? stop() : { attempts = 0; start() }()
    }

    // MARK: - polling

    /// Fetches the real limits and hands them to the bridge.
    ///
    /// The first call makes macOS ask for your authorization to read the Claude
    /// Code credential. If you decline, we TURN THE OPTION OFF — asking again
    /// every 5 minutes would be harassment, and "no" is an answer.
    private func updateLimits() async {
        guard fetchLimits, state.alive else { return }
        do {
            let u = try await Limits.fetch()
            await Limits.deliver(u, port: Self.port)
            limitsError = nil
            backoff = 0
            blockedUntil = nil
        } catch let f as Limits.Failure {
            limitsError = f.description
            await Limits.reportFailure(f.description, port: Self.port)
            if case .noCredential(let s) = f, s == errSecUserCanceled {
                fetchLimits = false
            }
            if case .http(let code, let retryAfter) = f, code == 429 {
                backoff = min(max(backoff * 2, Self.initialBackoff), Self.maxBackoff)
                blockedUntil = Date().addingTimeInterval(max(retryAfter ?? 0, backoff))
            }
        } catch {
            limitsError = error.localizedDescription
        }
    }

    /// Decides whether it is time to ask. Called on every /app poll, which
    /// already runs every 2 seconds — it needs no timer of its own.
    private func maybeFetchLimits(done: Int?) async {
        guard fetchLimits, state.alive else { return }
        let now = Date()

        // The counter is watched ALWAYS, even when we are not going to fetch
        // now: it is what turns "finished during the floor" into a fetch later.
        if let d = done, d != lastSeenDone {
            if lastSeenDone >= 0 { donePending = true }
            lastSeenDone = d
        }
        if let until = blockedUntil, now < until { return }

        guard let last = lastLimitsFetch else {
            await fetchNow()                          // first time
            return
        }
        let since = now.timeIntervalSince(last)
        if since >= Self.limitsCeiling || (donePending && since >= Self.limitsFloor) {
            await fetchNow()
        }
    }

    private func fetchNow() async {
        donePending = false
        lastLimitsFetch = Date()
        await updateLimits()
    }

    private func startPolling() {
        attempts = 0
        stopPolling()
        // 2s: the panel is only visible while open, and nothing here changes
        // fast enough to justify more.
        let t = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
        Task { await poll() }
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    private func responds() async -> Bool {
        var req = URLRequest(url: base.appendingPathComponent("health"))
        req.timeoutInterval = 2
        guard let (_, resp) = try? await URLSession.shared.data(for: req),
              let http = resp as? HTTPURLResponse else { return false }
        return http.statusCode == 200
    }

    private func poll() async {
        var req = URLRequest(url: base.appendingPathComponent("app"))
        req.timeoutInterval = 4
        do {
            let (raw, _) = try await URLSession.shared.data(for: req)
            data = try JSONDecoder().decode(AppState.self, from: raw)
            pollError = nil
            await maybeFetchLimits(done: data?.tasks_done)
        } catch {
            pollError = error.localizedDescription
        }
    }

    /// Builds an instance holding fixed data, with no process and no polling.
    ///
    /// It exists for mac/Shots, which renders the panel for the documentation.
    /// A real screenshot would carry real project names, real usage and the
    /// board's address into a public README — permanently. Synthetic data also
    /// makes the states that are hard to catch live (error, waiting) as easy to
    /// photograph as the others.
    static func fixture(_ json: String, alive: Bool = true) -> Bridge {
        let b = Bridge()
        b.state = alive ? .adopted : .stopped
        b.data = try? JSONDecoder().decode(AppState.self, from: Data(json.utf8))
        return b
    }

    /// Replaces the fixed data on an instance built by fixture(). Used by the
    /// harnesses to drive the interface through a sequence of states.
    func load(_ json: String) {
        data = try? JSONDecoder().decode(AppState.self, from: Data(json.utf8))
    }

    /// Short text for the menu bar icon. It favours the tightest limit,
    /// because that is the information you would look over there for.
    var barLabel: String {
        guard state.alive else { return "—" }
        guard let d = data else { return "…" }
        if d.peak >= 0 { return "\(d.peak)%" }
        let active = d.sessions.count
        return active > 0 ? "\(active)" : "·"
    }
}

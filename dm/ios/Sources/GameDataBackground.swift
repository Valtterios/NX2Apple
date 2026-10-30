// Game data download in the background: the pieces GameDataSync.prepare() left to fetch are handed to iOS's own download service (a background URLSession),
// which keeps fetching while the app is in the background or not running. Each finished piece comes back here, in this launch or a later one: it is checked
// against the manifest's SHA-256, written in place into <name>.part and recorded in <name>.part.json, exactly as the foreground mode does (GameDataSyncCore.swift).
// Only a window of pieces is queued at a time (iOS keeps a finished piece as a file until the app takes it, so queueing all of a 17 GB game would need the space
// twice); the next ones are queued as pieces come back. Inside LiveContainer the session belongs to LiveContainer's process: whether iOS keeps it going there
// has to be seen on the device, and the foreground mode stays available either way.
// Foundation and CryptoKit only, so the same file builds into the Mac test (with an ordinary session in place of the background one).
import Foundation
import CryptoKit

final class GameDataBackground: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let window = 64                         // pieces queued at once: 1 GB, the most iOS holds for the app while it is away
    private static var live: [String: GameDataBackground] = [:]   // one per session identifier and process: iOS allows no second session with the same identifier
    private static let liveLock = NSLock()
    private static var eventsDone: [String: () -> Void] = [:]   // the app delegate's completion handler for a relaunch in the background (main.m)
    static func liveLockedSetDone(_ id: String, _ h: @escaping () -> Void) { liveLock.withLock { eventsDone[id] = h } }

    let identifier: String
    private(set) var sync: GameDataSync   // the latest start's: its token and progress counters
    private var session: URLSession!
    private let q = DispatchQueue(label: "gamedata.background")   // plans, states and the part files are touched on this queue only
    private var plans: [String: GameDataSync.FilePlan] = [:]
    private var states: [String: GameDataSync.FileState] = [:]
    private var queued = Set<String>()             // "<name>#<piece>" handed to iOS and not back yet
    private var retries: [String: Int] = [:]
    private(set) var lastError: String?
    var onProgress: (() -> Void)?

    /// The session for this game, made once per process. config: nil = a background session (the app); the Mac test passes an ordinary one.
    static func shared(identifier: String, sync: GameDataSync, config: URLSessionConfiguration? = nil) -> GameDataBackground {
        liveLock.withLock {
            if let b = live[identifier] { b.q.sync { b.sync = sync }; return b }
            let b = GameDataBackground(identifier: identifier, sync: sync, config: config)
            live[identifier] = b; return b
        }
    }

    private init(identifier: String, sync: GameDataSync, config: URLSessionConfiguration?) {
        self.identifier = identifier; self.sync = sync
        super.init()
        let c = config ?? URLSessionConfiguration.background(withIdentifier: identifier)
        if config == nil { c.isDiscretionary = false; c.sessionSendsLaunchEvents = true }
        c.httpMaximumConnectionsPerHost = GameDataSync.chunkParallel
        c.requestCachePolicy = .reloadIgnoringLocalCacheData; c.urlCache = nil
        let dq = OperationQueue(); dq.maxConcurrentOperationCount = 1
        session = URLSession(configuration: c, delegate: self, delegateQueue: dq)
        // Pieces still with iOS from an earlier launch count as queued; any it already finished are delivered to the delegate below
        session.getAllTasks { [self] ts in q.sync { for t in ts { if let d = t.taskDescription { queued.insert(d) } } } }
    }

    private func load(_ name: String) -> Bool {
        if plans[name] != nil && states[name] != nil { return true }
        guard let p = try? JSONDecoder().decode(GameDataSync.FilePlan.self, from: Data(contentsOf: sync.planURL(name))),
              let s = try? JSONDecoder().decode(GameDataSync.FileState.self, from: Data(contentsOf: sync.stateURL(name))), s.identity == p.identity else { return false }
        plans[name] = p; states[name] = s; return true
    }

    /// Queues the next pieces of these files (the shader archive first, then the image), up to the window.
    func pump(_ names: [String]) {
        q.async { [self] in
            for name in names where load(name) {
                let p = plans[name]!, s = states[name]!
                for i in s.done.indices where !s.done[i] {
                    if queued.count >= Self.window { return }
                    let d = "\(name)#\(i)"
                    if queued.contains(d) || (retries[d] ?? 0) > 6 { continue }   // given up on: lastError says so, and Download starts it again
                    let lo = Int64(i) * p.chunkSize, r = lo ..< min(lo + p.chunkSize, p.size)
                    let t = session.downloadTask(with: sync.request(p.url, range: r))
                    t.taskDescription = d; t.countOfBytesClientExpectsToReceive = r.len
                    queued.insert(d); t.resume()
                }
            }
        }
    }

    /// A new start: forget earlier failures (and errors), so every missing piece is tried again.
    func reset() { q.sync { retries.removeAll(); lastError = nil; plans.removeAll(); states.removeAll() } }

    /// Pause: everything still queued is cancelled; the pieces already in place stay.
    func cancelAll() {
        session.getAllTasks { [self] ts in ts.forEach { $0.cancel() }; q.async { self.queued.removeAll() } }
    }

    var pending: Int { q.sync { queued.count } }

    // MARK: URLSessionDownloadDelegate

    func urlSession(_ s: URLSession, downloadTask t: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The file at location is gone when this returns: it is read, checked and written here
        guard let d = t.taskDescription, let hash = d.lastIndex(of: "#"), let i = Int(d[d.index(after: hash)...]) else { return }
        let name = String(d[..<hash])
        let code = (t.response as? HTTPURLResponse)?.statusCode ?? 0
        let data = try? Data(contentsOf: location, options: .mappedIfSafe)
        q.sync {
            queued.remove(d)
            guard load(name), var st = states[name], let p = plans[name], i < st.done.count else { return }
            let lo = Int64(i) * p.chunkSize, len = min(lo + p.chunkSize, p.size) - lo
            if code == 401 || code == 403 { lastError = "The server refused access (HTTP \(code)): check the access token."; return }
            guard (code == 206 || (code == 200 && lo == 0)), let all = data else { retry(d, "HTTP \(code)"); return }
            let piece = code == 200 ? all.prefix(Int(len)) : all
            guard Int64(piece.count) == len, sync.hex(SHA256.hash(data: piece)) == p.chunks[i] else { retry(d, "piece \(i) of \(name) does not match the manifest"); return }
            let fd = open(sync.partURL(name).path, O_RDWR); guard fd >= 0 else { lastError = "cannot open \(name).part"; return }
            let w = piece.withUnsafeBytes { pwrite(fd, $0.baseAddress, piece.count, off_t(lo)) }
            fsync(fd); close(fd)
            guard w == piece.count else { lastError = "write failed: is the phone full?"; return }
            st.done[i] = true; states[name] = st
            try? JSONEncoder().encode(st).write(to: sync.stateURL(name), options: .atomic)
            sync.progress.add(done: len, fetched: len)
        }
        onProgress?()
        pump(["msl.tar", "romfs.img"])
    }

    func urlSession(_ s: URLSession, task t: URLSessionTask, didCompleteWithError error: Error?) {
        guard let e = error, let d = t.taskDescription else { return }
        if (e as? URLError)?.code == .cancelled { q.sync { _ = queued.remove(d) }; return }
        q.sync { queued.remove(d); retry(d, e.localizedDescription) }
        pump(["msl.tar", "romfs.img"])
    }

    private func retry(_ d: String, _ why: String) {   // on q; the next pump queues the piece again
        let n = (retries[d] ?? 0) + 1; retries[d] = n
        fputs("game data (background): \(d): \(why); attempt \(n)\n", stderr)
        if n > 6 { lastError = "\(d.replacingOccurrences(of: "#", with: " piece ")) keeps failing: \(why)" }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession s: URLSession) {
        let done = Self.liveLock.withLock { Self.eventsDone.removeValue(forKey: identifier) }
        if let h = done { DispatchQueue.main.async { h() } }
    }
}

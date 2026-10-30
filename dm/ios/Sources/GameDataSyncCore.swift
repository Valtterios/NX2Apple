// Game data download, the part without UI (GameDataSync.swift draws it in the launcher): fetches this build's game data from the player's own server
// (docs/game-data-server.md, scripts/publish_gamedata.py writes what it serves) into the per-game layout main.m reads, Documents/games/<title ID>/:
//   romfs.img   the game files, one image (dm/host/romfs_image.h). Fetched in 16 MiB chunks with HTTP Range requests, several at a time, each checked
//               against the manifest's SHA-256 before it is written in place. That one mechanism gives resuming (chunks already done are kept in
//               romfs.img.part.json), updates that only fetch what changed (a previous version's chunks that still match are kept) and no second copy
//               of 16 GB on the phone. Only a complete image whose identity is the one this build needs (the check main.m makes) becomes romfs.img.
//   msl.tar     the shader libraries of an IPA built with --shaders separate: an uncompressed ustar of b-<version>/, fetched the same way and kept as it is;
//               the host reads the libraries straight from it (dm/gfx/nvn/nvn_mtl.m msl_pack_open), so nothing is unpacked.
// Saves (games/<id>/save, Documents/save) are never touched, and deleting the game data keeps them.
// Foundation and CryptoKit only, so the same file builds into a Mac test (dm/ios/tests/gamedata_sync_check.sh).
import Foundation
import CryptoKit

struct GameDataManifest: Decodable {
    struct Part: Decodable {
        let url: String           // relative to the manifest's URL
        let size: Int64
        let sha256: String        // the whole file (for the server side's own checks; the app checks the chunks)
        let chunkSize: Int64
        let chunks: [String]      // SHA-256 of each chunkSize piece, the last one shorter
        let identity: String?     // romfs: the identity line (dm/host/romfs_identity.h) of the image
        let dir: String?          // shaders: the folder the tar holds, b-<translation chain version>
        enum CodingKeys: String, CodingKey { case url, size, sha256, chunkSize = "chunk_size", chunks, identity, dir }
    }
    let format: Int
    let title: String
    let name: String?
    let version: String
    let build: String
    let romfs: Part
    let shaders: Part?
}

enum GameDataError: LocalizedError {
    case server(String), mismatch(String), local(String)
    var errorDescription: String? {
        switch self { case .server(let s), .mismatch(let s), .local(let s): return s }
    }
    var isAccess: Bool { if case .server(let s) = self { return s.hasPrefix("The server refused") }; return false }
}

/// size= and index= of an identity line: what decides a match (romfs_identity.h), the rest only names the image.
func romfsIdentityKey(_ line: String) -> String {
    line.split(separator: " ").filter { $0.hasPrefix("size=") || $0.hasPrefix("index=") }.sorted().joined(separator: " ")
}
func romfsIdentityField(_ line: String, _ key: String) -> String? {
    line.split(separator: " ").first { $0.hasPrefix(key + "=") }.map { String($0.dropFirst(key.count + 1)) }
}

/// Byte counts for the progress line: done counts every byte that is in place, fetched or kept.
final class GameDataProgress: @unchecked Sendable {
    private let lock = NSLock()
    private var _total: Int64 = 0, _done: Int64 = 0, _fetched: Int64 = 0, _phase = ""
    var total: Int64 { lock.withLock { _total } }
    var done: Int64 { lock.withLock { _done } }
    var fetched: Int64 { lock.withLock { _fetched } }   // over the network: what the speed is measured on
    var phase: String { lock.withLock { _phase } }
    func set(phase: String, total: Int64? = nil) { lock.withLock { _phase = phase; if let t = total { _total = t } } }
    func add(done d: Int64, fetched f: Int64) { lock.withLock { _done += d; _fetched += f } }
}

extension Range where Bound == Int64 { var len: Int64 { upperBound - lowerBound } }

final class GameDataSync: @unchecked Sendable {
    static let chunkParallel = 6
    let servers: [URL]        // e.g. a home address first, then https://games.example.com/data; the manifests are at <server>/<title ID>/[<build>/]manifest.json
    private(set) var using: URL?   // the address that answered: the files come from it too (their URLs are relative to its manifest)
    let token: String
    let gameDir: URL
    let progress = GameDataProgress()
    private let session: URLSession, probe: URLSession

    init(servers: [URL], token: String, gameDir: URL) {
        self.servers = servers; self.token = token; self.gameDir = gameDir
        let q = URLSessionConfiguration.ephemeral   // asking an address that is not reachable from here (the home one, away from home) gives up fast
        q.timeoutIntervalForRequest = 4; q.waitsForConnectivity = false
        probe = URLSession(configuration: q)
        let c = URLSessionConfiguration.default
        c.requestCachePolicy = .reloadIgnoringLocalCacheData; c.urlCache = nil
        c.httpMaximumConnectionsPerHost = Self.chunkParallel
        c.timeoutIntervalForRequest = 60
        c.waitsForConnectivity = true
        session = URLSession(configuration: c)
    }

    func request(_ url: URL, range: Range<Int64>? = nil) -> URLRequest {
        var r = URLRequest(url: url)
        if !token.isEmpty { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let g = range { r.setValue("bytes=\(g.lowerBound)-\(g.upperBound - 1)", forHTTPHeaderField: "Range") }
        r.setValue("identity", forHTTPHeaderField: "Accept-Encoding")   // never compressed: a Range is a byte range of the file as stored
        return r
    }

    /// This build's manifest: <server>/<title>/<build>/manifest.json (exactly the version the app needs), else the latest one at <server>/<title>/manifest.json,
    /// from the first address that answers (a home or Tailscale address before the public one): the download then runs from that address.
    func manifest(title: String, build: String?) async throws -> (GameDataManifest, URL) {
        var last = "no address"
        for server in servers {
            var urls: [URL] = []
            let base = server.appendingPathComponent(title)
            if let b = build, !b.isEmpty { urls.append(base.appendingPathComponent(b).appendingPathComponent("manifest.json")) }
            urls.append(base.appendingPathComponent("manifest.json"))
            for u in urls {
                let data: Data, resp: URLResponse
                do { (data, resp) = try await probe.data(for: request(u)) }
                catch { last = "\(server.host ?? server.absoluteString): \(error.localizedDescription)"; fputs("game data: \(last); trying the next address\n", stderr); break }
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 401 || code == 403 { throw GameDataError.server("The server refused access (HTTP \(code)) at \(server.host ?? ""): check the access token.") }
                guard code == 200 else { last = "HTTP \(code) for \(u.absoluteString)"; continue }
                do { let m = try JSONDecoder().decode(GameDataManifest.self, from: data); using = server; fputs("game data: using \(server.absoluteString)\n", stderr); return (m, u) }
                catch { throw GameDataError.server("The manifest at \(u.absoluteString) cannot be read: \(error.localizedDescription)") }
            }
        }
        throw GameDataError.server("No game data for \(title) on the server (\(last)).")
    }

    private func fetch(_ url: URL, _ range: Range<Int64>, sha: String) async throws -> Data {
        var wait: UInt64 = 1
        for attempt in 1...6 {
            try Task.checkCancellation()
            do {
                let (data, resp) = try await session.data(for: request(url, range: range))
                let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                if code == 401 || code == 403 { throw GameDataError.server("The server refused access (HTTP \(code)): check the access token.") }
                guard code == 206 || (code == 200 && range.lowerBound == 0) else { throw GameDataError.server("HTTP \(code) for \(url.lastPathComponent): the server must answer Range requests (206)") }
                let d = code == 200 ? data.prefix(Int(range.len)) : data
                guard Int64(d.count) == range.len else { throw GameDataError.server("short read: \(d.count) of \(range.len) bytes") }
                guard hex(SHA256.hash(data: d)) == sha else { throw GameDataError.mismatch("chunk at \(range.lowerBound) of \(url.lastPathComponent) does not match the manifest") }
                return Data(d)
            } catch let e as GameDataError where e.isAccess {
                throw e   // a wrong token does not get better by retrying
            } catch is CancellationError { throw CancellationError()
            } catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }   // URLSession reports a cancelled task as its own error
                if attempt == 6 { throw error }
                fputs("game data: \(url.lastPathComponent) bytes \(range.lowerBound): \(error.localizedDescription); retry \(attempt) in \(wait) s\n", stderr)
                try await Task.sleep(nanoseconds: wait * 1_000_000_000); wait = min(wait * 2, 30)
            }
        }
        throw CancellationError()
    }

    func hex<D: Digest>(_ d: D) -> String { d.map { String(format: "%02x", $0) }.joined() }
    func ranges(_ p: GameDataManifest.Part) -> [Range<Int64>] {
        (0..<p.chunks.count).map { i in Int64(i) * p.chunkSize ..< min(Int64(i + 1) * p.chunkSize, p.size) }
    }

    // MARK: one file of the game data (the image, the shader archive)

    struct FileState: Codable { var identity: String; var size: Int64; var chunkSize: Int64; var done: [Bool] }
    /// What a download of one file needs after a restart, kept as <name>.part.plan.json: the background mode (GameDataBackground.swift) reads it when iOS
    /// hands it finished pieces, perhaps in a later launch of the app
    struct FilePlan: Codable { var name: String; var url: URL; var size: Int64; var chunkSize: Int64; var chunks: [String]; var identity: String }

    func planURL(_ name: String) -> URL { gameDir.appendingPathComponent(name + ".part.plan.json") }
    func stateURL(_ name: String) -> URL { gameDir.appendingPathComponent(name + ".part.json") }
    func partURL(_ name: String) -> URL { gameDir.appendingPathComponent(name + ".part") }

    /// Readies gameDir/<name>.part for the manifest's file: a previous version or an interrupted download becomes the starting point, and every piece
    /// that already matches is kept. Returns the pieces still to fetch (none: finish() completes it).
    func prepare(_ p: GameDataManifest.Part, base: URL, name: String) async throws -> [Int] {
        let fm = FileManager.default
        try fm.createDirectory(at: gameDir, withIntermediateDirectories: true)
        let final = gameDir.appendingPathComponent(name), part = partURL(name), stateURL = stateURL(name)
        guard p.chunks.count == Int((p.size + p.chunkSize - 1) / max(p.chunkSize, 1)) else { throw GameDataError.server("the manifest's chunk list does not cover \(name)") }
        // A previous version becomes the starting point: its chunks that still match are kept (an update fetches only what changed), with no second copy
        if fm.fileExists(atPath: final.path) && !fm.fileExists(atPath: part.path) { try fm.moveItem(at: final, to: part) }
        let fresh = !fm.fileExists(atPath: part.path)
        let fd = open(part.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { throw GameDataError.local("cannot open \(part.path) (errno \(errno))") }
        defer { close(fd) }
        guard ftruncate(fd, off_t(p.size)) == 0 else { throw GameDataError.local("not enough space for \(p.size / 1_000_000) MB (errno \(errno))") }
        let id = p.identity ?? p.sha256
        var state = (try? JSONDecoder().decode(FileState.self, from: Data(contentsOf: stateURL))).flatMap {
            $0.identity == id && $0.size == p.size && $0.chunkSize == p.chunkSize && $0.done.count == p.chunks.count ? $0 : nil
        } ?? FileState(identity: id, size: p.size, chunkSize: p.chunkSize, done: Array(repeating: false, count: p.chunks.count))
        let rs = ranges(p)
        progress.set(phase: "Checking the data on the phone", total: progress.total + p.size)
        for (i, r) in rs.enumerated() where state.done[i] { progress.add(done: r.len, fetched: 0) }
        // What is on disk already (an interrupted chunk, a previous version) is kept where it matches; a file made just now holds nothing to check
        var todo: [Int] = []
        var buf = [UInt8](repeating: 0, count: Int(p.chunkSize))
        for (i, r) in rs.enumerated() where !state.done[i] {
            try Task.checkCancellation()
            if !fresh {
                let n = buf.withUnsafeMutableBytes { pread(fd, $0.baseAddress, Int(r.len), off_t(r.lowerBound)) }
                if n == Int(r.len) && hex(SHA256.hash(data: buf[0..<n])) == p.chunks[i] { state.done[i] = true; progress.add(done: r.len, fetched: 0); continue }
            }
            todo.append(i)
        }
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        let plan = FilePlan(name: name, url: URL(string: p.url, relativeTo: base)!.absoluteURL, size: p.size, chunkSize: p.chunkSize, chunks: p.chunks, identity: id)
        try JSONEncoder().encode(plan).write(to: planURL(name), options: .atomic)
        return todo
    }

    /// Fetches the pieces in this process, several at a time (the app has to stay open; the background mode is GameDataBackground.swift).
    func fetchForeground(_ p: GameDataManifest.Part, base: URL, name: String, todo: [Int]) async throws {
        let fd = open(partURL(name).path, O_RDWR); guard fd >= 0 else { throw GameDataError.local("cannot open \(name).part (errno \(errno))") }
        defer { close(fd) }
        let stateURL = stateURL(name)
        var state = try JSONDecoder().decode(FileState.self, from: Data(contentsOf: stateURL))
        let rs = ranges(p), url = URL(string: p.url, relativeTo: base)!.absoluteURL
        progress.set(phase: todo.isEmpty ? "Checking" : name == "romfs.img" ? "Downloading game files" : "Downloading shaders")
        let lock = NSLock(); var sinceSave = 0
        try await withThrowingTaskGroup(of: Void.self) { g in
            var next = todo.makeIterator()
            func add() -> Bool {
                guard let i = next.next() else { return false }
                g.addTask { [self] in
                    let r = rs[i], d = try await fetch(url, r, sha: p.chunks[i])
                    let w = d.withUnsafeBytes { pwrite(fd, $0.baseAddress, d.count, off_t(r.lowerBound)) }
                    guard w == d.count else { throw GameDataError.local("write failed at \(r.lowerBound) (errno \(errno)): is the phone full?") }
                    progress.add(done: r.len, fetched: r.len)
                    let snapshot: FileState? = lock.withLock { state.done[i] = true; sinceSave += 1; if sinceSave >= 8 { sinceSave = 0; return state }; return nil }
                    if let s = snapshot { fsync(fd); try? JSONEncoder().encode(s).write(to: stateURL, options: .atomic) }
                }
                return true
            }
            for _ in 0..<Self.chunkParallel { if !add() { break } }
            do { while try await g.next() != nil { _ = add() } }
            catch { g.cancelAll(); fsync(fd); try? JSONEncoder().encode(lock.withLock { state }).write(to: stateURL, options: .atomic); throw error }
        }
        fsync(fd)
        try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
    }

    /// True when every piece of <name> is in place (by its state file).
    func complete(_ name: String) -> Bool {
        (try? JSONDecoder().decode(FileState.self, from: Data(contentsOf: stateURL(name))))?.done.allSatisfy { $0 } ?? false
    }

    /// Swaps a complete <name>.part in as <name>. accepts: the final check (for the image, main.m's identity check on the device).
    func finish(_ name: String, accepts: (URL) -> Bool = { _ in true }) throws {
        let fm = FileManager.default, final = gameDir.appendingPathComponent(name), part = partURL(name)
        guard complete(name) else { throw GameDataError.local("\(name) is not complete yet") }
        progress.set(phase: "Checking")
        guard accepts(part) else { throw GameDataError.mismatch("The downloaded \(name) is complete but is not the one this app needs: the server has another version.") }
        if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
        try fm.moveItem(at: part, to: final)
        try? fm.removeItem(at: stateURL(name)); try? fm.removeItem(at: planURL(name))
    }

    /// Brings gameDir/<name> (romfs.img, msl.tar) to the manifest's file, fetched in this process.
    func syncFile(_ p: GameDataManifest.Part, base: URL, name: String, accepts: (URL) -> Bool = { _ in true }) async throws {
        let todo = try await prepare(p, base: base, name: name)
        try await fetchForeground(p, base: base, name: name, todo: todo)
        try finish(name, accepts: accepts)
    }

    /// Deletes the downloaded game data: the image, the shader libraries and any half-done download. The saves (games/<id>/save) stay.
    func deleteGameData() throws {
        let fm = FileManager.default
        for n in ["romfs.img", "romfs.img.part", "romfs.img.part.json", "romfs.img.part.plan.json", "msl.tar", "msl.tar.part", "msl.tar.part.json", "msl.tar.part.plan.json", "msl", "msl.part", "msl.part.json", "temp"] {
            let u = gameDir.appendingPathComponent(n)
            if fm.fileExists(atPath: u.path) { try fm.removeItem(at: u) }
        }
    }
}

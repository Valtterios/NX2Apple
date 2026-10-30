// Game data download, the part without UI (GameDataSync.swift draws it in the launcher): fetches this build's game data from the player's own server
// (docs/game-data-server.md, scripts/publish_gamedata.py writes what it serves) into the per-game layout main.m reads, Documents/games/<title ID>/:
//   romfs.img   the game files, one image (dm/host/romfs_image.h). Fetched in 16 MiB chunks with HTTP Range requests, several at a time, each checked
//               against the manifest's SHA-256 before it is written in place. That one mechanism gives resuming (chunks already done are kept in
//               romfs.img.part.json), updates that only fetch what changed (a previous version's chunks that still match are kept) and no second copy
//               of 16 GB on the phone. Only a complete image whose identity is the one this build needs (the check main.m makes) becomes romfs.img.
//   msl/        the shader libraries of an IPA built with --shaders separate: a plain uncompressed tar (ustar) of b-<version>/, unpacked as it arrives,
//               chunk by chunk in order; the unpacker's position is saved after every chunk, so an interruption resumes at the next one.
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

private extension Range where Bound == Int64 { var len: Int64 { upperBound - lowerBound } }

final class GameDataSync: @unchecked Sendable {
    static let chunkParallel = 6
    let server: URL           // e.g. https://games.example.com/data — the manifests are at <server>/<title ID>/[<build>/]manifest.json
    let token: String
    let gameDir: URL
    let progress = GameDataProgress()
    private let session: URLSession

    init(server: URL, token: String, gameDir: URL) {
        self.server = server; self.token = token; self.gameDir = gameDir
        let c = URLSessionConfiguration.default
        c.requestCachePolicy = .reloadIgnoringLocalCacheData; c.urlCache = nil
        c.httpMaximumConnectionsPerHost = Self.chunkParallel
        c.timeoutIntervalForRequest = 60
        c.waitsForConnectivity = true
        session = URLSession(configuration: c)
    }

    private func request(_ url: URL, range: Range<Int64>? = nil) -> URLRequest {
        var r = URLRequest(url: url)
        if !token.isEmpty { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let g = range { r.setValue("bytes=\(g.lowerBound)-\(g.upperBound - 1)", forHTTPHeaderField: "Range") }
        r.setValue("identity", forHTTPHeaderField: "Accept-Encoding")   // never compressed: a Range is a byte range of the file as stored
        return r
    }

    /// This build's manifest: <server>/<title>/<build>/manifest.json (exactly the version the app needs), else the latest one at <server>/<title>/manifest.json.
    func manifest(title: String, build: String?) async throws -> (GameDataManifest, URL) {
        var urls: [URL] = []
        let base = server.appendingPathComponent(title)
        if let b = build, !b.isEmpty { urls.append(base.appendingPathComponent(b).appendingPathComponent("manifest.json")) }
        urls.append(base.appendingPathComponent("manifest.json"))
        var last = "no manifest"
        for u in urls {
            let (data, resp) = try await session.data(for: request(u))
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 { throw GameDataError.server("The server refused access (HTTP \(code)): check the access token.") }
            guard code == 200 else { last = "HTTP \(code) for \(u.absoluteString)"; continue }
            do { return (try JSONDecoder().decode(GameDataManifest.self, from: data), u) }
            catch { throw GameDataError.server("The manifest at \(u.absoluteString) cannot be read: \(error.localizedDescription)") }
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

    private func hex<D: Digest>(_ d: D) -> String { d.map { String(format: "%02x", $0) }.joined() }
    private func ranges(_ p: GameDataManifest.Part) -> [Range<Int64>] {
        (0..<p.chunks.count).map { i in Int64(i) * p.chunkSize ..< min(Int64(i + 1) * p.chunkSize, p.size) }
    }

    // MARK: the game files image

    private struct ImageState: Codable { var identity: String; var size: Int64; var chunkSize: Int64; var done: [Bool] }

    /// Brings gameDir/romfs.img to the manifest's image. accepts: the final check on a complete image (main.m's identity check on the device).
    func syncImage(_ p: GameDataManifest.Part, base: URL, accepts: (URL) -> Bool) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: gameDir, withIntermediateDirectories: true)
        let final = gameDir.appendingPathComponent("romfs.img"), part = gameDir.appendingPathComponent("romfs.img.part")
        let stateURL = gameDir.appendingPathComponent("romfs.img.part.json")
        guard p.chunks.count == Int((p.size + p.chunkSize - 1) / max(p.chunkSize, 1)) else { throw GameDataError.server("the manifest's chunk list does not cover the image") }
        // A previous version becomes the starting point: its chunks that still match are kept (an update fetches only what changed), with no second copy
        if fm.fileExists(atPath: final.path) && !fm.fileExists(atPath: part.path) { try fm.moveItem(at: final, to: part) }
        let fresh = !fm.fileExists(atPath: part.path)
        let fd = open(part.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else { throw GameDataError.local("cannot open \(part.path) (errno \(errno))") }
        defer { close(fd) }
        guard ftruncate(fd, off_t(p.size)) == 0 else { throw GameDataError.local("not enough space for \(p.size / 1_000_000) MB (errno \(errno))") }
        let id = p.identity ?? p.sha256
        var state = (try? JSONDecoder().decode(ImageState.self, from: Data(contentsOf: stateURL))).flatMap {
            $0.identity == id && $0.size == p.size && $0.chunkSize == p.chunkSize && $0.done.count == p.chunks.count ? $0 : nil
        } ?? ImageState(identity: id, size: p.size, chunkSize: p.chunkSize, done: Array(repeating: false, count: p.chunks.count))
        let rs = ranges(p)
        progress.set(phase: "Checking the data on the phone", total: p.size)
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
        progress.set(phase: todo.isEmpty ? "Checking the image" : "Downloading game files")
        let url = URL(string: p.url, relativeTo: base)!.absoluteURL
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
                    let snapshot: ImageState? = lock.withLock { state.done[i] = true; sinceSave += 1; if sinceSave >= 8 { sinceSave = 0; return state }; return nil }
                    if let s = snapshot { fsync(fd); try? JSONEncoder().encode(s).write(to: stateURL, options: .atomic) }
                }
                return true
            }
            for _ in 0..<Self.chunkParallel { if !add() { break } }
            do { while try await g.next() != nil { _ = add() } }
            catch { g.cancelAll(); fsync(fd); try? JSONEncoder().encode(lock.withLock { state }).write(to: stateURL, options: .atomic); throw error }
        }
        fsync(fd)
        progress.set(phase: "Checking the image")
        guard accepts(part) else { throw GameDataError.mismatch("The downloaded image is complete but is not the one this app needs: the server has another version.") }
        if fm.fileExists(atPath: final.path) { try fm.removeItem(at: final) }
        try fm.moveItem(at: part, to: final)
        try? fm.removeItem(at: stateURL)
    }

    // MARK: the shader libraries (a tar, unpacked as it arrives)

    private struct TarState: Codable {
        var sha: String; var nextChunk = 0
        var header = Data()        // the part of a 512-byte header that ended a chunk
        var file: String? = nil    // the member being written, its bytes left and written so far
        var left: Int64 = 0, written: Int64 = 0, skip = false
        var pad: Int64 = 0         // padding to the next 512-byte block
        var ended = false
    }

    /// Unpacks the manifest's tar into gameDir/<into> (msl): into a .part folder first, swapped in when complete; a stamp names the tar it came from.
    func syncTar(_ p: GameDataManifest.Part, base: URL, into name: String) async throws {
        let fm = FileManager.default
        let dest = gameDir.appendingPathComponent(name), work = gameDir.appendingPathComponent(name + ".part")
        let stateURL = gameDir.appendingPathComponent(name + ".part.json"), stamp = dest.appendingPathComponent(".source-sha256")
        if (try? String(contentsOf: stamp, encoding: .utf8)) == p.sha256 { return }
        var st = (try? JSONDecoder().decode(TarState.self, from: Data(contentsOf: stateURL))).flatMap { $0.sha == p.sha256 ? $0 : nil } ?? TarState(sha: p.sha256)
        if st.nextChunk == 0 { try? fm.removeItem(at: work) }
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        let rs = ranges(p)
        progress.set(phase: "Downloading shaders", total: p.size)
        progress.add(done: rs.prefix(st.nextChunk).reduce(0) { $0 + $1.len }, fetched: 0)
        let url = URL(string: p.url, relativeTo: base)!.absoluteURL
        var out: FileHandle? = nil
        if let f = st.file, !st.skip {   // resume inside a member: back to where the last whole chunk left it
            let u = work.appendingPathComponent(f)
            if !fm.fileExists(atPath: u.path) { fm.createFile(atPath: u.path, contents: nil) }
            out = try FileHandle(forWritingTo: u); try out!.truncate(atOffset: UInt64(st.written))
        }
        defer { try? out?.close() }
        // In order, with a few chunks in flight ahead of the one being unpacked
        var inflight: [Int: Task<Data, Error>] = [:]
        defer { inflight.values.forEach { $0.cancel() } }
        var i = st.nextChunk
        while i < rs.count && !st.ended {
            for k in i..<min(i + Self.chunkParallel, rs.count) where inflight[k] == nil {
                let r = rs[k], sha = p.chunks[k]
                inflight[k] = Task { [self] in try await fetch(url, r, sha: sha) }
            }
            let data = try await inflight.removeValue(forKey: i)!.value
            try unpack(data, &st, &out, work)
            progress.add(done: Int64(data.count), fetched: Int64(data.count))
            i += 1; st.nextChunk = i
            try? out?.synchronize()
            try JSONEncoder().encode(st).write(to: stateURL, options: .atomic)
        }
        try? out?.close(); out = nil
        guard st.ended || i == rs.count, st.file == nil || st.left == 0 else { throw GameDataError.server("the shader archive ends inside a file") }
        try p.sha256.write(to: work.appendingPathComponent(".source-sha256"), atomically: true, encoding: .utf8)
        if fm.fileExists(atPath: dest.path) { try fm.removeItem(at: dest) }
        try fm.moveItem(at: work, to: dest)
        try? fm.removeItem(at: stateURL)
    }

    /// ustar: regular files and folders; other entries (pax headers, links) are skipped. Paths stay inside the folder.
    private func unpack(_ data: Data, _ st: inout TarState, _ out: inout FileHandle?, _ root: URL) throws {
        var at = data.startIndex
        while at < data.endIndex && !st.ended {
            let avail = Int64(data.endIndex - at)
            if st.left > 0 {
                let n = Int(min(st.left, avail))
                if !st.skip { try out!.write(contentsOf: data[at..<at + n]) }
                st.left -= Int64(n); st.written += Int64(n); at += n
                if st.left == 0 { try out?.close(); out = nil; st.file = nil; st.skip = false }
                continue
            }
            if st.pad > 0 { let n = min(st.pad, avail); st.pad -= n; at += Int(n); continue }   // after a member's data: up to the next 512-byte block
            let need = 512 - st.header.count, n = min(need, Int(avail))
            st.header.append(data[at..<at + n]); at += n
            guard st.header.count == 512 else { continue }
            let h = [UInt8](st.header); st.header = Data()
            if h.allSatisfy({ $0 == 0 }) { st.ended = true; break }
            func field(_ o: Int, _ l: Int) -> String { String(decoding: h[o..<o + l].prefix { $0 != 0 }, as: UTF8.self) }
            let size = Int64(field(124, 12).trimmingCharacters(in: .whitespaces), radix: 8) ?? -1
            guard size >= 0 else { throw GameDataError.server("the shader archive is not a tar") }
            let prefix = field(345, 155), path = (prefix.isEmpty ? "" : prefix + "/") + field(0, 100)
            guard !path.hasPrefix("/"), !path.split(separator: "/").contains("..") else { throw GameDataError.server("the shader archive has an unsafe path: \(path)") }
            let type = h[156]
            st.pad = (512 - size % 512) % 512; st.written = 0
            if type == UInt8(ascii: "5") {
                try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
                st.pad = 0
            } else if type == UInt8(ascii: "0") || type == 0 {
                let u = root.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                FileManager.default.createFile(atPath: u.path, contents: nil)
                if size == 0 { st.file = nil } else { out = try FileHandle(forWritingTo: u); st.file = path; st.left = size; st.skip = false }
            } else if size > 0 { st.file = path; st.left = size; st.skip = true }
        }
    }

    /// Deletes the downloaded game data: the image, the shader libraries and any half-done download. The saves (games/<id>/save) stay.
    func deleteGameData() throws {
        let fm = FileManager.default
        for n in ["romfs.img", "romfs.img.part", "romfs.img.part.json", "msl", "msl.part", "msl.part.json", "temp"] {
            let u = gameDir.appendingPathComponent(n)
            if fm.fileExists(atPath: u.path) { try fm.removeItem(at: u) }
        }
    }
}

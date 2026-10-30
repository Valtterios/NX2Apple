// The launcher's Game data server section: download, update and delete this game's data from the player's own server (GameDataSyncCore.swift does the work,
// docs/game-data-server.md describes the server). The server address and access token come from the fields here, or once from Documents/env.txt
// (DM_DATA_SERVER, DM_DATA_TOKEN). The download runs while the launcher is open; leaving the app pauses it, and the next Download resumes where it stopped.
import SwiftUI
import UIKit

private func info(_ key: String) -> Any? { Bundle.main.object(forInfoDictionaryKey: key) }

@MainActor
final class GameDataModel: ObservableObject {
    @Published var server: String { didSet { UserDefaults.standard.set(server, forKey: "gamedata.server") } }
    @Published var token: String { didSet { UserDefaults.standard.set(token, forKey: "gamedata.token") } }
    @Published var status = ""
    @Published var running = false
    @Published var line = ""          // "4.2 / 15.9 GB · 85 MB/s · 2 min left"
    @Published var fraction = 0.0
    @Published var note = ""
    @Published var confirmDelete = false
    @Published var background: Bool { didSet { UserDefaults.standard.set(background, forKey: "gamedata.background") } }   // GameDataBackground.swift: iOS keeps fetching while the app is away
    private var task: Task<Void, Never>?
    let gameDir = URL(fileURLWithPath: dm_game_dir())

    init() {
        let env = ProcessInfo.processInfo.environment
        server = UserDefaults.standard.string(forKey: "gamedata.server") ?? env["DM_DATA_SERVER"] ?? ""
        token = UserDefaults.standard.string(forKey: "gamedata.token") ?? env["DM_DATA_TOKEN"] ?? ""
        background = UserDefaults.standard.object(forKey: "gamedata.background") as? Bool ?? true
        refresh()
        // A download that was running when the app was left (or that iOS kept going in the background) continues as soon as the launcher shows
        if hasPartial && !server.isEmpty { note = "Continuing the download…"; DispatchQueue.main.async { [weak self] in self?.start() } }
    }

    var expected: String? { dm_expected_romfs_identity() }
    /// The download folder as the Files app shows it: inside LiveContainer, below its Data/Application/<app folder>/
    var whereShown: String {
        let p = gameDir.path
        if let r = p.range(of: "/Data/Application/") { return "LiveContainer › Data › Application › " + p[r.upperBound...].split(separator: "/").joined(separator: " › ") }
        if let r = p.range(of: "/Documents/") { return "On My iPhone › \((info("CFBundleDisplayName") as? String) ?? "the game") › " + p[r.upperBound...].split(separator: "/").joined(separator: " › ") }
        return p
    }
    var imagePath: String { gameDir.appendingPathComponent("romfs.img").path }
    var hasPartial: Bool { ["romfs.img.part.json", "msl.tar.part.json"].contains { FileManager.default.fileExists(atPath: gameDir.appendingPathComponent($0).path) } }
    static func identifier(_ title: String) -> String { "org.nxnative.gamedata." + title }   // one background session per game: two games in one LiveContainer do not share it
    var imageOK: Bool { dm_romfs_status(imagePath) == 0 }
    var hasAny: Bool { ["romfs.img", "romfs.img.part", "msl.tar", "msl.tar.part", "msl"].contains { FileManager.default.fileExists(atPath: gameDir.appendingPathComponent($0).path) } }

    func refresh() {
        let want = expected.flatMap { romfsIdentityField($0, "version") } ?? ""
        var parts: [String] = []
        switch dm_romfs_status(imagePath) {
        case 0: parts.append("Game files ready" + (want.isEmpty ? "" : " (\(want))"))
        case 3: parts.append("Game files are another version: update to \(want)")
        case 2: parts.append(hasPartial ? "Game files partly downloaded" : "Game files incomplete")
        default: parts.append(hasPartial ? "Game files partly downloaded" : "No downloaded game files")
        }
        parts.append(dm_have_shaders() ? "shaders ready" : "shaders missing")
        status = parts.joined(separator: ", ")
        var stale: ObjCBool = false
        if let picked = dm_picked_data_path(&stale), imageOK { note = "A location picked under Game data is in use (\((picked as NSString).lastPathComponent)): choose “Use the app's own data again” to play from the download." }
    }

    var buttonTitle: String {
        if hasPartial { return "Resume download" }
        if dm_romfs_status(imagePath) == 3 { return "Update game data" }
        return imageOK && dm_have_shaders() ? "Check for updates" : "Download game data"
    }

    func start() {
        guard !running else { return }
        // Several addresses, separated by spaces or commas: the first that answers is used (a home or Tailscale address first is fast at home, the public one works anywhere)
        let urls = server.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" }).compactMap { URL(string: String($0)) }.filter { $0.scheme == "https" || $0.scheme == "http" }
        guard !urls.isEmpty else { note = "Enter the server address, e.g. https://games.example.com/data"; return }
        running = true; note = ""; confirmDelete = false
        UIApplication.shared.isIdleTimerDisabled = true
        let sync = GameDataSync(servers: urls, token: token.trimmingCharacters(in: .whitespaces), gameDir: gameDir)
        let want = expected
        task = Task { [weak self] in
            let ticker = Task { [weak self] in await self?.tick(sync.progress, sync) }
            defer { ticker.cancel() }
            do {
                let (m, base) = try await sync.manifest(title: dm_game_title(), build: want.flatMap { romfsIdentityField($0, "build") })
                if let w = want, let have = m.romfs.identity, romfsIdentityKey(w) != romfsIdentityKey(have) {
                    throw GameDataError.mismatch("The server has \(m.name ?? m.title) \(m.version) (\(m.build)), but this app was built for \(romfsIdentityField(w, "version") ?? "another version"): publish that version, or install the matching app.")
                }
                let ownShaders = Bundle.main.resourceURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("msl").appendingPathComponent(dm_shader_dir_name()).path) } ?? false
                var files: [(GameDataManifest.Part, String)] = []
                if let s = m.shaders, !ownShaders {   // an IPA that carries its shaders (the default build) does not fetch them again
                    if let d = s.dir, d != dm_shader_dir_name() { throw GameDataError.mismatch("The server's shaders are \(d), this app needs \(dm_shader_dir_name()): publish them from the same build as the app.") }
                    files.append((s, "msl.tar"))
                }
                files.append((m.romfs, "romfs.img"))
                let accepts: (String) -> (URL) -> Bool = { n in n == "romfs.img" ? { dm_romfs_status($0.path) == 0 } : { _ in true } }
                var todo: [String: [Int]] = [:]
                for (p, n) in files { todo[n] = try await sync.prepare(p, base: base, name: n) }
                if self?.background == true {
                    // Handed to iOS: it keeps fetching while the app is away; this loop only watches, and Pause cancels what is still queued
                    let bg = GameDataBackground.shared(identifier: Self.identifier(m.title), sync: sync)
                    bg.reset(); bg.pump(files.map { $0.1 })
                    sync.progress.set(phase: "Downloading (continues in the background)")
                    do {
                        while !files.allSatisfy({ sync.complete($0.1) }) {
                            if let e = bg.lastError { throw GameDataError.server(e) }
                            try await Task.sleep(nanoseconds: 500_000_000)
                            if bg.pending == 0 { bg.pump(files.map { $0.1 }) }   // nothing queued but pieces missing (a cancelled or given-up piece): queue again
                        }
                    } catch { if error is CancellationError { bg.cancelAll() }; throw error }
                } else {
                    for (p, n) in files { try await sync.fetchForeground(p, base: base, name: n, todo: todo[n] ?? []) }
                }
                for (_, n) in files { try sync.finish(n, accepts: accepts(n)) }
                self?.finish("Done: \(m.name ?? "game data") \(m.version) is ready (from \(sync.using?.host ?? "the server")). Press Play.")
            } catch is CancellationError {
                self?.finish("Paused. Download resumes where it stopped.")
            } catch {
                self?.finish(error.localizedDescription + (self?.hasPartial == true ? " What is done is kept: Resume continues." : ""))
            }
        }
    }

    func cancel() { task?.cancel() }

    private func finish(_ msg: String) {
        running = false; line = ""; task = nil
        UIApplication.shared.isIdleTimerDisabled = false
        refresh(); note = msg
    }

    private func tick(_ p: GameDataProgress, _ sync: GameDataSync) async {
        var last = p.fetched, lastT = Date(), speed = 0.0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let now = Date(), f = p.fetched, dt = now.timeIntervalSince(lastT)
            if dt > 0 { let s = Double(f - last) / dt; speed = speed == 0 ? s : speed * 0.8 + s * 0.2 }
            last = f; lastT = now
            let total = max(p.total, 1), done = p.done
            fraction = min(Double(done) / Double(total), 1)
            let gb = { (b: Int64) in String(format: "%.1f", Double(b) / 1e9) }
            var s = "\(p.phase): \(gb(done)) / \(gb(total)) GB" + (sync.using?.host.map { " via \($0)" } ?? "")
            if speed > 1e5 {
                s += String(format: " · %.0f MB/s", speed / 1e6)
                let left = Double(total - done) / speed
                s += left < 90 ? " · \(Int(left)) s left" : " · \(Int(left / 60)) min left"
            }
            line = s
        }
    }

    func delete() {
        guard confirmDelete else { confirmDelete = true; return }
        confirmDelete = false
        do {
            try GameDataSync(servers: [], token: "", gameDir: gameDir).deleteGameData()
            refresh(); note = "Game data deleted. Your saves are kept."
        } catch { note = "Could not delete: \(error.localizedDescription)" }
    }
}

struct GameDataServerSection: View {
    @StateObject private var m = GameDataModel()

    var body: some View {
        Section {
            TextField("Server address(es): home first, then public, separated by spaces", text: $m.server, axis: .vertical)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(m.running)
            SecureField("Access token (if the server asks for one)", text: $m.token).disabled(m.running)
            Toggle("Keep downloading in the background", isOn: $m.background).disabled(m.running)
            Text(m.status).foregroundStyle(.secondary)
            if m.running {
                ProgressView(value: m.fraction)
                Text(m.line).font(.callout).monospacedDigit().foregroundStyle(.secondary)
                Button("Pause", role: .cancel) { m.cancel() }
            } else {
                Button(m.buttonTitle) { m.start() }
                if m.hasAny {
                    Button(m.confirmDelete ? "Tap again to delete the game data" : "Delete game data", role: .destructive) { m.delete() }
                }
            }
        } header: {
            Text("Game data")
        } footer: {
            VStack(alignment: .leading, spacing: 6) {
                if !m.note.isEmpty { Text(m.note) }
                Text("Downloads this game's files from your server, and resumes if interrupted. Delete frees the space and keeps your saves.")
                Text("In Files: \(m.whereShown)").font(.caption.monospaced())
            }
        }
    }
}

// main.m's app delegate: iOS relaunched the app in the background because a game data download has news; the session is made again to take it,
// and the completion handler is called once it has (GameDataBackground.urlSessionDidFinishEvents)
@_cdecl("dm_gamedata_background_events")
public func dmGamedataBackgroundEvents(_ identifier: NSString, _ done: @escaping @convention(block) () -> Void) {
    let id = identifier as String
    guard id == GameDataModel.identifier(dm_game_title()) else { done(); return }
    GameDataBackground.liveLockedSetDone(id, done)
    let sync = GameDataSync(servers: [], token: UserDefaults.standard.string(forKey: "gamedata.token") ?? "", gameDir: URL(fileURLWithPath: dm_game_dir()))
    _ = GameDataBackground.shared(identifier: id, sync: sync)
}

// The launcher's Game data server section: download, update and delete this game's data from the player's own server (GameDataSyncCore.swift does the work,
// docs/game-data-server.md describes the server). The server address and access token come from the fields here, or once from Documents/env.txt
// (DM_DATA_SERVER, DM_DATA_TOKEN). The download runs while the launcher is open; leaving the app pauses it, and the next Download resumes where it stopped.
import SwiftUI
import UIKit

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
    private var task: Task<Void, Never>?
    let gameDir = URL(fileURLWithPath: dm_game_dir())

    init() {
        let env = ProcessInfo.processInfo.environment
        server = UserDefaults.standard.string(forKey: "gamedata.server") ?? env["DM_DATA_SERVER"] ?? ""
        token = UserDefaults.standard.string(forKey: "gamedata.token") ?? env["DM_DATA_TOKEN"] ?? ""
        refresh()
    }

    var expected: String? { dm_expected_romfs_identity() }
    var imagePath: String { gameDir.appendingPathComponent("romfs.img").path }
    var hasPartial: Bool { FileManager.default.fileExists(atPath: gameDir.appendingPathComponent("romfs.img.part.json").path) || FileManager.default.fileExists(atPath: gameDir.appendingPathComponent("msl.part.json").path) }
    var imageOK: Bool { dm_romfs_status(imagePath) == 0 }
    var hasAny: Bool { ["romfs.img", "romfs.img.part", "msl", "msl.part"].contains { FileManager.default.fileExists(atPath: gameDir.appendingPathComponent($0).path) } }

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
        guard let url = URL(string: server.trimmingCharacters(in: .whitespaces)), url.scheme == "https" || url.scheme == "http" else { note = "Enter the server address, e.g. https://games.example.com/data"; return }
        running = true; note = ""; confirmDelete = false
        UIApplication.shared.isIdleTimerDisabled = true
        let sync = GameDataSync(server: url, token: token.trimmingCharacters(in: .whitespaces), gameDir: gameDir)
        let want = expected
        task = Task { [weak self] in
            let ticker = Task { [weak self] in await self?.tick(sync.progress) }
            defer { ticker.cancel() }
            do {
                let (m, base) = try await sync.manifest(title: dm_game_title(), build: want.flatMap { romfsIdentityField($0, "build") })
                if let w = want, let have = m.romfs.identity, romfsIdentityKey(w) != romfsIdentityKey(have) {
                    throw GameDataError.mismatch("The server has \(m.name ?? m.title) \(m.version) (\(m.build)), but this app was built for \(romfsIdentityField(w, "version") ?? "another version"): publish that version, or install the matching app.")
                }
                let ownShaders = Bundle.main.resourceURL.map { FileManager.default.fileExists(atPath: $0.appendingPathComponent("msl").appendingPathComponent(dm_shader_dir_name()).path) } ?? false
                if let s = m.shaders, !ownShaders {   // an IPA that carries its shaders (the default build) does not fetch them again
                    if let d = s.dir, d != dm_shader_dir_name() { throw GameDataError.mismatch("The server's shaders are \(d), this app needs \(dm_shader_dir_name()): publish them from the same build as the app.") }
                    try await sync.syncTar(s, base: base, into: "msl")
                }
                try await sync.syncImage(m.romfs, base: base) { dm_romfs_status($0.path) == 0 }
                self?.finish("Done: \(m.name ?? "game data") \(m.version) is ready. Press Play.")
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

    private func tick(_ p: GameDataProgress) async {
        var last = p.fetched, lastT = Date(), speed = 0.0
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let now = Date(), f = p.fetched, dt = now.timeIntervalSince(lastT)
            if dt > 0 { let s = Double(f - last) / dt; speed = speed == 0 ? s : speed * 0.8 + s * 0.2 }
            last = f; lastT = now
            let total = max(p.total, 1), done = p.done
            fraction = min(Double(done) / Double(total), 1)
            let gb = { (b: Int64) in String(format: "%.1f", Double(b) / 1e9) }
            var s = "\(p.phase): \(gb(done)) / \(gb(total)) GB"
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
            try GameDataSync(server: URL(fileURLWithPath: "/"), token: "", gameDir: gameDir).deleteGameData()
            refresh(); note = "Game data deleted. Your saves are kept."
        } catch { note = "Could not delete: \(error.localizedDescription)" }
    }
}

struct GameDataServerSection: View {
    @StateObject private var m = GameDataModel()

    var body: some View {
        Section {
            TextField("Server, e.g. https://games.example.com/data", text: $m.server)
                .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().disabled(m.running)
            SecureField("Access token (if the server asks for one)", text: $m.token).disabled(m.running)
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
            Text("Game data server")
        } footer: {
            Text(m.note.isEmpty ? "Downloads this game's files from your own server. Keep the app open while it runs; it resumes if interrupted. Deleting frees the space and keeps your saves." : m.note)
        }
    }
}

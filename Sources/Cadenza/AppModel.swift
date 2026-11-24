import Foundation
import SwiftUI

// MARK: Data returned by the bridge

struct Item: Decodable, Identifiable, Hashable {
    let id = UUID()
    var title: String
    var subtitle: String?
    var thumb: String?
    var kind: String
    var videoId: String?
    var playlistId: String?
    var browseId: String?
    var duration: String?

    private enum CodingKeys: String, CodingKey {
        case title, subtitle, thumb, kind, videoId, playlistId, browseId, duration
    }

    var isRound: Bool { kind == "artist" }
    var artURL: URL? { thumb.flatMap { $0.isEmpty ? nil : URL(string: $0) } }
}

struct PageSection: Decodable, Identifiable {
    let id = UUID()
    var title: String
    var style: String // "carousel" | "list" | "grid"
    var items: [Item]
    var continuation: String?

    private enum CodingKeys: String, CodingKey { case title, style, items, continuation }
}

struct PageHeader: Decodable {
    var title: String
    var subtitle: String?
    var second: String?
    var thumb: String?
    var playlistId: String?
    var round: Bool?

    var artURL: URL? { thumb.flatMap { $0.isEmpty ? nil : URL(string: $0) } }
}

struct Page: Decodable {
    var header: PageHeader?
    var sections: [PageSection]
}

enum Route: Hashable {
    case browse(id: String, title: String)
    case search(String)

    static let home = Route.browse(id: "FEmusic_home", title: "Home")

    var title: String {
        switch self {
        case .browse(_, let title): return title
        case .search(let query): return "Results for “\(query)”"
        }
    }

    /// Library pages only have content for a signed-in account.
    var needsAccount: Bool {
        if case .browse(let id, _) = self {
            return id.hasPrefix("FEmusic_liked") || id.hasPrefix("FEmusic_library") || id == "VLLM"
        }
        return false
    }
}

struct NowPlaying: Equatable {
    var id = ""
    var title = ""
    var artist = ""
    var art = ""
    var duration = 0.0
    var playing = false
    var ad = false
    var format = ""

    var artURL: URL? { art.isEmpty ? nil : URL(string: art) }
    var isEmpty: Bool { id.isEmpty || title.isEmpty }
}

/// Playback position, kept apart from `AppModel` so the 4×/second ticks only redraw the scrubber.
@MainActor
final class PlaybackClock: ObservableObject {
    @Published var time = 0.0
    var scrubbing = false
}

/// Volume, also kept apart so dragging the slider does not redraw the page.
@MainActor
final class VolumeState: ObservableObject {
    @Published var level = 100.0
    var lastSet = Date.distantPast
}

/// What the interface needs from the hidden web player.
@MainActor
protocol Engine: AnyObject {
    func fetch(_ call: String, _ arguments: [String: Any]) async throws -> Data
    func run(_ call: String)
    func openSignIn()
    func reloadPlayer()
}

@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var route = Route.home
    @Published private(set) var backStack: [Route] = []
    @Published private(set) var forwardStack: [Route] = []
    @Published private(set) var page: Page?
    /// Changes whenever a different page is put on screen; drives the page cross-fade.
    @Published private(set) var pageVersion = 0
    @Published private(set) var loading = false
    @Published private(set) var error: String?

    @Published var searchText = ""
    @Published private(set) var playlists: [Item] = []
    @Published private(set) var loggedIn = false
    @Published private(set) var ready = false
    @Published private(set) var now = NowPlaying()
    @Published var showLyrics = UserDefaults.standard.bool(forKey: Prefs.showLyrics) {
        didSet { UserDefaults.standard.set(showLyrics, forKey: Prefs.showLyrics) }
    }
    @Published var webMode = false

    let clock = PlaybackClock()
    let volume = VolumeState()
    let lyrics = LyricsModel()
    weak var engine: Engine?

    private var cache: [Route: Page] = [:]
    private var loadTask: Task<Void, Never>?

    private var loadingMore: Set<String> = []

    init() {
        lyrics.onSeek = { [weak self] in self?.seek(to: $0) }
        lyrics.reference = { [weak self] id in
            struct Reply: Decodable { let text: String }
            guard let data = try? await self?.engine?.fetch("lyrics(id)", ["id": id]),
                  let reply = try? JSONDecoder().decode(Reply.self, from: data) else { return nil }
            return reply.text.isEmpty ? nil : reply.text
        }
    }

    // MARK: Navigation

    func open(_ new: Route) {
        guard new != route else { reload(); return }
        backStack.append(route)
        forwardStack.removeAll()
        show(new)
    }

    func goBack() {
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(route)
        show(previous)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(route)
        show(next)
    }

    func submitSearch() {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty { open(.search(query)) }
    }

    func reload() {
        cache[route] = nil
        show(route)
    }

    private func show(_ new: Route) {
        route = new
        error = nil
        loadTask?.cancel()
        if let cached = cache[new] {
            page = cached
            pageVersion += 1
            loading = false
            return
        }
        page = nil
        pageVersion += 1
        guard ready else { loading = true; return } // loads as soon as the player reports in
        loading = true
        loadTask = Task { [weak self] in
            guard let self, let engine = self.engine else { return }
            do {
                let data: Data
                switch new {
                case .browse(let id, _): data = try await engine.fetch("browse(id)", ["id": id])
                case .search(let query): data = try await engine.fetch("search(query)", ["query": query])
                }
                let page = try JSONDecoder().decode(Page.self, from: data)
                if Task.isCancelled { return }
                self.cache[new] = page
                self.page = page
                self.pageVersion += 1
            } catch {
                if Task.isCancelled { return }
                self.error = "Couldn’t load this page. \(error.localizedDescription)"
            }
            self.loading = false
        }
    }

    private func loadPlaylists() {
        guard loggedIn, let engine else { playlists = []; return }
        Task { [weak self] in
            guard let data = try? await engine.fetch("browse(id)", ["id": "FEmusic_liked_playlists"]),
                  let page = try? JSONDecoder().decode(Page.self, from: data) else { return }
            self?.playlists = page.sections.flatMap(\.items).filter { $0.kind == "playlist" && $0.browseId != nil }
        }
    }

    /// Fetches the next batch of a long list (playlists over ~100 tracks, big libraries).
    func loadMore(_ section: PageSection) {
        guard let token = section.continuation, !loadingMore.contains(token), let engine else { return }
        loadingMore.insert(token)
        let origin = route
        Task { [weak self] in
            struct Batch: Decodable { let items: [Item]; let continuation: String? }
            let data = try? await engine.fetch("more(token)", ["token": token])
            guard let self else { return }
            self.loadingMore.remove(token)
            guard let data, let batch = try? JSONDecoder().decode(Batch.self, from: data),
                  var page = self.cache[origin],
                  let index = page.sections.firstIndex(where: { $0.continuation == token }) else { return }
            page.sections[index].items += batch.items
            // An empty batch means the list is finished even if a token came back.
            page.sections[index].continuation = batch.items.isEmpty ? nil : batch.continuation
            self.cache[origin] = page
            if self.route == origin { self.page = page }
        }
    }

    func toggleLyrics() {
        withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) { showLyrics.toggle() }
    }

    // MARK: Items

    func activate(_ item: Item, in header: PageHeader? = nil) {
        if item.videoId != nil || (item.browseId == nil && item.playlistId != nil) {
            play(item, fallbackPlaylist: header?.playlistId)
        } else if let id = item.browseId {
            open(.browse(id: id, title: item.title))
        }
    }

    func play(_ item: Item, fallbackPlaylist: String? = nil) {
        play(videoId: item.videoId, playlistId: item.playlistId ?? fallbackPlaylist)
    }

    func play(videoId: String?, playlistId: String?, shuffled: Bool = false) {
        guard videoId != nil || playlistId != nil else { return }
        var args = "\(js(videoId)), \(js(playlistId))"
        if args.isEmpty { args = "null, null" }
        engine?.run("play(\(args))")
        if shuffled {
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.engine?.run("shuffle()") }
        }
    }

    private func js(_ value: String?) -> String {
        guard let value, let data = try? JSONEncoder().encode(value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Transport

    func playPause() { engine?.run("playPause()") }
    func next() { engine?.run("next()") }
    func previous() { engine?.run("previous()") }

    func seek(to seconds: Double) {
        clock.time = seconds
        engine?.run("seek(\(seconds))")
    }

    func setVolume(_ value: Double) {
        volume.level = value
        volume.lastSet = Date()
        engine?.run("setVolume(\(Int(value)))")
    }

    func signIn() {
        webMode = true
        engine?.openSignIn()
    }

    // MARK: Updates from the web player

    func playerReported(_ body: [String: Any]) {
        let isReady = body["ready"] as? Bool ?? false
        let isLoggedIn = body["loggedIn"] as? Bool ?? false
        let sessionChanged = isReady && (!ready || isLoggedIn != loggedIn)
        if isReady {
            ready = true
            loggedIn = isLoggedIn
        }
        if sessionChanged {
            cache.removeAll()
            show(route)
            loadPlaylists()
        }

        if body["ad"] as? Bool == true {
            if !now.ad { now.ad = true }
            return
        }
        var updated = NowPlaying(
            id: body["id"] as? String ?? "",
            title: body["title"] as? String ?? "",
            artist: body["artist"] as? String ?? "",
            art: body["art"] as? String ?? "",
            duration: body["duration"] as? Double ?? 0,
            playing: body["playing"] as? Bool ?? false,
            ad: false)
        let afmt = body["afmt"] as? String ?? ""
        updated.format = afmt.isEmpty ? "" : (Self.audioFormats[afmt] ?? "Format \(afmt)")
        if updated != now { now = updated }

        // Ignore the player's echo while the slider is being dragged.
        if let v = body["volume"] as? Double, abs(v - volume.level) > 0.5,
           Date().timeIntervalSince(volume.lastSet) > 1.5 { volume.level = v }

        lyrics.setTrack(Track(
            id: updated.id, title: updated.title, artist: updated.artist,
            album: body["album"] as? String ?? "", duration: updated.duration))
    }

    func playerTime(id: String, _ t: Double) {
        guard id == now.id else { return }
        if !clock.scrubbing { clock.time = t }
        lyrics.setTime(t)
    }

    /// YouTube audio format ids ("itags") for the streams the web player uses.
    private static let audioFormats = [
        "139": "AAC 48 kbps", "140": "AAC 128 kbps", "141": "AAC 256 kbps",
        "249": "Opus 50 kbps", "250": "Opus 70 kbps", "251": "Opus 160 kbps", "774": "Opus 256 kbps",
    ]
}

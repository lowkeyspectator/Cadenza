import Foundation
import SwiftUI

struct LyricLine: Identifiable, Equatable {
    let id: Int
    let time: Double
    let text: String
}

struct Track: Equatable {
    var id = ""
    var title = ""
    var artist = ""
    var album = ""
    var duration = 0.0
}

/// Fetches lyrics from LRCLIB (https://lrclib.net), a free community lyrics database.
/// Only the track title, artist, album and length are sent.
enum LyricsService {
    enum Result {
        case synced([LyricLine])
        case plain(String)
        case instrumental
        case notFound
    }

    private struct Entry: Decodable {
        let albumName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?
    }

    /// - Parameter reference: YouTube Music's own (untimed) lyrics for the track, when it has any.
    ///   LRCLIB is matched only by title, artist and length, so the same title can come back as a
    ///   translation, a romanisation or a different song. The reference decides which candidate is
    ///   really this recording; if none is, the reference itself is shown rather than wrong lyrics.
    /// Throws only when LRCLIB could not be reached, so that is not mistaken for "no lyrics".
    static func fetch(_ track: Track, reference: String?) async throws -> Result {
        var candidates: [Entry] = []

        var exact = URLComponents(string: "https://lrclib.net/api/get")!
        exact.queryItems = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "duration", value: String(Int(track.duration.rounded()))),
        ]
        if !track.album.isEmpty { exact.queryItems?.append(URLQueryItem(name: "album_name", value: track.album)) }
        if let entry: Entry = try await get(exact.url!) { candidates.append(entry) }

        let reference = (reference ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let trusted = candidates.first.map { reference.isEmpty || similarity(text(of: $0), reference) >= 0.6 } ?? false
        if !trusted {
            // Looser search: drop "(Remastered)", "[Official Video]", featured artists and the like.
            var search = URLComponents(string: "https://lrclib.net/api/search")!
            search.queryItems = [
                URLQueryItem(name: "track_name", value: simplified(track.title)),
                URLQueryItem(name: "artist_name", value: primaryArtist(track.artist)),
            ]
            if let entries: [Entry] = try await get(search.url!) {
                candidates += entries
                    .filter { abs(($0.duration ?? 0) - track.duration) <= 4 }
                    .sorted { abs(($0.duration ?? 0) - track.duration) < abs(($1.duration ?? 0) - track.duration) }
            }
        }

        if reference.isEmpty {
            // Nothing to check the words against, so only accept a candidate from the same album.
            // Film songs in particular exist in several languages under one title and artist;
            // showing no lyrics is better than showing another language's.
            let album = fold(track.album)
            let sameAlbum = candidates.filter {
                let theirs = fold($0.albumName ?? "")
                // Exact album only: "DC" and "DC (Telugu)" are different-language releases.
                return !album.isEmpty && theirs == album
            }
            let best = sameAlbum.first { !($0.syncedLyrics ?? "").isEmpty } ?? sameAlbum.first
            return best.flatMap(result(from:)) ?? .notFound
        }

        // Keep only candidates that are the same words as YouTube Music's lyrics; prefer timed ones.
        let matching = candidates
            .map { ($0, similarity(text(of: $0), reference)) }
            .filter { $0.1 >= 0.6 }
            .sorted { $0.1 > $1.1 }
        if let timed = matching.first(where: { !($0.0.syncedLyrics ?? "").isEmpty }),
           case .synced(let lines)? = result(from: timed.0) {
            return .synced(lines)
        }
        return .plain(reference)
    }

    /// The non-Latin writing systems that make up a meaningful share of a text, as Unicode blocks
    /// (Tamil, Telugu, Devanagari, Hangul, …).
    static func scripts(_ s: String) -> Set<UInt32> {
        var counts: [UInt32: Int] = [:]
        var letters = 0
        for scalar in s.unicodeScalars where scalar.properties.isAlphabetic {
            letters += 1
            if scalar.value >= 0x0370 {
                // CJK ideographs span many blocks; treat them as one.
                let block = (0x3400...0x9FFF).contains(scalar.value) ? 0x3400 : scalar.value / 0x80
                counts[block, default: 0] += 1
            }
        }
        guard letters > 0 else { return [] }
        return Set(counts.filter { Double($0.value) / Double(letters) >= 0.08 }.keys)
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .components(separatedBy: CharacterSet.alphanumerics.inverted).joined()
    }

    private static func text(of entry: Entry) -> String {
        if let plain = entry.plainLyrics, !plain.isEmpty { return plain }
        return parseLRC(entry.syncedLyrics ?? "").map(\.text).joined(separator: "\n")
    }

    /// Overlap between two lyric texts, 0…1. Compares words, or character pairs for scripts
    /// written without spaces (Chinese, Japanese, Thai…).
    static func similarity(_ a: String, _ b: String) -> Double {
        func units(_ s: String) -> Set<String> {
            let words = s.lowercased().components(separatedBy: CharacterSet.letters.inverted).filter { !$0.isEmpty }
            let letters = words.joined()
            guard !letters.isEmpty else { return [] }
            if Double(words.count) > Double(letters.count) / 12 {
                return Set(words) // spaced script
            }
            let chars = Array(letters.prefix(6000))
            return Set(zip(chars, chars.dropFirst()).map { String([$0, $1]) })
        }
        // Different writing systems means a different-language version (or a romanisation), even
        // when the two share an English chorus.
        guard scripts(a) == scripts(b) else { return 0 }
        let x = units(a), y = units(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        // Share of the smaller text found in the larger one: tolerant of a missing verse or ad-libs.
        return Double(x.intersection(y).count) / Double(min(x.count, y.count))
    }

    private static func result(from entry: Entry) -> Result? {
        if let synced = entry.syncedLyrics, !synced.isEmpty {
            let lines = parseLRC(synced)
            if !lines.isEmpty { return .synced(lines) }
        }
        if let plain = entry.plainLyrics, !plain.isEmpty { return .plain(plain) }
        if entry.instrumental == true { return .instrumental }
        return nil
    }

    private static let userAgent: String = {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "Cadenza/\(version) (macOS music player; https://github.com/lowkeyspectator/Cadenza)"
    }()

    /// nil when LRCLIB has no entry; throws when it could not be reached or is failing.
    private static func get<T: Decodable>(_ url: URL) async throws -> T? {
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 429 || status >= 500 { throw URLError(.badServerResponse) }
        guard status == 200 else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    static func parseLRC(_ lrc: String) -> [LyricLine] {
        let stamp = try! NSRegularExpression(pattern: #"\[(\d+):(\d+(?:\.\d+)?)\]"#)
        var timed: [(Double, String)] = []
        for raw in lrc.components(separatedBy: .newlines) {
            let range = NSRange(raw.startIndex..., in: raw)
            let matches = stamp.matches(in: raw, range: range)
            guard !matches.isEmpty else { continue }
            let text = stamp.stringByReplacingMatches(in: raw, range: range, withTemplate: "")
                .trimmingCharacters(in: .whitespaces)
            for m in matches {
                guard let min = Double((raw as NSString).substring(with: m.range(at: 1))),
                      let sec = Double((raw as NSString).substring(with: m.range(at: 2))) else { continue }
                timed.append((min * 60 + sec, text))
            }
        }
        return timed.sorted { $0.0 < $1.0 }.enumerated().map {
            LyricLine(id: $0.offset, time: $0.element.0, text: $0.element.1.isEmpty ? "♪" : $0.element.1)
        }
    }

    private static func simplified(_ title: String) -> String {
        var s = title.replacingOccurrences(of: #"\s*[\(\[][^\)\]]*[\)\]]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+-\s+.*(remaster|version|edit|mix|live).*$"#, with: "",
                                   options: [.regularExpression, .caseInsensitive])
        let trimmed = s.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? title : trimmed
    }

    private static func primaryArtist(_ artist: String) -> String {
        let first = artist.components(separatedBy: CharacterSet(charactersIn: ",&•")).first ?? artist
        return first.replacingOccurrences(of: #"\s+(feat\.?|ft\.?|featuring)\s+.*$"#, with: "",
                                          options: [.regularExpression, .caseInsensitive])
            .trimmingCharacters(in: .whitespaces)
    }
}

@MainActor
final class LyricsModel: ObservableObject {
    enum Status: Equatable { case idle, loading, synced, plain(String), instrumental, notFound, failed }

    @Published private(set) var track = Track()
    @Published private(set) var status: Status = .idle
    @Published private(set) var lines: [LyricLine] = []
    @Published private(set) var currentIndex: Int?
    /// Where the lyrics on screen came from, shown under them.
    @Published private(set) var source = ""

    var onSeek: ((Double) -> Void)?
    /// Returns YouTube Music's own lyrics for a video id, or nil when it has none.
    var reference: ((String) async -> String?)?
    private var task: Task<Void, Never>?

    func setTrack(_ new: Track) {
        guard new != track else { return }
        // Duration settles a moment after the track changes; don't refetch for sub-second jitter.
        let sameSong = new.id == track.id && new.title == track.title && new.artist == track.artist
            && abs(new.duration - track.duration) < 1.5
        track = new
        if sameSong && status != .idle { return }

        task?.cancel()
        source = ""
        lines = []
        currentIndex = nil
        guard !new.title.isEmpty, new.duration > 0 else { status = .idle; return }
        status = .loading
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000) // let title/artist settle
            if Task.isCancelled { return }
            let reference = await self?.reference?(new.id)
            if Task.isCancelled { return }
            do {
                let result = try await LyricsService.fetch(new, reference: reference)
                if Task.isCancelled { return }
                self?.apply(result, checked: !(reference ?? "").isEmpty)
            } catch {
                if Task.isCancelled { return }
                // Offline or LRCLIB down: YouTube Music's own lyrics are still worth showing.
                if let reference, !reference.isEmpty {
                    self?.apply(.plain(reference), checked: true)
                } else {
                    self?.status = .failed
                }
            }
        }
    }

    /// Looks the current track up again (after a network failure).
    func retry() {
        let current = track
        track = Track()
        status = .idle
        setTrack(current)
    }

    private func apply(_ result: LyricsService.Result, checked: Bool) {
        switch result {
        case .synced(let l):
            lines = l; status = .synced
            source = checked ? "Timed lyrics from LRCLIB, matched to YouTube Music’s lyrics"
                             : "Timed lyrics from LRCLIB (matched by title, artist and album)"
        case .plain(let text):
            status = .plain(text)
            source = checked ? "Lyrics from YouTube Music" : "Lyrics from LRCLIB"
        case .instrumental: status = .instrumental; source = ""
        case .notFound: status = .notFound; source = ""
        }
    }

    func setTime(_ t: Double) {
        guard status == .synced else { return }
        // Last line that has started (lines are sorted by time).
        var lo = 0, hi = lines.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= t + 0.2 { lo = mid + 1 } else { hi = mid }
        }
        let index = lo > 0 ? lo - 1 : nil
        if index != currentIndex { currentIndex = index }
    }

    func seek(to line: LyricLine) {
        currentIndex = line.id
        onSeek?(line.time)
    }
}

struct LyricsView: View {
    @ObservedObject var model: LyricsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.track.title.isEmpty ? "Lyrics" : model.track.title)
                    .font(.headline).lineLimit(1)
                if !model.track.artist.isEmpty {
                    Text(model.track.artist).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .padding(.horizontal, 20).padding(.top, 34).padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()
            content
            Divider()
            Text(model.source.isEmpty ? " " : model.source).font(.caption2).foregroundStyle(.tertiary)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    @ViewBuilder private var content: some View {
        switch model.status {
        case .idle: message("Play a song to see its lyrics.")
        case .loading: ProgressView().controlSize(.small).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .notFound: message("No lyrics found for this song.")
        case .failed:
            VStack(spacing: 10) {
                Text("Couldn’t load lyrics. Check your internet connection.")
                    .foregroundStyle(.secondary).multilineTextAlignment(.center)
                Button("Try Again") { model.retry() }
            }
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        case .instrumental: message("Instrumental")
        case .plain(let text):
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("No time-synced lyrics for this version, so lines can’t be used to seek.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(text).font(.system(size: 16)).lineSpacing(6).textSelection(.enabled)
                }
                .padding(20).frame(maxWidth: .infinity, alignment: .leading)
            }
        case .synced:
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(model.lines) { line in
                            LineRow(line: line, isCurrent: line.id == model.currentIndex,
                                    isPast: line.id < (model.currentIndex ?? -1)) { model.seek(to: line) }
                                .id(line.id)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 120)
                }
                .onChange(of: model.currentIndex) { _, index in
                    guard let index else { return }
                    withAnimation(motion(.easeInOut(duration: 0.35))) { proxy.scrollTo(index, anchor: .center) }
                }
            }
        }
    }

    private func message(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct LineRow: View {
    let line: LyricLine
    let isCurrent: Bool
    let isPast: Bool
    let action: () -> Void
    // Plain State value rather than @State: the macro form needs Xcode's plugin, which the
    // Command Line Tools alone do not ship.
    private let hover = State(initialValue: false)
    private var hovering: Bool { hover.wrappedValue }

    var body: some View {
        Button(action: action) {
            Text(line.text)
                .font(.system(size: 19, weight: isCurrent ? .bold : .semibold))
                .foregroundStyle(Color.primary.opacity(isCurrent ? 1 : (hovering ? 0.8 : (isPast ? 0.35 : 0.5))))
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10).padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(hovering ? 0.08 : 0)))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hover.wrappedValue = $0 }
        .help("Jump to \(Self.stamp(line.time))")
        .accessibilityHint("Jumps to \(Self.stamp(line.time))")
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
        .animation(motion(.easeInOut(duration: 0.2)), value: isCurrent)
    }

    private static func stamp(_ t: Double) -> String {
        String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

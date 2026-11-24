import AppKit
import SwiftUI

// Note: this file avoids `@State`. With only the Command Line Tools installed (no Xcode) the
// macro behind it is unavailable, so view state lives in `AppModel` instead.

enum Theme {
    static let accent = Color(red: 0.98, green: 0.18, blue: 0.33)
}

// MARK: Root

struct RootView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(model: model)
                .frame(width: 228)
            Divider()
            VStack(spacing: 0) {
                TopBar(model: model)
                ContentView(model: model)
                Divider()
                PlayerBar(model: model)
            }
            .background(Color(nsColor: .windowBackgroundColor))
            if model.showLyrics {
                Divider()
                LyricsView(model: model.lyrics)
                    .frame(width: 330)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        // Opaque backing: the web player sits underneath this view, and without it the player
        // shows through the hairline dividers between the columns.
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(Theme.accent)
        .ignoresSafeArea()
    }
}

/// Bar shown above the web player while it is on screen (sign-in, account settings).
struct WebModeBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack {
            Spacer().frame(width: 78) // traffic lights
            Button { model.webMode = false } label: {
                Label("Back to Cadenza", systemImage: "chevron.left")
            }
            .buttonStyle(.bordered)
            Spacer()
            Text("YouTube Music web player").font(.subheadline).foregroundStyle(.secondary)
            Spacer()
            Spacer().frame(width: 200)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.bar)
        .tint(Theme.accent)
        .ignoresSafeArea()
    }
}

// MARK: Sidebar

private struct SidebarMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .sidebar
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

struct SidebarView: View {
    @ObservedObject var model: AppModel

    private static let library: [(String, String, String)] = [
        ("Liked Songs", "heart", "VLLM"),
        ("Playlists", "music.note.list", "FEmusic_liked_playlists"),
        ("Albums", "square.stack", "FEmusic_liked_albums"),
        ("Artists", "music.mic", "FEmusic_library_corpus_track_artists"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Spacer().frame(height: 44) // traffic lights

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $model.searchText)
                    .textFieldStyle(.plain)
                    .onSubmit { model.submitSearch() }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.primary.opacity(0.07)))
            .padding(.horizontal, 12).padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    row("Home", "house", .home)
                    row("Explore", "square.grid.2x2", .browse(id: "FEmusic_explore", title: "Explore"))

                    heading("Library")
                    ForEach(Self.library, id: \.2) { entry in
                        row(entry.0, entry.1, .browse(id: entry.2, title: entry.0))
                    }

                    if !model.playlists.isEmpty {
                        heading("Playlists")
                        ForEach(model.playlists) { playlist in
                            row(playlist.title, "music.note.list",
                                .browse(id: playlist.browseId ?? "", title: playlist.title))
                        }
                    }
                }
                .padding(.horizontal, 10).padding(.bottom, 12)
            }

            Divider()
            HStack(spacing: 8) {
                if model.loggedIn {
                    Image(systemName: "person.crop.circle.fill").foregroundStyle(.secondary)
                    Text("Signed in").font(.callout).foregroundStyle(.secondary)
                    Spacer()
                } else {
                    Button("Sign In") { model.signIn() }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                    Spacer()
                }
                Button { model.webMode = true } label: { Image(systemName: "globe") }
                    .buttonStyle(.borderless)
                    .help("Open the YouTube Music web player (account and playback settings)")
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
        }
        .background(SidebarMaterial())
    }

    private func heading(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            .padding(.horizontal, 8).padding(.top, 16).padding(.bottom, 4)
    }

    private func row(_ title: String, _ symbol: String, _ route: Route) -> some View {
        let selected = model.route == route
        return Hover { hovering in
            Button { model.open(route) } label: {
                HStack(spacing: 8) {
                    Image(systemName: symbol)
                        .font(.system(size: 14)).foregroundStyle(Theme.accent).frame(width: 20)
                    Text(title).font(.system(size: 13)).lineLimit(1)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(selected ? 0.1 : (hovering ? 0.05 : 0))))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

// MARK: Main column

struct TopBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 4) {
            Button { model.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(model.backStack.isEmpty)
            Button { model.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(model.forwardStack.isEmpty)
            Spacer()
        }
        .buttonStyle(.borderless)
        .font(.system(size: 15, weight: .medium))
        .padding(.horizontal, 20)
        .frame(height: 44)
    }
}

struct ContentView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Group {
            if let error = model.error {
                message("exclamationmark.triangle", error, button: ("Try Again", { model.reload() }))
            } else if let page = model.page {
                if page.sections.isEmpty && page.header == nil {
                    if model.route.needsAccount && !model.loggedIn {
                        message("person.crop.circle", "Sign in to see your library.",
                                button: ("Sign In", { model.signIn() }))
                    } else {
                        message("music.note", "Nothing here yet.", button: nil)
                    }
                } else {
                    PageView(model: model, page: page)
                        .id(model.route) // new scroll position per page
                        .transition(.opacity)
                }
            } else if model.loading {
                ProgressView().controlSize(.small).transition(.opacity)
            } else {
                Color.clear
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(.easeOut(duration: 0.18), value: model.pageVersion)
    }

    private func message(_ symbol: String, _ text: String, button: (String, () -> Void)?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 34)).foregroundStyle(.tertiary)
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let button {
                Button(button.0, action: button.1).buttonStyle(.borderedProminent)
            }
        }
        .padding(40)
    }
}

struct PageView: View {
    @ObservedObject var model: AppModel
    let page: Page

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 28) {
                if let header = page.header {
                    HeaderView(model: model, header: header, firstTrack: firstTrack)
                } else {
                    Text(model.route.title)
                        .font(.system(size: 30, weight: .bold))
                        .padding(.horizontal, 28)
                }
                ForEach(page.sections) { section in
                    SectionView(model: model, section: section, header: page.header,
                                showTitle: page.sections.count > 1 || page.header == nil)
                }
            }
            .padding(.top, 4).padding(.bottom, 28)
        }
    }

    private var firstTrack: Item? {
        page.sections.first { $0.style == "list" }?.items.first { $0.videoId != nil }
    }
}

struct HeaderView: View {
    @ObservedObject var model: AppModel
    let header: PageHeader
    let firstTrack: Item?

    var body: some View {
        let round = header.round ?? false
        HStack(alignment: .bottom, spacing: 24) {
            Artwork(url: header.artURL, size: 210, round: round)
                .shadow(color: .black.opacity(0.25), radius: 14, y: 6)
            VStack(alignment: .leading, spacing: 6) {
                Text(header.title).font(.system(size: 28, weight: .bold)).lineLimit(3)
                if let subtitle = header.subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.system(size: 20)).foregroundStyle(Theme.accent).lineLimit(2)
                }
                if let second = header.second, !second.isEmpty {
                    Text(second).font(.system(size: 12, weight: .medium)).foregroundStyle(.secondary).lineLimit(2)
                }
                if playlistId != nil || firstTrack != nil {
                    HStack(spacing: 10) {
                        Button { play(shuffled: false) } label: {
                            Label("Play", systemImage: "play.fill").frame(width: 92)
                        }
                        Button { play(shuffled: true) } label: {
                            Label("Shuffle", systemImage: "shuffle").frame(width: 92)
                        }
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .padding(.top, 14)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
    }

    private var playlistId: String? { firstTrack?.playlistId ?? header.playlistId }

    private func play(shuffled: Bool) {
        model.play(videoId: firstTrack?.videoId, playlistId: playlistId, shuffled: shuffled)
    }
}

struct SectionView: View {
    @ObservedObject var model: AppModel
    let section: PageSection
    let header: PageHeader?
    let showTitle: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showTitle && !section.title.isEmpty {
                Text(section.title).font(.system(size: 20, weight: .bold)).padding(.horizontal, 28)
            }
            switch section.style {
            case "carousel":
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 18) {
                        ForEach(section.items) { CardView(model: model, item: $0) }
                    }
                    .padding(.horizontal, 28)
                }
            case "grid":
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 160, maximum: 200), spacing: 18, alignment: .top)],
                          alignment: .leading, spacing: 22) {
                    ForEach(section.items) { CardView(model: model, item: $0) }
                    if section.continuation != nil {
                        ProgressView().controlSize(.small).onAppear { model.loadMore(section) }
                    }
                }
                .padding(.horizontal, 28)
            default:
                LazyVStack(spacing: 0) {
                    ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                        TrackRow(model: model, item: item, header: header, number: index + 1)
                    }
                    if section.continuation != nil {
                        ProgressView().controlSize(.small).padding(12).onAppear { model.loadMore(section) }
                    }
                }
                .padding(.horizontal, 20)
            }
        }
    }
}

struct CardView: View {
    @ObservedObject var model: AppModel
    let item: Item

    /// Albums and playlists can start playing straight from the card.
    private var canPlay: Bool { item.videoId != nil || (item.playlistId != nil && !item.isRound) }

    var body: some View {
        Hover { hovering in
            Button { model.activate(item) } label: {
                VStack(alignment: item.isRound ? .center : .leading, spacing: 6) {
                    Artwork(url: item.artURL, size: 160, round: item.isRound)
                        .overlay(alignment: .bottomLeading) {
                            if canPlay && hovering {
                                Button { model.play(item) } label: {
                                    Image(systemName: "play.fill")
                                        .font(.system(size: 13)).foregroundStyle(.white)
                                        .frame(width: 30, height: 30)
                                        .background(.ultraThinMaterial, in: Circle())
                                }
                                .buttonStyle(.plain).padding(8)
                                .transition(.opacity.combined(with: .scale(scale: 0.85)))
                            }
                        }
                        .brightness(hovering ? -0.06 : 0)
                    Text(item.title).font(.system(size: 13)).lineLimit(2)
                        .multilineTextAlignment(item.isRound ? .center : .leading)
                    if let subtitle = item.subtitle, !subtitle.isEmpty {
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(2)
                            .multilineTextAlignment(item.isRound ? .center : .leading)
                    }
                }
                .frame(width: 160, alignment: item.isRound ? .center : .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle())
            .animation(.easeOut(duration: 0.15), value: hovering)
            .contextMenu { ItemMenu(model: model, item: item) }
        }
    }
}

struct TrackRow: View {
    @ObservedObject var model: AppModel
    let item: Item
    let header: PageHeader?
    let number: Int

    var body: some View {
        let current = item.videoId != nil && item.videoId == model.now.id
        Hover { hovering in
            Button { model.activate(item, in: header) } label: {
                HStack(spacing: 12) {
                    leading(current: current, hovering: hovering)
                        .frame(width: 40, height: item.artURL != nil ? 40 : 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title).font(.system(size: 13))
                            .foregroundStyle(current ? Theme.accent : Color.primary).lineLimit(1)
                        if let subtitle = item.subtitle, !subtitle.isEmpty {
                            Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 12)
                    if let duration = item.duration {
                        Text(duration).font(.system(size: 12).monospacedDigit()).foregroundStyle(.secondary)
                    } else if item.videoId == nil && item.browseId != nil {
                        Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(hovering ? 0.09 : (number % 2 == 1 ? 0.035 : 0))))
                .contentShape(Rectangle())
            }
            .buttonStyle(PressableStyle(scale: 1))
            .contextMenu { ItemMenu(model: model, item: item) }
        }
    }

    @ViewBuilder private func leading(current: Bool, hovering: Bool) -> some View {
        let playable = item.videoId != nil
        let symbol = current ? (model.now.playing ? "speaker.wave.2.fill" : "speaker.fill") : "play.fill"
        if item.artURL != nil {
            // Rows with their own artwork (search results, playlists, mixes).
            ZStack {
                Artwork(url: item.artURL, size: 40, round: item.isRound, corner: 5)
                if current || (hovering && playable) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous).fill(.black.opacity(0.45))
                    Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(.white)
                }
            }
        } else if current || (hovering && playable) {
            Image(systemName: symbol).font(.system(size: 12)).foregroundStyle(Theme.accent)
        } else {
            // Album tracks share the album cover, so show the track number instead.
            Text("\(number)").font(.system(size: 13).monospacedDigit()).foregroundStyle(.secondary)
        }
    }
}

struct ItemMenu: View {
    @ObservedObject var model: AppModel
    let item: Item

    var body: some View {
        if item.videoId != nil || item.playlistId != nil {
            Button("Play") { model.play(item) }
        }
        if let id = item.browseId {
            Button("Open") { model.open(.browse(id: id, title: item.title)) }
        }
        if let link {
            Divider()
            Button("Copy Link") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link, forType: .string)
            }
        }
    }

    private var link: String? {
        if let v = item.videoId { return "https://music.youtube.com/watch?v=\(v)" }
        if let b = item.browseId { return "https://music.youtube.com/browse/\(b)" }
        if let p = item.playlistId { return "https://music.youtube.com/playlist?list=\(p)" }
        return nil
    }
}

private struct PressableStyle: ButtonStyle {
    var scale = 0.97

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.75 : 1)
            .scaleEffect(configuration.isPressed ? scale : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
    }
}

// MARK: Player bar

struct PlayerBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        let now = model.now
        HStack(spacing: 16) {
            // Transport
            HStack(spacing: 18) {
                Button { model.previous() } label: { Image(systemName: "backward.fill") }
                Button { model.playPause() } label: {
                    Image(systemName: now.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 22)).frame(width: 26)
                        .contentTransition(.symbolEffect(.replace))
                }
                Button { model.next() } label: { Image(systemName: "forward.fill") }
            }
            .font(.system(size: 15))
            .buttonStyle(PressableStyle(scale: 0.88))
            .foregroundStyle(.primary)
            .opacity(now.isEmpty ? 0.35 : 1)
            .disabled(now.isEmpty)

            // Now playing
            HStack(spacing: 10) {
                Artwork(url: now.artURL, size: 44, corner: 5)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(title(now)).font(.system(size: 13, weight: .medium)).lineLimit(1)
                        Text(subtitle(now)).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .animation(.easeInOut(duration: 0.2), value: now.id)
                    Scrubber(model: model, clock: model.clock, duration: now.duration,
                             enabled: !(now.isEmpty || now.ad))
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.primary.opacity(0.05)))
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)

            // Volume and panels
            HStack(spacing: 10) {
                if !now.format.isEmpty {
                    Text(now.format).font(.system(size: 10, weight: .medium)).foregroundStyle(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.4)))
                        .help("Audio stream currently playing")
                        .fixedSize()
                }
                VolumeSlider(model: model, volume: model.volume)
                Button { model.toggleLyrics() } label: {
                    Image(systemName: model.showLyrics ? "quote.bubble.fill" : "quote.bubble")
                        .foregroundStyle(model.showLyrics ? Theme.accent : Color.primary)
                }
                .buttonStyle(PressableStyle(scale: 0.88)).font(.system(size: 15))
                .help("Lyrics")
            }
        }
        .padding(.horizontal, 20)
        .frame(height: 68)
        .background(.bar)
    }

    private func title(_ now: NowPlaying) -> String {
        now.ad ? "Advertisement" : (now.isEmpty ? "Not Playing" : now.title)
    }

    private func subtitle(_ now: NowPlaying) -> String {
        now.ad || now.isEmpty ? "" : now.artist
    }

}

/// Redraws on every clock tick, so it is its own small view.
private struct Scrubber: View {
    let model: AppModel
    @ObservedObject var clock: PlaybackClock
    let duration: Double
    let enabled: Bool

    var body: some View {
        HStack(spacing: 8) {
            Text(Self.stamp(clock.time)).frame(width: 34, alignment: .trailing)
            Slider(value: Binding(
                get: { min(clock.time, max(duration, 1)) },
                set: { if clock.scrubbing { clock.time = $0 } }),
                   in: 0...max(duration, 1)) { editing in
                // Seek only at the end of a real drag, never from a programmatic change.
                let wasScrubbing = clock.scrubbing
                clock.scrubbing = editing
                if wasScrubbing && !editing { model.seek(to: clock.time) }
            }
            .controlSize(.mini)
            .disabled(!enabled)
            Text(Self.stamp(duration)).frame(width: 34, alignment: .leading)
        }
        .font(.system(size: 10).monospacedDigit()).foregroundStyle(.secondary)
    }

    private static func stamp(_ t: Double) -> String {
        guard t.isFinite, t >= 0 else { return "0:00" }
        return String(format: "%d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

private struct VolumeSlider: View {
    let model: AppModel
    @ObservedObject var volume: VolumeState

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: volume.level < 1 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                  variableValue: volume.level / 100)
                .font(.system(size: 11)).foregroundStyle(.secondary).frame(width: 16)
            Slider(value: Binding(get: { volume.level }, set: { model.setVolume($0) }), in: 0...100)
                .controlSize(.mini).frame(width: 84)
        }
    }
}

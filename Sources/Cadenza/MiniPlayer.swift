import AppKit
import SwiftUI

/// Shared transport buttons for the compact players.
private struct Transport: View {
    @ObservedObject var model: AppModel
    var size: CGFloat = 15

    var body: some View {
        HStack(spacing: size * 1.1) {
            Button { model.previous() } label: { Image(systemName: "backward.fill") }
            Button { model.playPause() } label: {
                Image(systemName: model.now.playing ? "pause.fill" : "play.fill")
                    .font(.system(size: size * 1.45)).frame(width: size * 1.7)
                    .contentTransition(.symbolEffect(.replace))
            }
            Button { model.next() } label: { Image(systemName: "forward.fill") }
        }
        .font(.system(size: size))
        .buttonStyle(PressableStyle(scale: 0.88))
        .foregroundStyle(.primary)
        .opacity(model.now.isEmpty ? 0.35 : 1)
        .disabled(model.now.isEmpty)
    }
}

private struct TrackText: View {
    let now: NowPlaying
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            Text(now.ad ? "Advertisement" : (now.isEmpty ? "Not Playing" : now.title))
                .font(.system(size: 13, weight: .semibold)).lineLimit(1)
            Text(now.ad || now.isEmpty ? " " : now.artist)
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        }
    }
}

/// The MiniPlayer window. Its layout follows its size: a slim strip, a strip with a scrubber,
/// or large artwork with the controls underneath.
struct MiniPlayerView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GeometryReader { geo in
            let now = model.now
            let size = geo.size
            Group {
                if size.height >= 300 {
                    // Large: artwork on top.
                    let art = max(80, min(size.width - 32, size.height - 168))
                    VStack(spacing: 10) {
                        Artwork(url: now.artURL, size: art, corner: 10)
                            .shadow(color: .black.opacity(0.3), radius: 12, y: 5)
                            .padding(.top, 34)
                        Spacer(minLength: 0)
                        HStack {
                            TrackText(now: now)
                            Spacer(minLength: 8)
                            expandButton
                        }
                        Scrubber(model: model, clock: model.clock, duration: now.duration,
                                 enabled: !(now.isEmpty || now.ad))
                        Transport(model: model, size: 17).padding(.bottom, 14)
                    }
                    .padding(.horizontal, 16)
                } else {
                    // Strip: artwork beside the controls; the scrubber appears when there is room.
                    VStack(spacing: 6) {
                        HStack(spacing: 10) {
                            Artwork(url: now.artURL, size: 48, corner: 6)
                            TrackText(now: now)
                            Spacer(minLength: 6)
                            Transport(model: model, size: 13)
                            expandButton
                        }
                        if size.height >= 118 {
                            Scrubber(model: model, clock: model.clock, duration: now.duration,
                                     enabled: !(now.isEmpty || now.ad))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 26) // title bar
                    .frame(maxHeight: .infinity)
                }
            }
            .frame(width: size.width, height: size.height)
            .animation(.spring(response: 0.3, dampingFraction: 0.9), value: size.height >= 300)
        }
        .background(VisualEffect(material: .hudWindow))
        .tint(Theme.accent)
        .ignoresSafeArea()
    }

    private var expandButton: some View {
        Button { model.showMainWindow?() } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
        }
        .buttonStyle(PressableStyle(scale: 0.88)).font(.system(size: 12))
        .foregroundStyle(.secondary)
        .help("Return to the full window")
    }
}

/// The popover under the menu bar icon.
struct MenuBarPlayerView: View {
    @ObservedObject var model: AppModel
    let quit: () -> Void

    var body: some View {
        let now = model.now
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Artwork(url: now.artURL, size: 64, corner: 8)
                TrackText(now: now)
                Spacer(minLength: 0)
            }
            Scrubber(model: model, clock: model.clock, duration: now.duration,
                     enabled: !(now.isEmpty || now.ad))
            HStack {
                Transport(model: model, size: 16)
                Spacer()
                VolumeSlider(model: model, volume: model.volume)
            }
            Divider()
            HStack {
                Button("Open Cadenza") { model.showMainWindow?() }
                Spacer()
                Button("Quit", action: quit)
            }
            .buttonStyle(.borderless).font(.system(size: 12))
        }
        .padding(14)
        .frame(width: 310)
        .tint(Theme.accent)
    }
}

enum MiniPlayerSize: Int, CaseIterable {
    case small, medium, large

    var title: String { ["Small", "Medium", "Large"][rawValue] }
    var size: NSSize { [NSSize(width: 340, height: 92), NSSize(width: 360, height: 132), NSSize(width: 320, height: 470)][rawValue] }
}

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

/// The MiniPlayer window: the artwork fills the window and the controls sit on top of it.
/// More appears as it grows: transport only, then title and scrubber, then (in a tall window)
/// artwork above a separate control area.
struct MiniPlayerView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let tall = size.height >= 380 && size.height > size.width * 1.25
            Group {
                if tall { tallLayout(size) } else { overlayLayout(size) }
            }
            .frame(width: size.width, height: size.height)
        }
        .environment(\.colorScheme, .dark)
        .tint(Theme.accent)
        .ignoresSafeArea()
    }

    // Artwork edge to edge, controls over a dark gradient.
    private func overlayLayout(_ size: CGSize) -> some View {
        let now = model.now
        let short = min(size.width, size.height)
        let showText = size.height >= 200 && size.width >= 200
        let showScrubber = size.height >= 210 && size.width >= 200
        let controlSize = max(13, min(22, short * 0.085))
        return ZStack {
            FillArtwork(url: now.artURL)
            LinearGradient(
                colors: [.black.opacity(0.0), .black.opacity(0.35), .black.opacity(0.8)],
                startPoint: .top, endPoint: .bottom)
            VStack(spacing: 8) {
                HStack {
                    Spacer()
                    expandButton.padding(8)
                }
                Spacer(minLength: 0)
                if showText {
                    TrackText(now: now, alignment: .center)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 12)
                }
                if showScrubber {
                    Scrubber(model: model, clock: model.clock, duration: now.duration,
                             enabled: !(now.isEmpty || now.ad))
                        .padding(.horizontal, 12)
                }
                Transport(model: model, size: controlSize)
                    .shadow(color: .black.opacity(0.4), radius: 4)
                    .padding(.bottom, max(10, short * 0.07))
            }
            .foregroundStyle(.white)
        }
    }

    // Tall window: square artwork on top, controls below on a blurred backdrop.
    private func tallLayout(_ size: CGSize) -> some View {
        let now = model.now
        let art = max(120, min(size.width - 32, size.height - 170))
        return ZStack {
            FillArtwork(url: now.artURL).blur(radius: 40).opacity(0.55)
            Color.black.opacity(0.45)
            VStack(spacing: 10) {
                ZStack(alignment: .topTrailing) {
                    Artwork(url: now.artURL, size: art, corner: 10)
                        .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
                    expandButton.padding(8)
                }
                .padding(.top, 16)
                Spacer(minLength: 0)
                TrackText(now: now).frame(maxWidth: .infinity, alignment: .leading)
                Scrubber(model: model, clock: model.clock, duration: now.duration,
                         enabled: !(now.isEmpty || now.ad))
                Transport(model: model, size: 17).padding(.bottom, 14)
            }
            .padding(.horizontal, 16)
            .foregroundStyle(.white)
        }
    }

    private var expandButton: some View {
        Button { model.showMainWindow?() } label: {
            Image(systemName: "arrow.up.left.and.arrow.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 24, height: 24)
                .background(.black.opacity(0.35), in: Circle())
        }
        .buttonStyle(PressableStyle(scale: 0.88))
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
    var size: NSSize {
        [NSSize(width: 180, height: 180), NSSize(width: 280, height: 280), NSSize(width: 320, height: 470)][rawValue]
    }
}

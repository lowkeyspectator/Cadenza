import AppKit
import ImageIO
import SwiftUI

/// Loads artwork once, decodes it off the main thread at the size it will be drawn, and keeps
/// the decoded bitmaps in memory so scrolling never waits on the network or a decoder.
final class ImageStore: @unchecked Sendable {
    static let shared = ImageStore()

    private let memory = NSCache<NSString, CGImage>()
    private let session: URLSession

    private init() {
        memory.countLimit = 600
        let config = URLSessionConfiguration.default
        config.urlCache = URLCache(memoryCapacity: 16 << 20, diskCapacity: 256 << 20)
        config.requestCachePolicy = .returnCacheDataElseLoad // artwork URLs are immutable
        config.httpMaximumConnectionsPerHost = 8
        session = URLSession(configuration: config)
    }

    private func key(_ url: URL, _ pixels: Int) -> NSString { "\(pixels)|\(url.absoluteString)" as NSString }

    func cached(_ url: URL, pixels: Int) -> CGImage? { memory.object(forKey: key(url, pixels)) }

    func load(_ url: URL, pixels: Int) async -> CGImage? {
        if let hit = cached(url, pixels: pixels) { return hit }
        guard let (data, _) = try? await session.data(from: url), !Task.isCancelled else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true, // decode here, not on first draw
            kCGImageSourceThumbnailMaxPixelSize: pixels,
        ]
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        memory.setObject(image, forKey: key(url, pixels))
        return image
    }
}

/// A layer that shows one remote image, fading it in the first time it arrives.
final class RemoteImageView: NSView {
    private var url: URL?
    private var task: Task<Void, Never>?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.contentsGravity = .resizeAspectFill
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show(_ newURL: URL?, pixels: Int) {
        guard newURL != url else { return }
        url = newURL
        task?.cancel()
        guard let newURL else { layer?.contents = nil; return }
        if let hit = ImageStore.shared.cached(newURL, pixels: pixels) {
            layer?.contents = hit
            return
        }
        layer?.contents = nil
        task = Task { [weak self] in
            let image = await ImageStore.shared.load(newURL, pixels: pixels)
            guard !Task.isCancelled, let self, self.url == newURL, let image else { return }
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.18
            self.layer?.add(fade, forKey: "contents")
            self.layer?.contents = image
        }
    }
}

struct RemoteImage: NSViewRepresentable {
    let url: URL?
    let pixels: Int

    func makeNSView(context: Context) -> RemoteImageView { RemoteImageView() }
    func updateNSView(_ view: RemoteImageView, context: Context) { view.show(url, pixels: pixels) }
}

struct Artwork: View {
    let url: URL?
    let size: CGFloat
    var round = false
    var corner: CGFloat = 8

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: round ? size / 2 : corner, style: .continuous)
        ZStack {
            Color.primary.opacity(0.08)
            Image(systemName: round ? "music.mic" : "music.note")
                .font(.system(size: size * 0.3)).foregroundStyle(.tertiary)
            RemoteImage(url: url, pixels: Int(size * 2)) // 2× for Retina
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
    }
}

/// Artwork that fills whatever space it is given, cropping to fit.
struct FillArtwork: View {
    let url: URL?

    var body: some View {
        ZStack {
            Color(white: 0.16)
            Image(systemName: "music.note").font(.system(size: 34)).foregroundStyle(.white.opacity(0.3))
            RemoteImage(url: url, pixels: 900)
        }
    }
}

/// Tracks pointer hover for its content. (A plain `State` value: the `@State` macro form needs
/// Xcode's compiler plugin, which the Command Line Tools alone do not ship.)
struct Hover<Content: View>: View {
    private let hovering = State(initialValue: false)
    private let content: (Bool) -> Content

    init(@ViewBuilder _ content: @escaping (Bool) -> Content) { self.content = content }

    var body: some View {
        content(hovering.wrappedValue).onHover { hovering.wrappedValue = $0 }
    }
}

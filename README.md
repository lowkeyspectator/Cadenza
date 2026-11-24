# Cadenza

A small native macOS app for YouTube Music. It wraps the official web player (`music.youtube.com`) in a
WebKit window, so you sign in with your own Google account and your YouTube Music / Premium subscription
applies exactly as it does in a browser.

Unofficial. Not affiliated with Google or YouTube. It does not download, rip, or re-encode streams, and
it does not block ads — playback is the stock web player.

## Features

- **Song / Video switch** in the toolbar (and `⌘1` / `⌘2`). It drives YouTube Music's own switch, so it is
  enabled only where YouTube Music offers it: signed in with Premium, on tracks that have both a song and a
  music-video version.
- **Highest video quality**: video playback is pinned to the best resolution the stream offers (up to 4K)
  instead of the player's "auto". The current resolution is shown in the title bar. Toggle under
  *Playback ▸ Always Use Highest Video Quality*.
- Stays signed in between launches.
- Media keys and the macOS Now Playing widget work (via the web player's media session).
- Playback menu: Play/Pause `⌘P`, Next `⌘→`, Previous `⌘←`.
- Keeps playing when the window is closed; click the Dock icon to bring it back.
- External links open in your default browser.

### Audio quality

Audio bitrate is controlled by your account, not by this app. For the best audio (256 kbps AAC, Premium
only), set it once in YouTube Music: **profile picture ▸ Settings ▸ Playback ▸ Audio quality ▸ High**.

## Build

Requires macOS 13+ and the Swift toolchain (Xcode or just the Command Line Tools).

```bash
./Scripts/build-app.sh
```

```bash
open build/Cadenza.app
```

The app is ad-hoc signed for local use. Copy `build/Cadenza.app` to `/Applications` if you want to keep it.

## Layout

| Path | What |
| --- | --- |
| `Sources/Cadenza/PlayerWindowController.swift` | Window, toolbar, web view, navigation rules |
| `Sources/Cadenza/BridgeScript.swift` | JavaScript injected into the page (mode switch, quality pinning) |
| `Sources/Cadenza/AppDelegate.swift` | Menus and actions |
| `Scripts/build-app.sh` | Builds and bundles `Cadenza.app` |

The bridge relies on YouTube Music's page structure (`ytmusic-av-toggle`, the `movie_player` API). If
Google changes those, the Song/Video switch or quality pinning may stop working until the selectors are
updated; plain playback is unaffected.

## License

MIT

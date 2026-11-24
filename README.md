# Cadenza

A native macOS app for YouTube Music. The interface is SwiftUI: a sidebar with your library and
playlists, artwork-led album and playlist pages, search, a player bar and a synced lyrics panel. The
official YouTube Music web player runs hidden underneath as the audio engine, so you sign in with your own
Google account and your YouTube Music / Premium subscription applies exactly as it does in a browser.

Unofficial. Not affiliated with Google, YouTube or Apple. It does not download, rip, or re-encode streams,
and it does not block ads.

## Features

- **Native interface.** Home, Explore, Search, Liked Songs, Playlists, Albums and Artists, plus your own
  playlists in the sidebar. Click an album, playlist or artist to open it; click a song to play it. Album
  and playlist pages have Play and Shuffle. Follows the system light or dark appearance.
- **Player bar** with transport controls, scrubber, volume, and a badge showing the audio stream actually
  playing (for example "Opus 160 kbps").
- **Audio only.** On by default (*Playback ▸ Audio Only (No Video)*). With Premium, tracks are switched to
  their song version using YouTube Music's own Song/Video switch. Where YouTube Music only offers a video
  stream (no Premium, or a video-only upload), the picture is hidden behind the cover art and fetched at
  240p to save bandwidth. 240p is deliberate: at 144p the player also lowers the audio bitrate.
- **Synced lyrics panel** (`⌘L` or the button in the player bar). The current line is highlighted and kept centred;
  click any line to jump to that point in the song. Lyrics come from [LRCLIB](https://lrclib.net), a free
  community database; the app sends it only the track title, artist, album and length. Songs without
  time-synced lyrics show plain text, which cannot be used to seek.
- Stays signed in between launches. **Sign In** in the sidebar opens Google's sign-in page.
- **Web player** (globe button, or `⇧⌘W`): shows the real YouTube Music page for anything the native
  interface does not cover, such as account and playback settings.
- Media keys and the macOS Now Playing widget work (via the web player's media session).
- Playback menu: Play/Pause `⌘P`, Next `⌘→`, Previous `⌘←`.
- Keeps playing when the window is closed; click the Dock icon to bring it back.

### Audio quality

The app never lowers audio quality, but the ceiling is set by your account, not by the app. Signed out or
on a free account the web player serves about 160 kbps Opus. For the top tier (256 kbps, Premium only), set
it once in the web player (globe button): **profile picture ▸ Settings ▸ Playback ▸ Audio quality ▸
High**. The badge in the player bar shows the result.

### Signing in, and why passkeys do not work

Sign in with your Google password plus whatever second step your account uses (phone prompt, code).
**Passkeys and Touch ID are not available inside the app.** macOS only lets an embedded web view use
passkeys if the app is a registered web browser (an entitlement Apple grants to browser vendors) or is
listed by the website itself as one of its own apps. Neither is possible for an unofficial client, and
a locally built, ad-hoc signed app cannot carry the entitlement at all.

Left alone, Google would still pick the passkey step and fail with "Something went wrong… Make sure
Bluetooth is on". To avoid that, the app hides the passkey API from Google's sign-in pages so Google offers
your other sign-in methods instead. If a passkey prompt still appears, choose **Try another way**.

## Build

Requires macOS 13+ and the Swift toolchain (Xcode or just the Command Line Tools).

```bash
./Scripts/build-app.sh
```

```bash
open build/Cadenza.app
```

The app is ad-hoc signed for local use. Copy `build/Cadenza.app` to `/Applications` if you want to keep it.

## Limits

- Pages show the first batch of results YouTube Music returns; very long playlists and feeds are not
  paged in yet.
- No queue view, like button, or playlist editing yet. Use the web player for those.
- On a free account, ads play in the hidden web player. The player bar shows "Advertisement" until the
  ad ends.

## Layout

| Path | What |
| --- | --- |
| `Sources/Cadenza/Views.swift` | SwiftUI interface: sidebar, pages, player bar |
| `Sources/Cadenza/AppModel.swift` | App state, navigation, data models |
| `Sources/Cadenza/Lyrics.swift` | LRCLIB client, LRC parser, lyrics panel |
| `Sources/Cadenza/BridgeScript.swift` | JavaScript injected into the web player: data requests, playback, audio only |
| `Sources/Cadenza/PlayerWindowController.swift` | Window, hidden web player, sign-in handling |
| `Sources/Cadenza/AppDelegate.swift` | Menus and actions |
| `Scripts/build-app.sh` | Builds and bundles `Cadenza.app` |

The bridge relies on YouTube Music's page structure and its internal JSON API, neither of which is a
public interface. If Google changes them, pages may come back empty or playback controls may stop working
until the bridge is updated. The web player remains available as a fallback.

## License

MIT

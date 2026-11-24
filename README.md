# Cadenza

A small native macOS app for YouTube Music. It wraps the official web player (`music.youtube.com`) in a
WebKit window, so you sign in with your own Google account and your YouTube Music / Premium subscription
applies exactly as it does in a browser.

Unofficial. Not affiliated with Google or YouTube. It does not download, rip, or re-encode streams, and
it does not block ads — playback is the stock web player.

## Features

- **Audio only.** On by default (*Playback ▸ Audio Only (No Video)*). With Premium, tracks are switched to
  their song version using YouTube Music's own Song/Video switch. Where YouTube Music only offers a video
  stream (no Premium, or a video-only upload), the picture is hidden behind the cover art and fetched at
  240p to save bandwidth. 240p is deliberate: at 144p the player also lowers the audio bitrate.
- **Audio format in the title bar**, read from the player (for example "Opus 160 kbps" or "AAC 256 kbps"),
  so you can see what you are actually getting.
- **Synced lyrics panel** (`⌘L` or the toolbar button). The current line is highlighted and kept centred;
  click any line to jump to that point in the song. Lyrics come from [LRCLIB](https://lrclib.net), a free
  community database; the app sends it only the track title, artist, album and length. Songs without
  time-synced lyrics show plain text, which cannot be used to seek.
- Stays signed in between launches. *Cadenza ▸ Sign In to YouTube Music…* opens Google's sign-in page.
- Media keys and the macOS Now Playing widget work (via the web player's media session).
- Playback menu: Play/Pause `⌘P`, Next `⌘→`, Previous `⌘←`.
- Keeps playing when the window is closed; click the Dock icon to bring it back.
- External links open in your default browser.

### Audio quality

The app never lowers audio quality, but the ceiling is set by your account, not by the app. Signed out or
on a free account the web player serves about 160 kbps Opus. For the top tier (256 kbps, Premium only), set
it once in YouTube Music: **profile picture ▸ Settings ▸ Playback ▸ Audio quality ▸ High**. The title bar
shows the result.

### Signing in, and why passkeys do not work

Sign in with your Google password plus whatever second step your account uses (phone prompt, code).
**Passkeys and Touch ID are not available inside the app.** macOS only lets an embedded web view use
passkeys if the app is a registered web browser (an entitlement Apple grants to browser vendors) or is
listed by the website itself as one of its own apps. Neither is possible for an unofficial client, and
a locally built, ad-hoc signed app cannot carry the entitlement at all. If Google offers a passkey, choose
**Try another way**.

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
| `Sources/Cadenza/BridgeScript.swift` | JavaScript injected into the page (audio only, track and time reporting, seek) |
| `Sources/Cadenza/Lyrics.swift` | LRCLIB client, LRC parser, lyrics panel |
| `Sources/Cadenza/AppDelegate.swift` | Menus and actions |
| `Scripts/build-app.sh` | Builds and bundles `Cadenza.app` |

The bridge relies on YouTube Music's page structure (`ytmusic-av-toggle`, the `movie_player` API). If
Google changes those, audio-only mode or the lyrics panel may stop working until the selectors are
updated; plain playback is unaffected.

## License

MIT

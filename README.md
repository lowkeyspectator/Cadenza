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
- **MiniPlayer** (`⇧⌘M`, or the button at the right of the player bar). Collapses the app into a small
  floating window that stays above other apps: the artwork fills it and the controls sit on top. The
  expand button on the artwork, or `⇧⌘M` again, brings the full window back. Resize it freely or pick
  Small, Medium or Large under *Window ▸ MiniPlayer Size*: Small is artwork and controls only, larger
  sizes add the title and a scrubber, and a tall window puts the controls below the artwork.
- **Previous/next in Control Center** and the menu bar Now Playing widget, instead of the web player's
  15-second skip buttons.
- **Menu bar player.** A music-note icon in the menu bar opens a popover with the current track, transport
  controls, scrubber and volume. Turn it off under *View ▸ Show Player in Menu Bar*.
- **Dock menu** with Play/Pause, Next and Previous.
- **Resizes down to a small window.** The sidebar and lyrics column fold away as the window narrows, and
  the sidebar can be hidden by hand (`⌃⌘S`).
- **Audio only.** On by default (*Playback ▸ Audio Only (No Video)*). With Premium, tracks are switched to
  their song version using YouTube Music's own Song/Video switch. Where YouTube Music only offers a video
  stream (no Premium, or a video-only upload), the picture is hidden behind the cover art and fetched at
  240p to save bandwidth. 240p is deliberate: at 144p the player also lowers the audio bitrate.
- **Synced lyrics panel** (`⌘L` or the button in the player bar). The current line is highlighted and kept centred;
  click any line to jump to that point in the song. Timed lyrics come from [LRCLIB](https://lrclib.net), a
  free community database; the app sends it only the track title, artist, album and length. Because that
  match is by name only, each candidate is compared with YouTube Music's own lyrics for the track, and a
  translation, romanisation or different song with the same title is rejected. When no timed version
  matches, YouTube Music's plain lyrics are shown instead; those cannot be used to seek.
- Stays signed in between launches. **Sign In** in the sidebar opens Google's sign-in page.
- **Web player** (globe button, or `⇧⌘W`): shows the real YouTube Music page for anything the native
  interface does not cover, such as account and playback settings.
- Media keys and the macOS Now Playing widget work (via the web player's media session).
- Keyboard: `Space` or `⌘P` play/pause, `⌘→` next, `⌘←` previous, `⌘F` search, `⌘[` / `⌘]` back and forward.
- Keeps playing when the window is closed; click the Dock icon to bring it back.

### Audio quality

YouTube Music's best stream is 256 kbps (AAC or Opus). It offers no lossless/FLAC tier and no 320 kbps
tier, so no client can play more than that. The app never lowers audio quality, but the ceiling is set by
the service and your account, not by the app. Signed out or
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

## Install

**Requirements:** macOS 14 Sonoma or later, on Apple Silicon or Intel.

1. Download `Cadenza-<version>.dmg` from the [latest release](https://github.com/lowkeyspectator/Cadenza/releases/latest).
2. Open it and drag **Cadenza** onto the **Applications** shortcut.
3. Open it. The app isn't notarized by Apple, so the first launch is blocked with a message that macOS
   couldn't verify it. To allow it:
   - Open **System Settings → Privacy & Security**, scroll down to the message about Cadenza, click
     **Open Anyway** and confirm. Or
   - run this once in Terminal:
     ```bash
     xattr -dr com.apple.quarantine /Applications/Cadenza.app
     ```

To uninstall, quit Cadenza and delete `/Applications/Cadenza.app`.

## Build

Requires macOS 14+ and the Swift toolchain (Xcode or just the Command Line Tools).

```bash
./Scripts/build-app.sh
```

```bash
open build/Cadenza.app
```

To package a DMG (written to `build/Cadenza-<version>.dmg`):

```bash
./Scripts/make-dmg.sh
```

Both produce a universal (Apple Silicon and Intel) app. It is signed with a Developer ID Application
certificate if one is in your keychain (or the one named in `SIGN_ID`), otherwise ad-hoc for local use.

### Notarized releases

A notarized DMG opens on any Mac without the "Open Anyway" step. One-time setup, with an Apple
Developer Program membership:

1. Create a **Developer ID Application** certificate: Xcode ▸ Settings ▸ Accounts ▸ select the team ▸
   Manage Certificates ▸ **+** ▸ Developer ID Application. Only the team's Account Holder can do this.
2. Save notarization credentials in your keychain (it prompts for an app-specific password from
   [account.apple.com](https://account.apple.com) ▸ Sign-In and Security ▸ App-Specific Passwords):

   ```bash
   xcrun notarytool store-credentials cadenza-notary --apple-id YOUR_APPLE_ID --team-id YOUR_TEAM_ID
   ```

Then each release:

```bash
NOTARY_PROFILE=cadenza-notary ./Scripts/make-dmg.sh
```

This signs the app with the hardened runtime, submits the DMG to Apple, waits for approval, and staples
the ticket to the DMG.

## Limits

- Long playlists and library lists load more as you scroll; the Home and Explore feeds show only their
  first batch of shelves.
- No queue view, like button, or playlist editing yet. Use the web player for those.
- No desktop or Notification Center widget: those need an app extension built with Xcode.
- On a free account, ads play in the hidden web player. The player bar shows "Advertisement" until the
  ad ends.

## Layout

| Path | What |
| --- | --- |
| `Sources/Cadenza/Views.swift` | SwiftUI interface: sidebar, pages, player bar |
| `Sources/Cadenza/AppModel.swift` | App state, navigation, data models |
| `Sources/Cadenza/MiniPlayer.swift` | MiniPlayer and menu bar popover |
| `Sources/Cadenza/Artwork.swift` | Cached artwork loading |
| `Sources/Cadenza/Lyrics.swift` | LRCLIB client, LRC parser, lyrics panel |
| `Sources/Cadenza/BridgeScript.swift` | JavaScript injected into the web player: data requests, playback, audio only |
| `Sources/Cadenza/PlayerWindowController.swift` | Window, hidden web player, sign-in handling |
| `Sources/Cadenza/AppDelegate.swift` | Menus and actions |
| `Scripts/build-app.sh` | Builds and bundles a universal `Cadenza.app` |
| `Scripts/make-dmg.sh` | Packages the app as a DMG for releases |

The bridge relies on YouTube Music's page structure and its internal JSON API, neither of which is a
public interface. If Google changes them, pages may come back empty or playback controls may stop working
until the bridge is updated. The web player remains available as a fallback.

## License

MIT

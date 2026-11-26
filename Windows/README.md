# Cadenza for Windows (preview)

The Windows version of Cadenza: a native WPF interface (Windows 11 Fluent theme) over the official
YouTube Music web player, which runs hidden in Microsoft Edge WebView2 as the audio engine. It uses
the same JavaScript bridge as the macOS app, read straight out of `Sources/Cadenza/BridgeScript.swift`,
so a fix to the bridge fixes both.

Unofficial. Not affiliated with Google or YouTube.

## Status

Preview, version 0.1.0. Built and tested automatically on Windows by
[`.github/workflows/windows.yml`](../.github/workflows/windows.yml), which launches the app against
the real YouTube Music, loads Home, Explore and a search, starts two songs in quick succession and
installs the MSIX package.

Not yet tested on a real Windows PC:

- **Playback and sign-in.** YouTube asks the CI runner's datacenter address to "confirm you're not a
  bot", so audio cannot be checked there. On a home connection, signed in, this does not normally
  appear.
- **Media keys and the Windows media overlay.** Requested from WebView2, but unconfirmed.
- **Passkeys.** WebView2 supports Windows Hello, so unlike on the Mac they are left enabled.

## Features

Home, Explore, Liked Songs, Playlists, Albums, Artists and your own playlists; search; album,
playlist and artist pages with Play and Shuffle; player bar with scrubber, volume and the audio
format badge; synced lyrics with click-to-seek (LRCLIB, matched against YouTube Music's own
lyrics, as on the Mac); audio only; the web player for sign-in and account settings.

Keyboard: `Space` or `Ctrl+P` play/pause, `Ctrl+→`/`Ctrl+←` next/previous, `Ctrl+↑`/`Ctrl+↓`
volume (or scroll over the volume slider), `Ctrl+L` lyrics, `Ctrl+F` search, `Alt+←`/`Alt+→`
back/forward, `F5` reload.

## Requirements

Windows 10 1809 or later (x64) with the
[WebView2 Runtime](https://go.microsoft.com/fwlink/p/?LinkId=2124703), which Windows 11 and
Microsoft Edge already include. The app is self-contained: no .NET install is needed.

## Build

```bash
dotnet publish Windows/Cadenza.Windows.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o out
```

Needs the .NET 9 SDK. It compiles on Windows; the CI workflow does this on every push.

## Microsoft Store

The workflow also produces `Cadenza-<version>-x64.msix`. To publish it:

1. Create a developer account in [Partner Center](https://partner.microsoft.com/dashboard) and
   reserve the app name.
2. Copy the three identity values from *Product management ▸ Product identity* into repository
   variables `MSIX_IDENTITY_NAME`, `MSIX_PUBLISHER` and `MSIX_PUBLISHER_DISPLAY_NAME`
   (Settings ▸ Secrets and variables ▸ Actions ▸ Variables), then rerun the workflow.
3. Upload the MSIX in a new submission. The Store signs it, so no code-signing certificate is
   needed for Store distribution.

Store review may reject or later remove an unofficial client of another company's service. Keep
"YouTube" out of the app name, icon and screenshots, and say plainly in the listing that the app is
unofficial and requires the user's own account.

// JavaScript injected into music.youtube.com (page world).
let bridgeScript = #"""
// Injected into music.youtube.com. Bridges the web player to the native shell:
//  - reports the Song/Video switch state and the current track
//  - lets the native toolbar flip the Song/Video switch
//  - keeps video playback pinned to the highest quality the stream offers
(function () {
  if (window.__cadenza) return;

  const post = (msg) => {
    try { window.webkit.messageHandlers.cadenza.postMessage(msg); } catch (e) {}
  };
  const player = () => document.getElementById('movie_player');
  const avToggle = () => document.querySelector('ytmusic-av-toggle');
  const click = (sel) => {
    const el = document.querySelector(sel);
    if (el) el.click();
    return !!el;
  };

  const api = (window.__cadenza = {
    maxQuality: true,

    // 'audio' | 'video' | 'none' (no track loaded, or the track has no switch)
    mode() {
      const t = avToggle();
      if (!t) return 'none';
      return (t.getAttribute('playback-mode') || '').startsWith('OMV') ? 'video' : 'audio';
    },

    // The switch is locked for tracks that exist only as a song or only as a video.
    canSwitch() {
      const t = avToggle();
      return !!t && !t.hasAttribute('toggle-disabled');
    },

    setMode(mode) {
      const t = avToggle();
      if (!t) return false;
      const btn = t.querySelector(mode === 'video' ? '.video-button' : '.song-button');
      if (!btn) return false;
      btn.click();
      return true;
    },

    playPause: () => click('#play-pause-button'),
    next: () => click('.next-button'),
    previous: () => click('.previous-button'),

    setMaxQuality(on) {
      api.maxQuality = !!on;
      lastPinned = null;
      if (!on) {
        const p = player();
        if (p && p.setPlaybackQualityRange) p.setPlaybackQualityRange('auto', 'auto');
      }
    },
  });

  // --- Highest video quality -------------------------------------------------
  let lastPinned = null;
  function pinQuality() {
    if (!api.maxQuality) return;
    const p = player();
    if (!p || !p.getAvailableQualityLevels || !p.setPlaybackQualityRange) return;
    const levels = p.getAvailableQualityLevels().filter((q) => q !== 'auto');
    if (!levels.length) return; // audio-only stream or nothing loaded yet
    const top = levels[0]; // the player lists levels best-first
    const id = (p.getVideoData && p.getVideoData().video_id) || '';
    const key = id + ':' + top;
    if (lastPinned === key && p.getPlaybackQuality() === top) return;
    p.setPlaybackQualityRange(top, top);
    lastPinned = key;
  }

  // --- State reporting -------------------------------------------------------
  let lastState = '';
  function report() {
    const md = navigator.mediaSession && navigator.mediaSession.metadata;
    const p = player();
    const state = {
      mode: api.mode(),
      canSwitch: api.canSwitch(),
      title: md ? md.title || '' : '',
      artist: md ? md.artist || '' : '',
      quality: p && p.getPlaybackQualityLabel ? p.getPlaybackQualityLabel() || '' : '',
    };
    const s = JSON.stringify(state);
    if (s !== lastState) {
      lastState = s;
      post(state);
    }
  }

  setInterval(() => {
    try { pinQuality(); report(); } catch (e) {}
  }, 1000);
})();
"""#

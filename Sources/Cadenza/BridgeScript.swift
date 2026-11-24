// JavaScript injected into music.youtube.com (page world).
let bridgeScript = #"""
// Bridges the web player to the native shell:
//  - keeps playback on the audio ("Song") version and hides video
//  - reports the current track, audio format and playback position
//  - lets the native lyrics panel seek
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

  const style = document.createElement('style');
  style.textContent = `
    html.cadenza-audio-only ytmusic-av-toggle { display: none !important; }
    html.cadenza-audio-only #movie_player video { opacity: 0 !important; }
    html.cadenza-audio-only #movie_player {
      background: #000 var(--cadenza-art, none) center / contain no-repeat !important;
    }`;
  (document.head || document.documentElement).appendChild(style);

  const api = (window.__cadenza = {
    audioOnly: true,

    setAudioOnly(on) {
      api.audioOnly = !!on;
      lastSwitch = '';
      if (!on) {
        const p = player();
        if (p && p.setPlaybackQualityRange) p.setPlaybackQualityRange('auto', 'auto');
      }
      enforceAudio();
    },

    playPause: () => click('#play-pause-button'),
    next: () => click('.next-button'),
    previous: () => click('.previous-button'),

    seek(seconds) {
      const p = player();
      if (p && p.seekTo) p.seekTo(seconds, true);
    },
  });

  const isAd = (p) => p.classList.contains('ad-showing') || p.classList.contains('ad-interrupting');
  const videoId = (p) => (p.getVideoData && p.getVideoData().video_id) || '';

  // --- Audio only ------------------------------------------------------------
  let lastSwitch = '';
  function enforceAudio() {
    document.documentElement.classList.toggle('cadenza-audio-only', api.audioOnly);
    if (!api.audioOnly) return;
    const p = player();
    if (!p) return;
    const id = videoId(p);

    // Preferred: YouTube Music's own Song/Video switch (Premium, tracks that have both).
    const t = avToggle();
    const onVideo = t && (t.getAttribute('playback-mode') || '').startsWith('OMV');
    if (onVideo && !t.hasAttribute('toggle-disabled') && lastSwitch !== id) {
      const btn = t.querySelector('.song-button');
      if (btn) { lastSwitch = id; btn.click(); return; }
    }

    // Otherwise the stream carries video: fetch a small picture and show cover art instead.
    // Not the very smallest: at 144p ("tiny") the player also drops to a lower audio bitrate,
    // while 240p and up keep the best audio stream.
    if (p.getAvailableQualityLevels && p.setPlaybackQualityRange) {
      const levels = p.getAvailableQualityLevels().filter((q) => q !== 'auto');
      if (levels.length) {
        const usable = levels.filter((q) => q !== 'tiny');
        const low = usable.length ? usable[usable.length - 1] : levels[0];
        if (p.getPlaybackQuality() !== low) p.setPlaybackQualityRange(low, low);
        if (id) {
          document.documentElement.style.setProperty(
            '--cadenza-art', `url(https://i.ytimg.com/vi/${id}/hqdefault.jpg)`);
        }
      }
    }
  }

  // --- State reporting -------------------------------------------------------
  let lastTrack = '';
  function reportTrack() {
    const p = player();
    if (!p || !p.getVideoData) return;
    const md = navigator.mediaSession && navigator.mediaSession.metadata;
    const stats = p.getVideoStats ? p.getVideoStats() || {} : {};
    const levels = p.getAvailableQualityLevels ? p.getAvailableQualityLevels() : [];
    const track = {
      type: 'track',
      ad: isAd(p),
      id: videoId(p),
      title: md ? md.title || '' : '',
      artist: md ? md.artist || '' : '',
      album: md ? md.album || '' : '',
      duration: p.getDuration ? p.getDuration() || 0 : 0,
      afmt: String(stats.afmt || ''),
      hasVideo: levels.some((q) => q !== 'auto'),
    };
    const s = JSON.stringify(track);
    if (s !== lastTrack) { lastTrack = s; post(track); }
  }

  let lastTime = -1;
  function reportTime() {
    const p = player();
    if (!p || !p.getCurrentTime || isAd(p)) return;
    const t = p.getCurrentTime();
    if (Math.abs(t - lastTime) < 0.05) return;
    lastTime = t;
    post({ type: 'time', id: videoId(p), t });
  }

  setInterval(() => { try { enforceAudio(); reportTrack(); } catch (e) {} }, 1000);
  setInterval(() => { try { reportTime(); } catch (e) {} }, 250);
})();
"""#

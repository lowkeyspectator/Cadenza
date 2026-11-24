// JavaScript injected into music.youtube.com (page world).
let bridgeScript = #"""
// Bridges the web player to the native shell:
//  - keeps playback on the audio ("Song") version and hides video
//  - fetches browse/search data for the native interface
//  - starts playback and reports the current track, audio format and position
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

  // --- Data: YouTube Music's own JSON API, called as the signed-in page would ---------------
  async function authHeader() {
    const m = document.cookie.match(/(?:^|;\s*)(?:SAPISID|__Secure-3PAPISID)=([^;]+)/);
    if (!m) return null;
    const ts = Math.floor(Date.now() / 1000);
    const data = new TextEncoder().encode(`${ts} ${m[1]} ${location.origin}`);
    const digest = await crypto.subtle.digest('SHA-1', data);
    const hex = [...new Uint8Array(digest)].map((b) => b.toString(16).padStart(2, '0')).join('');
    return `SAPISIDHASH ${ts}_${hex}`;
  }

  async function yt(endpoint, body) {
    const cfg = window.ytcfg;
    const headers = {
      'Content-Type': 'application/json',
      'X-Origin': location.origin,
      'X-Goog-AuthUser': String(cfg.get('SESSION_INDEX') || 0),
    };
    if (cfg.get('VISITOR_DATA')) headers['X-Goog-Visitor-Id'] = cfg.get('VISITOR_DATA');
    if (cfg.get('DELEGATED_SESSION_ID')) headers['X-Goog-PageId'] = cfg.get('DELEGATED_SESSION_ID');
    const auth = await authHeader();
    if (auth) headers.Authorization = auth;
    const r = await fetch(`/youtubei/v1/${endpoint}?prettyPrint=false`, {
      method: 'POST', credentials: 'include', headers,
      body: JSON.stringify({ context: cfg.get('INNERTUBE_CONTEXT'), ...body }),
    });
    if (!r.ok) throw new Error('YouTube Music returned ' + r.status);
    return r.json();
  }

  const text = (t) => (!t ? '' : t.simpleText || (t.runs || []).map((r) => r.text).join(''));

  function find(o, key, depth) {
    depth = depth || 0;
    if (!o || typeof o !== 'object' || depth > 14) return undefined;
    if (!Array.isArray(o) && key in o) return o[key];
    for (const v of Array.isArray(o) ? o : Object.values(o)) {
      const hit = find(v, key, depth + 1);
      if (hit !== undefined) return hit;
    }
    return undefined;
  }

  function thumb(o) {
    const list = find(o, 'thumbnails');
    if (!list || !list.length) return '';
    let url = list[list.length - 1].url || '';
    if (url.startsWith('//')) url = 'https:' + url;
    return url.replace(/=w(\d+)-h(\d+)/, (_, w, h) => `=w480-h${Math.round((480 * h) / w)}`);
  }

  const KINDS = {
    MUSIC_PAGE_TYPE_ALBUM: 'album', MUSIC_PAGE_TYPE_AUDIOBOOK: 'album',
    MUSIC_PAGE_TYPE_PLAYLIST: 'playlist', MUSIC_PAGE_TYPE_ARTIST: 'artist',
    MUSIC_PAGE_TYPE_USER_CHANNEL: 'artist', MUSIC_PAGE_TYPE_LIBRARY_ARTIST: 'artist',
    MUSIC_PAGE_TYPE_PODCAST_SHOW_DETAIL_PAGE: 'playlist',
  };
  const kindOf = (browse) => {
    const type = find(browse, 'pageType');
    return KINDS[type] || 'other';
  };

  function card(r) {
    const nav = r.navigationEndpoint || {};
    const watch = nav.watchEndpoint;
    const browse = nav.browseEndpoint;
    const playAll = find(r.thumbnailOverlay, 'watchPlaylistEndpoint');
    return {
      title: text(r.title), subtitle: text(r.subtitle), thumb: thumb(r.thumbnailRenderer),
      kind: watch ? 'song' : browse ? kindOf(browse) : 'other',
      videoId: watch ? watch.videoId : null,
      playlistId: watch ? watch.playlistId || null : playAll ? playAll.playlistId : null,
      browseId: browse ? browse.browseId : null, duration: null,
    };
  }

  function row(r) {
    const cols = (r.flexColumns || [])
      .map((c) => text(c.musicResponsiveListItemFlexColumnRenderer && c.musicResponsiveListItemFlexColumnRenderer.text))
      .filter(Boolean);
    const watch = find(r.overlay, 'watchEndpoint') || find(r.flexColumns, 'watchEndpoint');
    const browse = r.navigationEndpoint && r.navigationEndpoint.browseEndpoint;
    const videoId = (r.playlistItemData && r.playlistItemData.videoId) || (watch && watch.videoId) || null;
    return {
      title: cols[0] || '', subtitle: cols.slice(1).join(' · '), thumb: thumb(r.thumbnail),
      kind: videoId ? 'song' : browse ? kindOf(browse) : 'other',
      videoId, playlistId: watch ? watch.playlistId || null : null,
      browseId: !videoId && browse ? browse.browseId : null,
      duration: text(find(r.fixedColumns, 'text')) || null,
    };
  }

  const entry = (c) =>
    c.musicTwoRowItemRenderer ? card(c.musicTwoRowItemRenderer)
    : c.musicResponsiveListItemRenderer ? row(c.musicResponsiveListItemRenderer)
    : null;

  const SHELVES = ['musicCarouselShelfRenderer', 'musicShelfRenderer', 'musicPlaylistShelfRenderer',
    'gridRenderer', 'musicCardShelfRenderer'];
  const HEADERS = ['musicResponsiveHeaderRenderer', 'musicImmersiveHeaderRenderer',
    'musicDetailHeaderRenderer', 'musicVisualHeaderRenderer'];

  function shelf(kind, v) {
    const raw = v.contents || v.items || [];
    const items = raw.map(entry).filter((i) => i && i.title);
    let title = text(v.title) || text(find(v.header, 'title'));
    let style = kind === 'gridRenderer' ? 'grid' : 'list';
    if (kind === 'musicCarouselShelfRenderer') {
      style = raw.length && raw[0].musicResponsiveListItemRenderer ? 'list' : 'carousel';
    }
    if (kind === 'musicCardShelfRenderer') {
      // Search "top result": the card itself plus a few related rows.
      const nav = find(v.title, 'navigationEndpoint') || {};
      const watch = nav.watchEndpoint || find(v.buttons, 'watchEndpoint');
      const browse = nav.browseEndpoint;
      items.unshift({
        title: text(v.title), subtitle: text(v.subtitle), thumb: thumb(v.thumbnail),
        kind: browse ? kindOf(browse) : 'song',
        videoId: !browse && watch ? watch.videoId : null,
        playlistId: !browse && watch ? watch.playlistId || null : null,
        browseId: browse ? browse.browseId : null, duration: null,
      });
      title = 'Top Result';
    }
    return { title, style, items };
  }

  function header(v) {
    const play = find(v, 'watchPlaylistEndpoint') || find(v, 'watchEndpoint') || {};
    return {
      title: text(v.title),
      subtitle: text(v.straplineTextOne) || text(v.subtitle),
      second: text(v.straplineTextOne) ? text(v.subtitle) : text(v.secondSubtitle),
      thumb: thumb(v.thumbnail || v.foregroundThumbnail || v),
      playlistId: play.playlistId || null,
      round: !!v.musicImmersiveHeaderRenderer,
    };
  }

  function walk(o, page) {
    if (!o || typeof o !== 'object') return;
    if (Array.isArray(o)) { o.forEach((x) => walk(x, page)); return; }
    for (const [k, v] of Object.entries(o)) {
      if (SHELVES.includes(k)) {
        page.sections.push(shelf(k, v));
      } else if (HEADERS.includes(k)) {
        if (!page.header) { page.header = header(v); page.header.round = k === 'musicImmersiveHeaderRenderer'; }
      } else if (k === 'itemSectionRenderer') {
        // Search results arrive as a flat run of single rows.
        const rows = (v.contents || []).map(entry).filter((i) => i && i.title);
        if (!rows.length) { walk(v, page); continue; }
        let last = page.sections[page.sections.length - 1];
        if (!last || !last.results) {
          last = { title: 'Results', style: 'list', items: [], results: true };
          page.sections.push(last);
        }
        last.items.push(...rows);
      } else {
        walk(v, page);
      }
    }
  }

  function normalize(response) {
    const page = { header: null, sections: [] };
    walk(response, page);
    page.sections = page.sections.filter((s) => s.items.length);
    return page;
  }

  api.browse = async (browseId, params) => normalize(await yt('browse', params ? { browseId, params } : { browseId }));
  api.search = async (query) => normalize(await yt('search', { query }));
  api.loggedIn = () => !!(window.ytcfg && window.ytcfg.get('LOGGED_IN'));

  // --- Playback --------------------------------------------------------------
  api.play = function (videoId, playlistId) {
    const endpoint = videoId
      ? { watchEndpoint: playlistId ? { videoId, playlistId } : { videoId } }
      : { watchPlaylistEndpoint: { playlistId } };
    const url = '/watch?' + [videoId && 'v=' + videoId, playlistId && 'list=' + playlistId].filter(Boolean).join('&');
    // In-page navigation keeps the player alive; fall back to a normal page load if it didn't take.
    try { document.querySelector('ytmusic-app').handleNavigationEndpoint(endpoint); } catch (e) {}
    setTimeout(() => {
      const p = player();
      const current = p && p.getVideoData ? p.getVideoData().video_id : '';
      const took = videoId ? current === videoId || location.search.includes(videoId)
                           : location.search.includes(playlistId);
      if (!took) location.href = url;
    }, 2500);
  };

  api.shuffle = () => click('ytmusic-player-bar .shuffle, .shuffle.ytmusic-player-bar');
  api.setVolume = (v) => {
    const p = player();
    if (p && p.setVolume) { p.unMute && p.unMute(); p.setVolume(v); }
  };


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
    const md = navigator.mediaSession && navigator.mediaSession.metadata;
    const stats = p && p.getVideoStats ? p.getVideoStats() || {} : {};
    const art = md && md.artwork && md.artwork.length ? md.artwork[md.artwork.length - 1].src : '';
    const track = {
      type: 'track',
      ready: !!(window.ytcfg && window.ytcfg.get('INNERTUBE_CONTEXT')),
      loggedIn: api.loggedIn(),
      ad: !!p && isAd(p),
      id: p && p.getVideoData ? videoId(p) : '',
      title: md ? md.title || '' : '',
      artist: md ? md.artist || '' : '',
      album: md ? md.album || '' : '',
      art,
      duration: p && p.getDuration ? p.getDuration() || 0 : 0,
      playing: !!p && !!p.getPlayerState && p.getPlayerState() === 1,
      volume: p && p.getVolume ? p.getVolume() : 100,
      afmt: String(stats.afmt || ''),
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

  setInterval(() => { try { enforceAudio(); } catch (e) {} try { reportTrack(); } catch (e) {} }, 500);
  setInterval(() => { try { reportTime(); } catch (e) {} }, 250);
})();
"""#

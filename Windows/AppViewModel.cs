using System.Collections.ObjectModel;
using System.IO;
using System.Text.Json;
using System.Windows.Threading;

namespace Cadenza;

/// <summary>Settings kept between launches.</summary>
public sealed class Settings
{
    public bool AudioOnly { get; set; } = true;
    public bool ShowLyrics { get; set; } = true;
    public bool SidebarHidden { get; set; }

    private static string FilePath => Path.Combine(App.DataFolder, "settings.json");

    public static Settings Load()
    {
        try { return Json.Parse<Settings>(File.ReadAllText(FilePath)) ?? new(); } catch { return new(); }
    }

    public void Save()
    {
        try { File.WriteAllText(FilePath, JsonSerializer.Serialize(this, Json.Options)); } catch { }
    }
}

/// <summary>App state, navigation and playback. The Windows counterpart of AppModel.swift.</summary>
public sealed class AppViewModel : Observable
{
    private readonly Engine engine;
    public Settings Settings { get; } = Settings.Load();

    public LyricsModel Lyrics { get; } = new();
    public NowPlaying Now { get; } = new();
    public ObservableCollection<Item> Playlists { get; } = new();
    public ObservableCollection<NavEntry> Library { get; } = new()
    {
        new("\uE80F", "Home", Route.HomeRoute),
        new("\uE909", "Explore", Route.Browse("FEmusic_explore", "Explore")),
        new("\uEB51", "Liked Songs", Route.Browse("VLLM", "Liked Songs")),
        new("\uE8FD", "Playlists", Route.Browse("FEmusic_liked_playlists", "Playlists")),
        new("\uE93C", "Albums", Route.Browse("FEmusic_liked_albums", "Albums")),
        new("\uE77B", "Artists", Route.Browse("FEmusic_library_corpus_track_artists", "Artists")),
    };

    private readonly Dictionary<Route, PageVM> cache = new();
    private readonly Stack<Route> back = new(), forward = new();
    private int loadVersion;
    private DispatcherTimer? readyTimeout;

    public AppViewModel(Engine engine)
    {
        this.engine = engine;
        engine.Message += OnMessage;
        engine.LoadFailed += PlayerFailed;
        showLyrics = Settings.ShowLyrics;
        Lyrics.SeekRequested = Seek;
        Lyrics.Reference = async id =>
        {
            var json = await engine.FetchAsync($"lyrics({Json.Js(id)})");
            using var doc = JsonDocument.Parse(json);
            var text = doc.RootElement.TryGetProperty("text", out var t) ? t.GetString() : null;
            return string.IsNullOrEmpty(text) ? null : text;
        };

        OpenCommand = new Command(p => { if (p is Route r) Open(r); else if (p is NavEntry n) Open(n.Route); });
        ActivateCommand = new Command(p => { if (p is Item i) Activate(i); });
        PlayItemCommand = new Command(p => { if (p is Item i) Play(i.VideoId, i.PlaylistId); });
        OpenItemCommand = new Command(p => { if (p is Item { BrowseId: { } id } i) Open(Route.Browse(id, i.Title)); });
        CopyLinkCommand = new Command(p => { if (p is Item i && LinkFor(i) is { } link) System.Windows.Clipboard.SetText(link); });
        PlayHeaderCommand = new Command(p => PlayHeader(p as string == "shuffle"));
        LoadMoreCommand = new Command(p => { if (p is SectionVM s) _ = LoadMoreAsync(s); });
        BackCommand = new Command(_ => GoBack(), _ => back.Count > 0);
        ForwardCommand = new Command(_ => GoForward(), _ => forward.Count > 0);
        SearchCommand = new Command(SubmitSearch);
        ReloadCommand = new Command(Reload);
        PlayPauseCommand = new Command(PlayPause);
        NextCommand = new Command(Next);
        PreviousCommand = new Command(Previous);
        ToggleLyricsCommand = new Command(() => ShowLyrics = !ShowLyrics);
        SignInCommand = new Command(SignIn);
        ShowWebCommand = new Command(() => WebMode = true);
        HideWebCommand = new Command(() => WebMode = false);
        RetryLyricsCommand = new Command(Lyrics.Retry);
        SeekLineCommand = new Command(p => { if (p is LyricLine l) Lyrics.Seek(l); });
    }

    public Command OpenCommand { get; }
    public Command ActivateCommand { get; }
    public Command PlayItemCommand { get; }
    public Command OpenItemCommand { get; }
    public Command CopyLinkCommand { get; }
    public Command PlayHeaderCommand { get; }
    public Command LoadMoreCommand { get; }
    public Command BackCommand { get; }
    public Command ForwardCommand { get; }
    public Command SearchCommand { get; }
    public Command ReloadCommand { get; }
    public Command PlayPauseCommand { get; }
    public Command NextCommand { get; }
    public Command PreviousCommand { get; }
    public Command ToggleLyricsCommand { get; }
    public Command SignInCommand { get; }
    public Command ShowWebCommand { get; }
    public Command HideWebCommand { get; }
    public Command RetryLyricsCommand { get; }
    public Command SeekLineCommand { get; }

    // MARK: State

    private Route route = Route.HomeRoute;
    public Route Route { get => route; private set { Set(ref route, value); foreach (var n in Library) n.IsSelected = n.Route == value; } }

    private PageVM? page;
    public PageVM? Page { get => page; private set { Set(ref page, value); Raise(nameof(ShowEmpty)); Raise(nameof(ShowSignInPrompt)); MarkCurrent(); } }

    private bool loading;
    public bool Loading { get => loading; private set => Set(ref loading, value); }

    private string? error;
    public string? Error { get => error; private set { Set(ref error, value); Raise(nameof(HasError)); } }
    public bool HasError => error != null;

    public bool ShowSignInPrompt => page is { IsEmpty: true } && route.NeedsAccount && !loggedIn;
    public bool ShowEmpty => page is { IsEmpty: true } && !ShowSignInPrompt;

    private string searchText = "";
    public string SearchText { get => searchText; set => Set(ref searchText, value); }

    private bool loggedIn;
    public bool LoggedIn { get => loggedIn; private set { Set(ref loggedIn, value); Raise(nameof(ShowSignInPrompt)); Raise(nameof(ShowEmpty)); } }

    private bool ready;
    public bool Ready { get => ready; private set => Set(ref ready, value); }

    private double time;
    public double Time { get => time; private set { if (Set(ref time, value)) TimeChanged?.Invoke(value); } }
    public event Action<double>? TimeChanged;

    private double volume = 100;
    public double Volume { get => volume; private set => Set(ref volume, value); }
    private DateTime volumeSetAt = DateTime.MinValue;

    private bool showLyrics;
    public bool ShowLyrics
    {
        get => showLyrics;
        set
        {
            if (!Set(ref showLyrics, value)) return;
            Settings.ShowLyrics = value; Settings.Save();
            // Lyrics are only looked up while the panel is open; catch up when it opens.
            if (value) Lyrics.SetTrack(currentTrack);
        }
    }

    private bool webMode;
    public bool WebMode
    {
        get => webMode;
        set
        {
            if (!Set(ref webMode, value)) return;
            engine.WebModeOn = value;
            if (!value) { signingIn = false; if (!engine.IsOnPlayer) engine.ReloadPlayer(); }
        }
    }

    public bool AudioOnly
    {
        get => Settings.AudioOnly;
        set { if (Settings.AudioOnly == value) return; Settings.AudioOnly = value; Settings.Save(); Raise(); _ = engine.SetAudioOnlyAsync(value); }
    }

    private Track currentTrack = new();
    private bool signingIn;

    // MARK: Navigation

    public void Start() => Show(route);

    public void Open(Route next)
    {
        if (next == route) { Reload(); return; }
        back.Push(route);
        forward.Clear();
        Show(next);
    }

    public void GoBack() { if (back.Count == 0) return; forward.Push(route); Show(back.Pop()); }
    public void GoForward() { if (forward.Count == 0) return; back.Push(route); Show(forward.Pop()); }

    public void SubmitSearch()
    {
        var q = searchText.Trim();
        if (q.Length > 0) Open(Route.Search(q));
    }

    public void Reload()
    {
        cache.Remove(route);
        // If the player itself never came up (offline at launch), load it again first.
        if (!ready) engine.ReloadPlayer();
        Show(route);
    }

    private async void Show(Route next)
    {
        Route = next;
        Error = null;
        var mine = ++loadVersion;
        if (cache.TryGetValue(next, out var cached)) { Page = cached; Loading = false; return; }
        Page = null;
        Loading = true;
        if (!ready) { StartReadyTimeout(); return; } // loads as soon as the player reports in
        try
        {
            var json = next.Kind == "search"
                ? await engine.FetchAsync($"search({Json.Js(next.Id)})")
                : await engine.FetchAsync($"browse({Json.Js(next.Id)})");
            var dto = Json.Parse<PageDto>(json) ?? new PageDto();
            if (mine != loadVersion) return;
            var vm = new PageVM(dto, next.Title);
            cache[next] = vm;
            Page = vm;
        }
        catch (Exception e)
        {
            if (mine != loadVersion) return;
            Error = "Couldn’t load this page. " + e.Message;
        }
        if (mine == loadVersion) Loading = false;
    }

    private void StartReadyTimeout()
    {
        readyTimeout?.Stop();
        readyTimeout = new DispatcherTimer { Interval = TimeSpan.FromSeconds(30) };
        readyTimeout.Tick += (_, _) =>
        {
            readyTimeout?.Stop();
            if (ready || error != null) return;
            Loading = false;
            Error = "YouTube Music is taking too long to load. Check your internet connection and try again.";
        };
        readyTimeout.Start();
    }

    private void PlayerFailed(string reason)
    {
        if (ready) return; // already running; a later sub-navigation failing is harmless
        readyTimeout?.Stop();
        Loading = false;
        Error = "Couldn’t reach YouTube Music. Check your internet connection and try again.\n" + reason;
    }

    private async void LoadPlaylists()
    {
        if (!loggedIn) { Playlists.Clear(); return; }
        try
        {
            var dto = Json.Parse<PageDto>(await engine.FetchAsync("browse(\"FEmusic_liked_playlists\")"));
            Playlists.Clear();
            foreach (var i in dto?.Sections.SelectMany(s => s.Items) ?? Enumerable.Empty<ItemDto>())
                if (i.Kind == "playlist" && i.BrowseId != null) Playlists.Add(new Item(i, 0));
        }
        catch { }
    }

    /// <summary>Fetches the next batch of a long list.</summary>
    public async Task LoadMoreAsync(SectionVM section)
    {
        if (section.Continuation is not { } token || section.LoadingMore) return;
        section.LoadingMore = true;
        section.MoreFailed = false;
        try
        {
            var batch = Json.Parse<BatchDto>(await engine.FetchAsync($"more({Json.Js(token)})")) ?? new BatchDto();
            var start = section.Items.Count;
            foreach (var (dto, i) in batch.Items.Select((d, i) => (d, i))) section.Items.Add(new Item(dto, start + i + 1));
            // An empty batch means the list is finished even if a token came back.
            section.Continuation = batch.Items.Count == 0 ? null : batch.Continuation;
            MarkCurrent();
        }
        catch { section.MoreFailed = true; }
        finally { section.LoadingMore = false; }
    }

    // MARK: Playback

    public void Activate(Item item)
    {
        if (item.VideoId != null || (item.BrowseId == null && item.PlaylistId != null))
            Play(item.VideoId, item.PlaylistId ?? page?.Header?.PlaylistId);
        else if (item.BrowseId is { } id)
            Open(Route.Browse(id, item.Title));
    }

    public void Play(string? videoId, string? playlistId, bool shuffled = false)
    {
        if (videoId == null && playlistId == null) return;
        engine.Run($"play({Json.Js(videoId)}, {Json.Js(playlistId)}, {(shuffled ? "true" : "false")})");
    }

    private void PlayHeader(bool shuffled)
    {
        if (page?.Header is not { } h) return;
        Play(h.FirstTrack?.VideoId, h.PlaylistId, shuffled);
    }

    public void PlayPause() => engine.Run("playPause()");
    public void Next() => engine.Run("next()");
    public void Previous() => engine.Run("previous()");

    public void Seek(double seconds)
    {
        Time = seconds;
        engine.Run($"seek({seconds.ToString(System.Globalization.CultureInfo.InvariantCulture)})");
    }

    public void SetVolume(double value)
    {
        value = Math.Clamp(value, 0, 100);
        Volume = value;
        volumeSetAt = DateTime.UtcNow;
        engine.Run($"setVolume({(int)Math.Round(value)})");
    }

    public void SignIn()
    {
        signingIn = true;
        WebMode = true;
        engine.OpenSignIn();
    }

    private static string? LinkFor(Item i) =>
        i.VideoId != null ? $"https://music.youtube.com/watch?v={i.VideoId}"
        : i.BrowseId != null ? $"https://music.youtube.com/browse/{i.BrowseId}"
        : i.PlaylistId != null ? $"https://music.youtube.com/playlist?list={i.PlaylistId}" : null;

    private void MarkCurrent()
    {
        if (page == null) return;
        foreach (var s in page.Sections)
            foreach (var i in s.Items) i.IsCurrent = i.VideoId != null && i.VideoId == Now.Id;
    }

    // MARK: Updates from the web player

    private void OnMessage(JsonElement body)
    {
        switch (Str(body, "type"))
        {
            case "time":
                if (Str(body, "id") == Now.Id && body.TryGetProperty("t", out var t) && t.ValueKind == JsonValueKind.Number)
                {
                    if (!Scrubbing) Time = t.GetDouble();
                    Lyrics.SetTime(t.GetDouble());
                }
                break;
            case "track":
                PlayerReported(body);
                // Sign-in finished: back on YouTube Music with an account.
                if (signingIn && Bool(body, "loggedIn")) WebMode = false;
                break;
        }
    }

    /// <summary>Set while the user drags the scrubber, so the player's time does not fight it.</summary>
    public bool Scrubbing { get; set; }

    private void PlayerReported(JsonElement b)
    {
        var isReady = Bool(b, "ready");
        var isLoggedIn = Bool(b, "loggedIn");
        var sessionChanged = isReady && (!ready || isLoggedIn != loggedIn);
        if (isReady)
        {
            readyTimeout?.Stop();
            Ready = true;
            LoggedIn = isLoggedIn;
        }
        if (sessionChanged)
        {
            cache.Clear();
            Show(route);
            LoadPlaylists();
        }

        if (Bool(b, "ad")) { Now.Ad = true; return; }
        var previousId = Now.Id;
        Now.Ad = false;
        Now.Id = Str(b, "id");
        Now.Title = Str(b, "title");
        Now.Artist = Str(b, "artist");
        Now.Art = Str(b, "art");
        Now.Duration = Num(b, "duration");
        Now.Playing = Bool(b, "playing");
        var afmt = Str(b, "afmt");
        Now.Format = afmt.Length == 0 ? "" : AudioFormats.GetValueOrDefault(afmt, $"Format {afmt}");
        if (previousId != Now.Id) MarkCurrent();

        // Ignore the player's echo for a moment after the user moves the slider.
        var v = Num(b, "volume", -1);
        if (v >= 0 && Math.Abs(v - volume) > 0.5 && (DateTime.UtcNow - volumeSetAt).TotalSeconds > 1.5) Volume = v;

        currentTrack = new Track(Now.Id, Now.Title, Now.Artist, Str(b, "album"), Now.Duration);
        // Nothing is sent to LRCLIB while the lyrics panel is closed.
        if (showLyrics) Lyrics.SetTrack(currentTrack);
    }

    private static string Str(JsonElement b, string k) =>
        b.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() ?? "" : "";
    private static bool Bool(JsonElement b, string k) =>
        b.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.True;
    private static double Num(JsonElement b, string k, double fallback = 0) =>
        b.TryGetProperty(k, out var v) && v.ValueKind == JsonValueKind.Number ? v.GetDouble() : fallback;

    /// <summary>YouTube audio format ids ("itags") for the streams the web player uses.</summary>
    private static readonly Dictionary<string, string> AudioFormats = new()
    {
        ["139"] = "AAC 48 kbps", ["140"] = "AAC 128 kbps", ["141"] = "AAC 256 kbps",
        ["249"] = "Opus 50 kbps", ["250"] = "Opus 70 kbps", ["251"] = "Opus 160 kbps", ["774"] = "Opus 256 kbps",
    };
}

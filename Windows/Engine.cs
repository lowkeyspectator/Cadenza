using System.Diagnostics;
using System.IO;
using System.Text.Json;
using System.Text.RegularExpressions;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.Wpf;

namespace Cadenza;

/// <summary>
/// Hosts the official YouTube Music web player in a WebView2 and talks to it through the same
/// injected bridge as the macOS app (window.__cadenza). The player stays hidden behind the
/// native interface unless the user is signing in or changing account settings.
/// </summary>
public sealed class Engine
{
    public static readonly Uri Home = new("https://music.youtube.com/");
    private const string SignInUrl =
        "https://accounts.google.com/ServiceLogin?service=youtube&continue=https%3A%2F%2Fmusic.youtube.com%2F";

    private readonly WebView2 web;
    private readonly Dictionary<int, TaskCompletionSource<string>> pending = new();
    private int nextRequest;
    private string? scriptId;
    private bool navigating;

    /// <summary>A message from the bridge ("track" or "time").</summary>
    public event Action<JsonElement>? Message;
    /// <summary>The player page could not be loaded (offline, DNS…).</summary>
    public event Action<string>? LoadFailed;

    public bool WebModeOn { get; set; }

    public Engine(WebView2 web) { this.web = web; }

    private CoreWebView2 Core => web.CoreWebView2;

    public async Task StartAsync(bool audioOnly, string? homeOverride = null)
    {
        // Keep timers running while the player is hidden: the bridge polls the player a few
        // times a second, and Chromium otherwise slows background pages down to once a minute.
        var options = new CoreWebView2EnvironmentOptions(
            "--disable-background-timer-throttling --disable-renderer-backgrounding " +
            "--disable-backgrounding-occluded-windows --autoplay-policy=no-user-gesture-required " +
            "--enable-features=HardwareMediaKeyHandling");
        var env = await CoreWebView2Environment.CreateAsync(null, Path.Combine(App.DataFolder, "WebView2"), options);
        await web.EnsureCoreWebView2Async(env);

        Core.Settings.AreDevToolsEnabled = true;
        Core.Settings.IsStatusBarEnabled = false;
        Core.Settings.AreDefaultContextMenusEnabled = true;
        await InstallBridgeAsync(audioOnly);

        Core.WebMessageReceived += OnMessage;
        Core.NavigationStarting += OnNavigationStarting;
        Core.NavigationCompleted += OnNavigationCompleted;
        Core.NewWindowRequested += OnNewWindow;
        Core.ProcessFailed += (_, _) => Core.Reload();

        var start = homeOverride != null && Uri.TryCreate(homeOverride, UriKind.Absolute, out var o) ? o : Home;
        Core.Navigate(start.ToString());
    }

    /// <summary>The bridge (from the macOS source) plus a shim that gives it the messaging API it expects.</summary>
    private async Task InstallBridgeAsync(bool audioOnly)
    {
        if (scriptId != null) Core.RemoveScriptToExecuteOnDocumentCreated(scriptId);
        var script =
            "(function () {\n" +
            "  if (window.top !== window || location.hostname !== 'music.youtube.com') return;\n" +
            "  window.webkit = { messageHandlers: { cadenza: { postMessage: function (m) { window.chrome.webview.postMessage(m); } } } };\n" +
            "  var run = function () {\n" + BridgeSource.Value + "\n" +
            $"    if (window.__cadenza) window.__cadenza.audioOnly = {(audioOnly ? "true" : "false")};\n" +
            "  };\n" +
            "  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', run, { once: true }); else run();\n" +
            "})();";
        scriptId = await Core.AddScriptToExecuteOnDocumentCreatedAsync(script);
    }

    public async Task SetAudioOnlyAsync(bool on)
    {
        await InstallBridgeAsync(on); // for the next page load
        Run($"setAudioOnly({(on ? "true" : "false")})");
    }

    // MARK: Calls into the bridge

    /// <summary>Calls a function on window.__cadenza without waiting for a result.</summary>
    public void Run(string call)
    {
        if (web.CoreWebView2 == null) return;
        _ = Core.ExecuteScriptAsync($"window.__cadenza && window.__cadenza.{call}");
    }

    /// <summary>Calls an async bridge function and returns its result as JSON.</summary>
    public async Task<string> FetchAsync(string call)
    {
        Exception last = new TimeoutException("YouTube Music did not respond.");
        // The player page may be mid-load (launch, after sign-in), so wait and retry.
        for (var attempt = 0; attempt < 3; attempt++)
        {
            if (attempt > 0) await Task.Delay(700);
            if (!await BridgeReadyAsync()) continue;
            try { return await InvokeAsync(call); }
            catch (Exception e) { last = e; }
        }
        throw last;
    }

    private async Task<string> InvokeAsync(string call)
    {
        var id = ++nextRequest;
        var tcs = new TaskCompletionSource<string>();
        pending[id] = tcs;
        // ExecuteScriptAsync does not wait for promises, so the result comes back as a message.
        var js = "(async () => { const post = (m) => window.chrome.webview.postMessage(m);" +
                 $" try {{ const r = await window.__cadenza.{call};" +
                 $" post({{ type: 'reply', rid: {id}, ok: true, data: JSON.stringify(r) }}); }}" +
                 $" catch (e) {{ post({{ type: 'reply', rid: {id}, ok: false, error: String((e && e.message) || e) }}); }} }})();";
        await Core.ExecuteScriptAsync(js);
        var done = await Task.WhenAny(tcs.Task, Task.Delay(TimeSpan.FromSeconds(20)));
        pending.Remove(id);
        if (done != tcs.Task) throw new TimeoutException("YouTube Music did not respond.");
        return await tcs.Task;
    }

    private async Task<bool> BridgeReadyAsync()
    {
        const string probe =
            "!!(window.__cadenza && window.__cadenza.browse && window.ytcfg && window.ytcfg.get('INNERTUBE_CONTEXT'))";
        for (var i = 0; i < 40; i++) // up to ~10 s
        {
            if (web.CoreWebView2 == null) { await Task.Delay(250); continue; }
            // Stranded on a sign-in page with the web player hidden: go back to the player.
            if (!WebModeOn && !navigating && Uri.TryCreate(Core.Source, UriKind.Absolute, out var u)
                && !IsPlayerHost(u.Host) && u.Scheme.StartsWith("http"))
                ReloadPlayer();
            if (await Core.ExecuteScriptAsync(probe) == "true") return true;
            await Task.Delay(250);
        }
        return false;
    }

    public void ReloadPlayer() => Core?.Navigate(Home.ToString());
    public void OpenSignIn() => Core?.Navigate(SignInUrl);
    public bool IsOnPlayer => web.CoreWebView2 != null && Uri.TryCreate(Core.Source, UriKind.Absolute, out var u) && IsPlayerHost(u.Host);

    // MARK: Events from the page

    private void OnMessage(object? sender, CoreWebView2WebMessageReceivedEventArgs e)
    {
        // Only the player page may talk to the app.
        if (!Uri.TryCreate(e.Source, UriKind.Absolute, out var source) || !IsPlayerHost(source.Host)) return;
        JsonElement body;
        try { body = JsonDocument.Parse(e.WebMessageAsJson).RootElement.Clone(); }
        catch { return; }
        if (body.ValueKind != JsonValueKind.Object) return;
        var type = body.TryGetProperty("type", out var t) ? t.GetString() : null;
        if (type == "reply")
        {
            var rid = body.GetProperty("rid").GetInt32();
            if (!pending.TryGetValue(rid, out var tcs)) return;
            if (body.GetProperty("ok").GetBoolean()) tcs.TrySetResult(body.GetProperty("data").GetString() ?? "null");
            else tcs.TrySetException(new InvalidOperationException(body.GetProperty("error").GetString()));
            return;
        }
        Message?.Invoke(body);
    }

    private void OnNavigationStarting(object? sender, CoreWebView2NavigationStartingEventArgs e)
    {
        if (Uri.TryCreate(e.Uri, UriKind.Absolute, out var url) && (url.Scheme == "http" || url.Scheme == "https")
            && !IsInApp(url))
        {
            // Artist websites, merch links and the like belong in the real browser.
            e.Cancel = true;
            if (e.IsUserInitiated) OpenInBrowser(url);
            return;
        }
        navigating = true;
    }

    private void OnNavigationCompleted(object? sender, CoreWebView2NavigationCompletedEventArgs e)
    {
        navigating = false;
        if (e.IsSuccess || e.WebErrorStatus == CoreWebView2WebErrorStatus.OperationCanceled) return;
        LoadFailed?.Invoke(Describe(e.WebErrorStatus));
    }

    private void OnNewWindow(object? sender, CoreWebView2NewWindowRequestedEventArgs e)
    {
        e.Handled = true;
        if (!Uri.TryCreate(e.Uri, UriKind.Absolute, out var url)) return;
        if (IsInApp(url)) Core.Navigate(url.ToString()); else OpenInBrowser(url);
    }

    private static void OpenInBrowser(Uri url)
    {
        try { Process.Start(new ProcessStartInfo(url.ToString()) { UseShellExecute = true }); } catch { }
    }

    private static string Describe(CoreWebView2WebErrorStatus status) => status switch
    {
        CoreWebView2WebErrorStatus.HostNameNotResolved => "The server could not be found.",
        CoreWebView2WebErrorStatus.Disconnected or CoreWebView2WebErrorStatus.ConnectionAborted
            or CoreWebView2WebErrorStatus.ConnectionReset => "The connection was lost.",
        CoreWebView2WebErrorStatus.Timeout => "The connection timed out.",
        CoreWebView2WebErrorStatus.CannotConnect => "Could not connect.",
        _ => status.ToString(),
    };

    // MARK: Hosts

    public static bool IsPlayerHost(string? host) => string.Equals(host, "music.youtube.com", StringComparison.OrdinalIgnoreCase);

    private static readonly Regex GoogleHost = new(@"(^|\.)google\.(com|[a-z]{2}|co\.[a-z]{2}|com\.[a-z]{2})$", RegexOptions.IgnoreCase);

    /// <summary>Hosts that stay inside the app: the player itself and Google's sign-in.</summary>
    public static bool IsInApp(Uri url)
    {
        var host = url.Host.ToLowerInvariant();
        bool Within(string domain) => host == domain || host.EndsWith("." + domain);
        return Within("youtube.com") || Within("youtube-nocookie.com") || Within("googleusercontent.com")
            || Within("gstatic.com") || GoogleHost.IsMatch(host);
    }
}

/// <summary>The bridge JavaScript, read out of the macOS app's BridgeScript.swift.</summary>
public static class BridgeSource
{
    public static readonly Lazy<string> Lazy = new(Load);
    public static string Value => Lazy.Value;

    private static string Load()
    {
        using var stream = typeof(BridgeSource).Assembly.GetManifestResourceStream("BridgeScript.swift")
            ?? throw new InvalidOperationException("Bridge script missing from the build.");
        using var reader = new StreamReader(stream);
        var swift = reader.ReadToEnd().Replace("\r\n", "\n");
        // let bridgeScript = #""" … """#   (a Swift raw string: the text between is used verbatim)
        var start = swift.IndexOf("#\"\"\"\n", StringComparison.Ordinal);
        var end = swift.LastIndexOf("\n\"\"\"#", StringComparison.Ordinal);
        if (start < 0 || end <= start) throw new InvalidOperationException("Bridge script not found in BridgeScript.swift.");
        return swift.Substring(start + 5, end - start - 5);
    }
}

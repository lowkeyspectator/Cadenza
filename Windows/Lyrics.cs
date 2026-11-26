using System.Collections.ObjectModel;
using System.Globalization;
using System.Net;
using System.Net.Http;
using System.Reflection;
using System.Text;
using System.Text.RegularExpressions;

namespace Cadenza;

public sealed record Track(string Id = "", string Title = "", string Artist = "", string Album = "", double Duration = 0);

public sealed class LyricLine : Observable
{
    public LyricLine(int index, double time, string text) { Index = index; Time = time; Text = text; }
    public int Index { get; }
    public double Time { get; }
    public string Text { get; }
    public string Stamp => $"{(int)Time / 60}:{(int)Time % 60:00}";

    private bool current, past;
    public bool IsCurrent { get => current; set => Set(ref current, value); }
    public bool IsPast { get => past; set => Set(ref past, value); }
}

/// <summary>
/// Timed lyrics from LRCLIB (https://lrclib.net), a free community database. Only the title,
/// artist, album and length are sent. Same matching rules as the macOS app (Lyrics.swift).
/// </summary>
public static class LyricsService
{
    public abstract record Result;
    public sealed record Synced(List<(double Time, string Text)> Lines) : Result;
    public sealed record Plain(string Text) : Result;
    public sealed record Instrumental : Result;
    public sealed record NotFound : Result;

    private sealed class Entry
    {
        public string? AlbumName { get; set; }
        public double? Duration { get; set; }
        public bool? Instrumental { get; set; }
        public string? PlainLyrics { get; set; }
        public string? SyncedLyrics { get; set; }
    }

    private static readonly HttpClient Http = CreateClient();

    private static HttpClient CreateClient()
    {
        var client = new HttpClient { Timeout = TimeSpan.FromSeconds(15) };
        var version = Assembly.GetExecutingAssembly().GetName().Version?.ToString(3) ?? "dev";
        client.DefaultRequestHeaders.UserAgent.ParseAdd($"Cadenza/{version} (Windows music player; https://github.com/lowkeyspectator/Cadenza)");
        return client;
    }

    /// <summary>Throws only when LRCLIB could not be reached, so that is not mistaken for "no lyrics".</summary>
    public static async Task<Result> FetchAsync(Track track, string? reference)
    {
        var candidates = new List<Entry>();
        var exact = $"https://lrclib.net/api/get?track_name={Uri.EscapeDataString(track.Title)}" +
                    $"&artist_name={Uri.EscapeDataString(track.Artist)}&duration={(int)Math.Round(track.Duration)}";
        if (track.Album.Length > 0) exact += $"&album_name={Uri.EscapeDataString(track.Album)}";
        if (await GetAsync<Entry>(exact) is { } hit) candidates.Add(hit);

        reference = (reference ?? "").Trim();
        var trusted = candidates.Count > 0 && (reference.Length == 0 || Similarity(TextOf(candidates[0]), reference) >= 0.6);
        if (!trusted)
        {
            // Looser search: drop "(Remastered)", "[Official Video]", featured artists and the like.
            var search = $"https://lrclib.net/api/search?track_name={Uri.EscapeDataString(Simplified(track.Title))}" +
                         $"&artist_name={Uri.EscapeDataString(PrimaryArtist(track.Artist))}";
            if (await GetAsync<List<Entry>>(search) is { } entries)
                candidates.AddRange(entries
                    .Where(e => Math.Abs((e.Duration ?? 0) - track.Duration) <= 4)
                    .OrderBy(e => Math.Abs((e.Duration ?? 0) - track.Duration)));
        }

        if (reference.Length == 0)
        {
            // Nothing to check the words against: accept only the same album (exact), since
            // film songs exist in several languages under one title and artist.
            var album = Fold(track.Album);
            var same = candidates.Where(c => album.Length > 0 && Fold(c.AlbumName ?? "") == album).ToList();
            var best = same.FirstOrDefault(c => !string.IsNullOrEmpty(c.SyncedLyrics)) ?? same.FirstOrDefault();
            return (best == null ? null : ResultFrom(best)) ?? new NotFound();
        }

        var timed = candidates
            .Select(c => (c, score: Similarity(TextOf(c), reference)))
            .Where(x => x.score >= 0.6)
            .OrderByDescending(x => x.score)
            .FirstOrDefault(x => !string.IsNullOrEmpty(x.c.SyncedLyrics));
        if (timed.c != null && ResultFrom(timed.c) is Synced synced) return synced;
        return new Plain(reference);
    }

    private static async Task<T?> GetAsync<T>(string url) where T : class
    {
        using var response = await Http.GetAsync(url);
        if (response.StatusCode == HttpStatusCode.TooManyRequests || (int)response.StatusCode >= 500)
            throw new HttpRequestException($"LRCLIB returned {(int)response.StatusCode}");
        if (response.StatusCode != HttpStatusCode.OK) return null;
        try { return Json.Parse<T>(await response.Content.ReadAsStringAsync()); }
        catch { return null; }
    }

    private static Result? ResultFrom(Entry e)
    {
        if (!string.IsNullOrEmpty(e.SyncedLyrics))
        {
            var lines = ParseLrc(e.SyncedLyrics);
            if (lines.Count > 0) return new Synced(lines);
        }
        if (!string.IsNullOrEmpty(e.PlainLyrics)) return new Plain(e.PlainLyrics);
        if (e.Instrumental == true) return new Instrumental();
        return null;
    }

    private static string TextOf(Entry e) =>
        !string.IsNullOrEmpty(e.PlainLyrics) ? e.PlainLyrics : string.Join("\n", ParseLrc(e.SyncedLyrics ?? "").Select(l => l.Text));

    private static readonly Regex Stamp = new(@"\[(\d+):(\d+(?:\.\d+)?)\]");

    public static List<(double Time, string Text)> ParseLrc(string lrc)
    {
        var timed = new List<(double, string)>();
        foreach (var raw in lrc.Replace("\r", "").Split('\n'))
        {
            var matches = Stamp.Matches(raw);
            if (matches.Count == 0) continue;
            var text = Stamp.Replace(raw, "").Trim();
            foreach (Match m in matches)
            {
                if (double.TryParse(m.Groups[1].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out var min)
                    && double.TryParse(m.Groups[2].Value, NumberStyles.Float, CultureInfo.InvariantCulture, out var sec))
                    timed.Add((min * 60 + sec, text.Length == 0 ? "♪" : text));
            }
        }
        return timed.OrderBy(t => t.Item1).ToList();
    }

    /// <summary>The non-Latin writing systems that make up a meaningful share of a text.</summary>
    public static HashSet<int> Scripts(string s)
    {
        var counts = new Dictionary<int, int>();
        var letters = 0;
        foreach (var r in s.EnumerateRunes())
        {
            if (!Rune.IsLetter(r)) continue;
            letters++;
            if (r.Value < 0x0370) continue;
            var block = r.Value is >= 0x3400 and <= 0x9FFF ? 0x3400 : r.Value / 0x80; // CJK as one
            counts[block] = counts.GetValueOrDefault(block) + 1;
        }
        return letters == 0 ? new() : counts.Where(kv => (double)kv.Value / letters >= 0.08).Select(kv => kv.Key).ToHashSet();
    }

    private static readonly Regex NonLetters = new(@"[^\p{L}\p{M}]+");

    /// <summary>Overlap between two lyric texts, 0…1 (words, or character pairs for unspaced scripts).</summary>
    public static double Similarity(string a, string b)
    {
        static HashSet<string> Units(string s)
        {
            var words = NonLetters.Split(s.ToLowerInvariant()).Where(w => w.Length > 0).ToList();
            var letters = string.Concat(words);
            if (letters.Length == 0) return new();
            if (words.Count > letters.Length / 12.0) return words.ToHashSet();
            var chars = new List<string>();
            var e = StringInfo.GetTextElementEnumerator(letters);
            while (e.MoveNext() && chars.Count < 6000) chars.Add((string)e.Current);
            return chars.Zip(chars.Skip(1), (x, y) => x + y).ToHashSet();
        }
        // Different writing systems means a different-language version or a romanisation.
        if (!Scripts(a).SetEquals(Scripts(b))) return 0;
        var ua = Units(a); var ub = Units(b);
        if (ua.Count == 0 || ub.Count == 0) return 0;
        return (double)ua.Intersect(ub).Count() / Math.Min(ua.Count, ub.Count);
    }

    private static string Fold(string s)
    {
        var sb = new StringBuilder();
        foreach (var c in s.Normalize(NormalizationForm.FormD))
            if (CharUnicodeInfo.GetUnicodeCategory(c) != UnicodeCategory.NonSpacingMark && char.IsLetterOrDigit(c))
                sb.Append(char.ToLowerInvariant(c));
        return sb.ToString();
    }

    private static string Simplified(string title)
    {
        var s = Regex.Replace(title, @"\s*[\(\[][^\)\]]*[\)\]]", "");
        s = Regex.Replace(s, @"\s+-\s+.*(remaster|version|edit|mix|live).*$", "", RegexOptions.IgnoreCase).Trim();
        return s.Length == 0 ? title : s;
    }

    private static string PrimaryArtist(string artist)
    {
        var first = artist.Split(',', '&', '•')[0];
        return Regex.Replace(first, @"\s+(feat\.?|ft\.?|featuring)\s+.*$", "", RegexOptions.IgnoreCase).Trim();
    }
}

public enum LyricsStatus { Idle, Loading, Synced, Plain, Instrumental, NotFound, Failed }

public sealed class LyricsModel : Observable
{
    public ObservableCollection<LyricLine> Lines { get; } = new();
    public Func<string, Task<string?>>? Reference { get; set; }
    public Action<double>? SeekRequested { get; set; }

    private Track track = new();
    public Track Track { get => track; private set { Set(ref track, value); Raise(nameof(Heading)); } }
    public string Heading => track.Title.Length == 0 ? "Lyrics" : track.Title;

    private LyricsStatus status;
    public LyricsStatus Status { get => status; private set { Set(ref status, value); Raise(nameof(Message)); Raise(nameof(IsSynced)); Raise(nameof(IsPlain)); Raise(nameof(HasMessage)); Raise(nameof(IsFailed)); } }
    public bool IsSynced => status == LyricsStatus.Synced;
    public bool IsPlain => status == LyricsStatus.Plain;
    public bool IsFailed => status == LyricsStatus.Failed;
    public bool HasMessage => status is LyricsStatus.Idle or LyricsStatus.Loading or LyricsStatus.NotFound or LyricsStatus.Instrumental or LyricsStatus.Failed;
    public string Message => status switch
    {
        LyricsStatus.Idle => "Play a song to see its lyrics.",
        LyricsStatus.Loading => "Loading lyrics…",
        LyricsStatus.NotFound => "No lyrics found for this song.",
        LyricsStatus.Instrumental => "Instrumental",
        LyricsStatus.Failed => "Couldn’t load lyrics. Check your internet connection.",
        _ => "",
    };

    private string plainText = "";
    public string PlainText { get => plainText; private set => Set(ref plainText, value); }
    private string source = "";
    public string Source { get => source; private set => Set(ref source, value); }

    private int currentIndex = -1;
    public LyricLine? Current => currentIndex >= 0 && currentIndex < Lines.Count ? Lines[currentIndex] : null;
    public event Action<LyricLine>? CurrentChanged;

    private int generation;

    public void SetTrack(Track next)
    {
        if (next == track) return;
        // Duration settles a moment after the track changes; don't refetch for that.
        var sameSong = next.Id == track.Id && next.Title == track.Title && next.Artist == track.Artist
                       && Math.Abs(next.Duration - track.Duration) < 1.5;
        Track = next;
        if (sameSong && status != LyricsStatus.Idle) return;

        var mine = ++generation;
        Source = ""; Lines.Clear(); currentIndex = -1; PlainText = "";
        if (next.Title.Length == 0 || next.Duration <= 0) { Status = LyricsStatus.Idle; return; }
        Status = LyricsStatus.Loading;
        _ = LoadAsync(next, mine);
    }

    private async Task LoadAsync(Track t, int mine)
    {
        await Task.Delay(500); // let title/artist settle
        if (mine != generation) return;
        string? reference = null;
        try { reference = Reference == null ? null : await Reference(t.Id); } catch { }
        if (mine != generation) return;
        try
        {
            var result = await LyricsService.FetchAsync(t, reference);
            if (mine == generation) Apply(result, !string.IsNullOrEmpty(reference));
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException)
        {
            if (mine != generation) return;
            // Offline or LRCLIB down: YouTube Music's own lyrics are still worth showing.
            if (!string.IsNullOrEmpty(reference)) Apply(new LyricsService.Plain(reference), true);
            else Status = LyricsStatus.Failed;
        }
    }

    public void Retry()
    {
        var t = track;
        Track = new Track();
        Status = LyricsStatus.Idle;
        SetTrack(t);
    }

    private void Apply(LyricsService.Result result, bool checkedAgainstYouTube)
    {
        switch (result)
        {
            case LyricsService.Synced s:
                for (var i = 0; i < s.Lines.Count; i++) Lines.Add(new LyricLine(i, s.Lines[i].Time, s.Lines[i].Text));
                Source = checkedAgainstYouTube ? "Timed lyrics from LRCLIB, matched to YouTube Music’s lyrics"
                                               : "Timed lyrics from LRCLIB (matched by title, artist and album)";
                Status = LyricsStatus.Synced;
                break;
            case LyricsService.Plain p:
                PlainText = p.Text;
                Source = checkedAgainstYouTube ? "Lyrics from YouTube Music" : "Lyrics from LRCLIB";
                Status = LyricsStatus.Plain;
                break;
            case LyricsService.Instrumental: Status = LyricsStatus.Instrumental; break;
            default: Status = LyricsStatus.NotFound; break;
        }
    }

    public void SetTime(double t)
    {
        if (status != LyricsStatus.Synced || Lines.Count == 0) return;
        // Last line that has started (lines are sorted by time).
        int lo = 0, hi = Lines.Count;
        while (lo < hi) { var mid = (lo + hi) / 2; if (Lines[mid].Time <= t + 0.2) lo = mid + 1; else hi = mid; }
        var index = lo - 1;
        if (index == currentIndex) return;
        currentIndex = index;
        foreach (var line in Lines) { line.IsCurrent = line.Index == index; line.IsPast = line.Index < index; }
        if (Current is { } c) CurrentChanged?.Invoke(c);
    }

    public void Seek(LyricLine line) => SeekRequested?.Invoke(line.Time);
}

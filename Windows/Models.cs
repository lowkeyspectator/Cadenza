using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Windows.Input;

namespace Cadenza;

public abstract class Observable : INotifyPropertyChanged
{
    public event PropertyChangedEventHandler? PropertyChanged;

    protected bool Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return false;
        field = value;
        Raise(name);
        return true;
    }

    protected void Raise([CallerMemberName] string? name = null) =>
        PropertyChanged?.Invoke(this, new PropertyChangedEventArgs(name));
}

public sealed class Command : ICommand
{
    private readonly Action<object?> run;
    private readonly Func<object?, bool>? can;

    public Command(Action<object?> run, Func<object?, bool>? can = null) { this.run = run; this.can = can; }
    public Command(Action run) : this(_ => run()) { }

    public event EventHandler? CanExecuteChanged
    {
        add => CommandManager.RequerySuggested += value;
        remove => CommandManager.RequerySuggested -= value;
    }

    public bool CanExecute(object? parameter) => can?.Invoke(parameter) ?? true;
    public void Execute(object? parameter) => run(parameter);
}

// MARK: Data returned by the bridge (same shapes as the macOS app)

public sealed class ItemDto
{
    public string Title { get; set; } = "";
    public string? Subtitle { get; set; }
    public string? Thumb { get; set; }
    public string Kind { get; set; } = "";
    public string? VideoId { get; set; }
    public string? PlaylistId { get; set; }
    public string? BrowseId { get; set; }
    public string? Duration { get; set; }
}

public sealed class SectionDto
{
    public string Title { get; set; } = "";
    public string Style { get; set; } = "list";
    public List<ItemDto> Items { get; set; } = new();
    public string? Continuation { get; set; }
}

public sealed class HeaderDto
{
    public string Title { get; set; } = "";
    public string? Subtitle { get; set; }
    public string? Second { get; set; }
    public string? Thumb { get; set; }
    public string? PlaylistId { get; set; }
    public bool? Round { get; set; }
}

public sealed class PageDto
{
    public HeaderDto? Header { get; set; }
    public List<SectionDto> Sections { get; set; } = new();
}

public sealed class BatchDto
{
    public List<ItemDto> Items { get; set; } = new();
    public string? Continuation { get; set; }
}

public static class Json
{
    public static readonly JsonSerializerOptions Options = new(JsonSerializerDefaults.Web);
    public static T? Parse<T>(string json) => JsonSerializer.Deserialize<T>(json, Options);
    /// <summary>A JavaScript literal for a string (or null).</summary>
    public static string Js(string? value) => value == null ? "null" : JsonSerializer.Serialize(value);
}

// MARK: What the interface shows

public sealed class Item : Observable
{
    public Item(ItemDto d, int number)
    {
        Title = d.Title; Subtitle = d.Subtitle ?? ""; Thumb = d.Thumb ?? ""; Kind = d.Kind;
        VideoId = d.VideoId; PlaylistId = d.PlaylistId; BrowseId = d.BrowseId; Duration = d.Duration ?? "";
        Number = number;
    }

    public string Title { get; }
    public string Subtitle { get; }
    public string Thumb { get; }
    public string Kind { get; }
    public string? VideoId { get; }
    public string? PlaylistId { get; }
    public string? BrowseId { get; }
    public string Duration { get; }
    public int Number { get; }

    public bool IsRound => Kind == "artist";
    public bool HasArt => Thumb.Length > 0;
    public bool HasSubtitle => Subtitle.Length > 0;
    public bool CanPlay => VideoId != null || (PlaylistId != null && !IsRound);
    public bool OpensPage => VideoId == null && BrowseId != null;
    public string Accessible => HasSubtitle ? $"{Title}, {Subtitle}" : Title;

    private bool isCurrent;
    public bool IsCurrent { get => isCurrent; set => Set(ref isCurrent, value); }
}

public sealed class SectionVM : Observable
{
    public SectionVM(SectionDto d)
    {
        Title = d.Title;
        Style = d.Style is "carousel" or "grid" ? d.Style : "list";
        Items = new ObservableCollection<Item>(d.Items.Select((x, i) => new Item(x, i + 1)));
        continuation = d.Continuation;
    }

    public string Title { get; }
    public string Style { get; }
    public ObservableCollection<Item> Items { get; }
    public bool ShowTitle { get; set; } = true;

    private string? continuation;
    public string? Continuation { get => continuation; set { Set(ref continuation, value); Raise(nameof(HasMore)); } }
    public bool HasMore => continuation != null;

    private bool loadingMore;
    public bool LoadingMore { get => loadingMore; set { Set(ref loadingMore, value); Raise(nameof(MoreText)); } }
    private bool moreFailed;
    public bool MoreFailed { get => moreFailed; set { Set(ref moreFailed, value); Raise(nameof(MoreText)); } }
    public string MoreText => LoadingMore ? "Loading…" : MoreFailed ? "Couldn’t load more. Try Again" : "Show More";
}

public sealed class HeaderVM
{
    public HeaderVM(HeaderDto d, Item? firstTrack)
    {
        Title = d.Title; Subtitle = d.Subtitle ?? ""; Second = d.Second ?? ""; Thumb = d.Thumb ?? "";
        IsRound = d.Round ?? false;
        FirstTrack = firstTrack;
        PlaylistId = firstTrack?.PlaylistId ?? d.PlaylistId;
    }

    public string Title { get; }
    public string Subtitle { get; }
    public string Second { get; }
    public string Thumb { get; }
    public bool IsRound { get; }
    public Item? FirstTrack { get; }
    public string? PlaylistId { get; }
    public bool CanPlay => PlaylistId != null || FirstTrack != null;
}

public sealed class PageVM
{
    public PageVM(PageDto d, string fallbackTitle)
    {
        Sections = new ObservableCollection<SectionVM>(d.Sections.Select(s => new SectionVM(s)));
        var first = Sections.FirstOrDefault(s => s.Style == "list")?.Items.FirstOrDefault(i => i.VideoId != null);
        Header = d.Header == null ? null : new HeaderVM(d.Header, first);
        Title = fallbackTitle;
        var titles = Sections.Count > 1 || Header == null;
        foreach (var s in Sections) s.ShowTitle = titles && s.Title.Length > 0;
    }

    public HeaderVM? Header { get; }
    public string Title { get; }
    public bool HasHeader => Header != null;
    public ObservableCollection<SectionVM> Sections { get; }
    public bool IsEmpty => Sections.Count == 0 && Header == null;
}

public sealed record Route(string Kind, string Id, string Title)
{
    public static readonly Route HomeRoute = new("browse", "FEmusic_home", "Home");
    public static Route Browse(string id, string title) => new("browse", id, title);
    public static Route Search(string query) => new("search", query, $"Results for “{query}”");

    /// <summary>Library pages only have content for a signed-in account.</summary>
    public bool NeedsAccount => Kind == "browse" && (Id.StartsWith("FEmusic_liked") || Id.StartsWith("FEmusic_library") || Id == "VLLM");
}

public sealed class NavEntry : Observable
{
    public NavEntry(string glyph, string title, Route route) { Glyph = glyph; Title = title; Route = route; }
    public string Glyph { get; }
    public string Title { get; }
    public Route Route { get; }
    private bool selected;
    public bool IsSelected { get => selected; set => Set(ref selected, value); }
}

public sealed class NowPlaying : Observable
{
    private string id = "", title = "", artist = "", art = "", format = "";
    private double duration;
    private bool playing, ad;

    public string Id { get => id; set { if (Set(ref id, value)) Raise(nameof(IsEmpty)); } }
    public string Title { get => title; set { if (Set(ref title, value)) { Raise(nameof(DisplayTitle)); Raise(nameof(IsEmpty)); } } }
    public string Artist { get => artist; set { if (Set(ref artist, value)) Raise(nameof(DisplayArtist)); } }
    public string Art { get => art; set => Set(ref art, value); }
    public double Duration { get => duration; set => Set(ref duration, value); }
    public bool Playing { get => playing; set { if (Set(ref playing, value)) Raise(nameof(PlayGlyph)); } }
    public bool Ad { get => ad; set { if (Set(ref ad, value)) { Raise(nameof(DisplayTitle)); Raise(nameof(DisplayArtist)); } } }
    public string Format { get => format; set { if (Set(ref format, value)) Raise(nameof(HasFormat)); } }

    public bool IsEmpty => id.Length == 0 || title.Length == 0;
    public bool HasFormat => format.Length > 0;
    public string DisplayTitle => ad ? "Advertisement" : IsEmpty ? "Not Playing" : title;
    public string DisplayArtist => ad || IsEmpty ? "" : artist;
    public string PlayGlyph => playing ? "\uE769" : "\uE768"; // Pause / Play
}

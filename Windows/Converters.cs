using System.Globalization;
using System.Windows;
using System.Windows.Data;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Cadenza;

/// <summary>true → Visible (or the reverse with ConverterParameter=Invert). Also treats non-empty strings and non-null objects as true.</summary>
public sealed class VisibleWhen : IValueConverter
{
    public object Convert(object? value, Type t, object? p, CultureInfo c)
    {
        var on = value switch { bool b => b, string s => s.Length > 0, int n => n > 0, null => false, _ => true };
        if (p as string == "Invert") on = !on;
        return on ? Visibility.Visible : Visibility.Collapsed;
    }
    public object ConvertBack(object? v, Type t, object? p, CultureInfo c) => Binding.DoNothing;
}

public sealed class Not : IValueConverter
{
    public object Convert(object? value, Type t, object? p, CultureInfo c) => value is not true;
    public object ConvertBack(object? value, Type t, object? p, CultureInfo c) => value is not true;
}

/// <summary>Seconds → "m:ss".</summary>
public sealed class Clock : IValueConverter
{
    public object Convert(object? value, Type t, object? p, CultureInfo c)
    {
        var s = value is double d && double.IsFinite(d) && d > 0 ? (int)d : 0;
        return $"{s / 60}:{s % 60:00}";
    }
    public object ConvertBack(object? v, Type t, object? p, CultureInfo c) => Binding.DoNothing;
}

/// <summary>Artist pictures are round; everything else has rounded corners. Parameter: the size.</summary>
public sealed class Corner : IValueConverter
{
    public object Convert(object? value, Type t, object? p, CultureInfo c)
    {
        var size = double.TryParse(p as string, NumberStyles.Float, CultureInfo.InvariantCulture, out var s) ? s : 160;
        return value is true ? size / 2 : Math.Min(8, size / 10);
    }
    public object ConvertBack(object? v, Type t, object? p, CultureInfo c) => Binding.DoNothing;
}

/// <summary>
/// URL → image decoded at the size it is drawn (parameter: pixel width), cached so lists can be
/// scrolled and pages revisited without downloading or decoding the artwork again.
/// </summary>
public sealed class Artwork : IValueConverter
{
    private static readonly Dictionary<string, ImageSource> Cache = new();
    private static readonly Queue<string> Order = new();
    private const int Limit = 500;

    public object? Convert(object? value, Type t, object? p, CultureInfo c)
    {
        if (value is not string url || url.Length == 0 || !Uri.TryCreate(url, UriKind.Absolute, out var uri)) return null;
        var px = int.TryParse(p as string, out var n) ? n : 320;
        var key = px + "|" + url;
        if (Cache.TryGetValue(key, out var hit)) return hit;
        try
        {
            var image = new BitmapImage();
            image.BeginInit();
            image.UriSource = uri;
            image.DecodePixelWidth = px;
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.EndInit();
            Cache[key] = image;
            Order.Enqueue(key);
            while (Order.Count > Limit) Cache.Remove(Order.Dequeue());
            return image;
        }
        catch { return null; }
    }
    public object ConvertBack(object? v, Type t, object? p, CultureInfo c) => Binding.DoNothing;
}

/// <summary>Picks the template for a page section by its style.</summary>
public sealed class SectionTemplates : System.Windows.Controls.DataTemplateSelector
{
    public DataTemplate? Carousel { get; set; }
    public DataTemplate? Grid { get; set; }
    public DataTemplate? List { get; set; }

    public override DataTemplate? SelectTemplate(object item, DependencyObject container) =>
        (item as SectionVM)?.Style switch { "carousel" => Carousel, "grid" => Grid, _ => List };
}

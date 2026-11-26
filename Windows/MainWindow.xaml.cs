using System.ComponentModel;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Media;
using System.Windows.Threading;

namespace Cadenza;

public partial class MainWindow : Window
{
    private readonly Engine engine;
    internal Engine Engine => engine;
    private readonly AppViewModel vm;
    private bool settingSlider;      // a value set from the player, not by the user
    private bool keyboardNavigating; // Tab was used since the last click

    public MainWindow()
    {
        InitializeComponent();
        engine = new Engine(Web);
        vm = new AppViewModel(engine);
        DataContext = vm;

        vm.PropertyChanged += OnModelChanged;
        vm.Now.PropertyChanged += OnNowChanged;
        vm.TimeChanged += OnTime;
        vm.Lyrics.CurrentChanged += ScrollLyrics;

        Scrubber.AddHandler(Thumb.DragStartedEvent, new DragStartedEventHandler((_, _) => vm.Scrubbing = true));
        Scrubber.AddHandler(Thumb.DragCompletedEvent, new DragCompletedEventHandler((_, _) =>
        {
            vm.Scrubbing = false;
            vm.Seek(Scrubber.Value);
        }));
        Scrubber.ValueChanged += OnScrubberChanged;

        VolumeSlider.Value = vm.Volume;
        VolumeSlider.ValueChanged += (_, e) => { if (!settingSlider) vm.SetVolume(e.NewValue); UpdateVolumeIcon(); };
        VolumeSlider.MouseWheel += VolumeWheel;
        VolumeIcon.MouseWheel += VolumeWheel;

        PreviewKeyDown += OnPreviewKeyDown;
        PreviewMouseDown += (_, _) => keyboardNavigating = false;
        PreviewMouseWheel += ForwardWheelFromCarousels;
        SizeChanged += (_, _) => Relayout();
        Loaded += OnLoaded;
    }

    private async void OnLoaded(object sender, RoutedEventArgs e)
    {
        Relayout();
        vm.Start();
        try
        {
            await engine.StartAsync(vm.AudioOnly, Environment.GetEnvironmentVariable("CADENZA_HOME"));
        }
        catch (Exception ex)
        {
            // Most likely the WebView2 runtime is missing (it ships with Windows 11 and Edge).
            MessageBox.Show(this,
                "Cadenza needs the Microsoft Edge WebView2 Runtime, which could not be started.\n\n" + ex.Message +
                "\n\nInstall it from https://go.microsoft.com/fwlink/p/?LinkId=2124703 and open Cadenza again.",
                "Cadenza", MessageBoxButton.OK, MessageBoxImage.Error);
            Close();
            return;
        }
        if (Environment.GetEnvironmentVariable("CADENZA_SELFTEST") is { Length: > 0 } log)
            _ = SelfTest.RunAsync(this, vm, log);
    }

    // MARK: Layout

    /// <summary>Folds the sidebar, then the lyrics column, away as the window narrows.</summary>
    private void Relayout()
    {
        var width = ActualWidth;
        Sidebar.Visibility = width >= 860 ? Visibility.Visible : Visibility.Collapsed;
        LyricsPanel.Visibility = vm.ShowLyrics && width >= 720 ? Visibility.Visible : Visibility.Collapsed;
        if (vm.ShowLyrics) LyricsButton.Foreground = (Brush)FindResource("Accent");
        else LyricsButton.ClearValue(ForegroundProperty);
        FormatBadge.Opacity = width >= 960 ? 1 : 0;
    }

    private void OnModelChanged(object? sender, PropertyChangedEventArgs e)
    {
        switch (e.PropertyName)
        {
            case nameof(AppViewModel.ShowLyrics): Relayout(); break;
            case nameof(AppViewModel.Page): MainScroll.ScrollToTop(); break;
            case nameof(AppViewModel.Volume):
                settingSlider = true;
                VolumeSlider.Value = vm.Volume;
                settingSlider = false;
                UpdateVolumeIcon();
                break;
        }
    }

    // MARK: Scrubber

    private void OnNowChanged(object? sender, PropertyChangedEventArgs e)
    {
        if (e.PropertyName == nameof(NowPlaying.Duration))
        {
            settingSlider = true;
            Scrubber.Maximum = Math.Max(vm.Now.Duration, 1);
            settingSlider = false;
        }
    }

    private void OnTime(double t)
    {
        if (vm.Scrubbing) return;
        settingSlider = true;
        Scrubber.Value = Math.Min(t, Scrubber.Maximum);
        settingSlider = false;
        ElapsedText.Text = Stamp(t);
    }

    private void OnScrubberChanged(object sender, RoutedPropertyChangedEventArgs<double> e)
    {
        ElapsedText.Text = Stamp(e.NewValue);
        if (settingSlider || vm.Scrubbing) return;
        vm.Seek(e.NewValue); // a click on the track or the arrow keys
    }

    private static string Stamp(double t)
    {
        var s = double.IsFinite(t) && t > 0 ? (int)t : 0;
        return $"{s / 60}:{s % 60:00}";
    }

    // MARK: Volume

    private void VolumeWheel(object sender, MouseWheelEventArgs e)
    {
        vm.SetVolume(vm.Volume + (e.Delta > 0 ? 5 : -5));
        e.Handled = true;
    }

    private void UpdateVolumeIcon() =>
        VolumeIcon.Text = vm.Volume < 1 ? "" : vm.Volume < 34 ? "" : vm.Volume < 67 ? "" : "";

    // MARK: Keyboard

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (vm.WebMode) return;
        var mods = Keyboard.Modifiers;
        if (e.Key == Key.Tab) keyboardNavigating = true;

        if (mods == ModifierKeys.Control && e.Key == Key.F) { SearchBox.Focus(); SearchBox.SelectAll(); e.Handled = true; return; }
        if (mods == ModifierKeys.Control && (e.Key == Key.Up || e.Key == Key.Down))
        {
            vm.SetVolume(vm.Volume + (e.Key == Key.Up ? 10 : -10));
            e.Handled = true;
            return;
        }
        // Space plays/pauses unless something that uses Space has keyboard focus.
        if (e.Key == Key.Space && mods == ModifierKeys.None && SpacePlays())
        {
            vm.PlayPause();
            e.Handled = true;
        }
    }

    private bool SpacePlays() => Keyboard.FocusedElement switch
    {
        TextBoxBase or RangeBase or ComboBox => false,
        // A button reached with Tab gets Space; one that only took focus from a click does not.
        ButtonBase => !keyboardNavigating,
        _ => true,
    };

    private void SearchBox_KeyDown(object sender, KeyEventArgs e)
    {
        if (e.Key == Key.Enter) { vm.SubmitSearch(); e.Handled = true; }
        else if (e.Key == Key.Escape) { vm.SearchText = ""; MainScroll.Focus(); e.Handled = true; }
    }

    /// <summary>Wheel over a horizontal shelf scrolls the page, as it does in Music; Shift+wheel scrolls the shelf.</summary>
    private void ForwardWheelFromCarousels(object sender, MouseWheelEventArgs e)
    {
        if (Keyboard.Modifiers == ModifierKeys.Shift) return;
        for (var d = e.OriginalSource as DependencyObject; d != null; d = VisualTreeHelper.GetParent(d))
        {
            if (d is ScrollViewer { Tag: "carousel" })
            {
                MainScroll.ScrollToVerticalOffset(MainScroll.VerticalOffset - e.Delta);
                e.Handled = true;
                return;
            }
            if (d == MainScroll) return;
        }
    }

    // MARK: Lyrics

    private DispatcherTimer? lyricsAnimation;

    /// <summary>Keeps the current line in the middle of the lyrics column.</summary>
    private void ScrollLyrics(LyricLine line)
    {
        if (LyricLines.ItemContainerGenerator.ContainerFromItem(line) is not FrameworkElement row || !row.IsVisible) return;
        var y = row.TranslatePoint(new Point(0, 0), LyricLines).Y + LyricLines.Margin.Top;
        var target = Math.Max(0, y - (LyricsScroll.ViewportHeight - row.ActualHeight) / 2);
        var start = LyricsScroll.VerticalOffset;
        lyricsAnimation?.Stop();
        if (!SystemParameters.ClientAreaAnimation) { LyricsScroll.ScrollToVerticalOffset(target); return; } // animations off
        var began = DateTime.UtcNow;
        lyricsAnimation = new DispatcherTimer(DispatcherPriority.Render) { Interval = TimeSpan.FromMilliseconds(15) };
        lyricsAnimation.Tick += (_, _) =>
        {
            var p = Math.Min(1, (DateTime.UtcNow - began).TotalMilliseconds / 350);
            var eased = p < 0.5 ? 2 * p * p : 1 - Math.Pow(-2 * p + 2, 2) / 2;
            LyricsScroll.ScrollToVerticalOffset(start + (target - start) * eased);
            if (p >= 1) lyricsAnimation?.Stop();
        };
        lyricsAnimation.Start();
    }
}

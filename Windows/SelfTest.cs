using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;

namespace Cadenza;

/// <summary>
/// Automated check used by CI (set CADENZA_SELFTEST to a log path): waits for the player, loads
/// Home, plays two songs in quick succession, shows lyrics, takes screenshots of the interface
/// and quits. Does nothing in normal use.
/// </summary>
internal static class SelfTest
{
    public static async Task RunAsync(MainWindow window, AppViewModel vm, string logPath)
    {
        var log = new List<string>();
        void Note(string line)
        {
            log.Add($"{DateTime.Now:HH:mm:ss} {line}");
            try { File.WriteAllLines(logPath, log); } catch { }
        }
        string State() =>
            $"ready={vm.Ready} loggedIn={vm.LoggedIn} loading={vm.Loading} sections={vm.Page?.Sections.Count ?? -1} " +
            $"error={vm.Error ?? "none"} now={vm.Now.Id}|{vm.Now.Title}|playing={vm.Now.Playing} t={vm.Time:0.0} " +
            $"format={vm.Now.Format} lyrics={vm.Lyrics.Status}";

        try
        {
            for (var i = 0; i < 60 && vm.Page == null && vm.Error == null; i++)
            {
                await Task.Delay(1000);
                Note($"wait {i} {State()}");
            }
            Note("home " + State());
            Snapshot(window, logPath, "home");
            var ids = vm.Page?.Sections.SelectMany(s => s.Items).Select(x => x.VideoId).OfType<string>().Distinct().ToList() ?? new();
            if (ids.Count < 2) { Note("FAIL no songs on Home"); return; }

            Note($"play {ids[0]} then {ids[1]} one second later");
            vm.Play(ids[0], null);
            await Task.Delay(1000);
            vm.Play(ids[1], null);
            for (var i = 0; i < 12; i++) { await Task.Delay(1000); Note($"after {i} {State()}"); }
            Note(vm.Now.Id == ids[1] ? "PASS rapid play stayed on the second song" : $"FAIL now playing {vm.Now.Id}");
            Note(vm.Time > 1 ? "PASS playback time is advancing" : "FAIL playback time not advancing");

            vm.ShowLyrics = true;
            for (var i = 0; i < 10 && vm.Lyrics.Status is LyricsStatus.Loading or LyricsStatus.Idle; i++) await Task.Delay(1000);
            Note("lyrics " + vm.Lyrics.Status);
            vm.SetVolume(40);
            await Task.Delay(2000);
            Note($"volume set 40 → model {vm.Volume}");
            Snapshot(window, logPath, "playing");

            vm.SearchText = "lofi";
            vm.SubmitSearch();
            for (var i = 0; i < 20 && (vm.Loading || vm.Page == null); i++) await Task.Delay(500);
            Note("search " + State());
            Snapshot(window, logPath, "search");
            vm.PlayPause();
            Note("DONE");
        }
        catch (Exception e) { Note("FAIL exception " + e); }
        finally
        {
            await Task.Delay(500);
            Application.Current.Shutdown();
        }
    }

    private static void Snapshot(Window window, string logPath, string name)
    {
        try
        {
            if (window.Content is not FrameworkElement root) return;
            var dpi = VisualTreeHelper.GetDpi(window);
            var bitmap = new RenderTargetBitmap(
                (int)(root.ActualWidth * dpi.DpiScaleX), (int)(root.ActualHeight * dpi.DpiScaleY),
                dpi.PixelsPerInchX, dpi.PixelsPerInchY, PixelFormats.Pbgra32);
            // Paint the window background first; the theme's backdrop is not part of the visual tree.
            var visual = new DrawingVisual();
            using (var dc = visual.RenderOpen())
            {
                dc.DrawRectangle(window.Background ?? Brushes.White, null, new Rect(0, 0, root.ActualWidth, root.ActualHeight));
                dc.DrawRectangle(new VisualBrush(root), null, new Rect(0, 0, root.ActualWidth, root.ActualHeight));
            }
            bitmap.Render(visual);
            var encoder = new PngBitmapEncoder();
            encoder.Frames.Add(BitmapFrame.Create(bitmap));
            using var file = File.Create(Path.ChangeExtension(logPath, null) + $"-{name}.png");
            encoder.Save(file);
        }
        catch { }
    }
}

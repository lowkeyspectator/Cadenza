using System.IO;
using System.Windows;
using System.Windows.Threading;

namespace Cadenza;

public partial class App : Application
{
    public static string DataFolder { get; } = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Cadenza");

    protected override void OnStartup(StartupEventArgs e)
    {
        Directory.CreateDirectory(DataFolder);
        DispatcherUnhandledException += OnUnhandled;
        base.OnStartup(e);
    }

    // Log and keep running rather than vanish: most failures here are a page the bridge
    // could not read, which the user can recover from by navigating elsewhere.
    private void OnUnhandled(object sender, DispatcherUnhandledExceptionEventArgs e)
    {
        try { File.AppendAllText(Path.Combine(DataFolder, "errors.log"), $"{DateTime.Now:u} {e.Exception}\n\n"); }
        catch { }
        e.Handled = true;
    }
}

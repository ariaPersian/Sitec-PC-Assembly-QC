using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Linq;
using System.Reflection;
using System.Security.Principal;
using System.Windows.Forms;

namespace SitecQC.Launcher;

internal static class Program
{
    private const string AppVersion = "3.0.0";
    private const string PayloadResource = "SitecQC.Payload.zip";

    [STAThread]
    private static int Main()
    {
        try
        {
            if (!IsAdministrator())
            {
                RelaunchElevated();
                return 0;
            }

            var appRoot = EnsurePayloadExtracted();
            var script = Path.Combine(appRoot, "Start-SitecQC.ps1");
            if (!File.Exists(script))
                throw new FileNotFoundException("The embedded SITEC QC application payload is incomplete.", script);

            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = $"-NoProfile -ExecutionPolicy Bypass -File \"{script}\"",
                WorkingDirectory = appRoot,
                UseShellExecute = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };

            Process.Start(psi);
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "SITEC PC Assembly & QC", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
    }

    private static bool IsAdministrator()
    {
        using var identity = WindowsIdentity.GetCurrent();
        return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
    }

    private static void RelaunchElevated()
    {
        var exe = Environment.ProcessPath ?? Process.GetCurrentProcess().MainModule?.FileName
                  ?? throw new InvalidOperationException("Unable to determine launcher path.");
        Process.Start(new ProcessStartInfo
        {
            FileName = exe,
            UseShellExecute = true,
            Verb = "runas"
        });
    }

    private static string EnsurePayloadExtracted()
    {
        var baseRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), "SitecQC", "App");
        var appRoot = Path.Combine(baseRoot, AppVersion);
        var marker = Path.Combine(appRoot, ".payload-ready");
        if (File.Exists(marker))
            return appRoot;

        Directory.CreateDirectory(baseRoot);
        var assembly = Assembly.GetExecutingAssembly();
        var resourceName = assembly.GetManifestResourceNames().FirstOrDefault(n => string.Equals(n, PayloadResource, StringComparison.OrdinalIgnoreCase));
        if (resourceName is null)
            throw new InvalidOperationException("This SitecQC.exe build does not contain the embedded application payload.");

        var tempZip = Path.Combine(Path.GetTempPath(), $"SitecQC-{Guid.NewGuid():N}.zip");
        try
        {
            using (var input = assembly.GetManifestResourceStream(resourceName) ?? throw new InvalidOperationException("Unable to open embedded payload."))
            using (var output = File.Create(tempZip))
                input.CopyTo(output);

            if (Directory.Exists(appRoot))
                Directory.Delete(appRoot, true);
            Directory.CreateDirectory(appRoot);
            ZipFile.ExtractToDirectory(tempZip, appRoot);
            File.WriteAllText(marker, AppVersion);
            return appRoot;
        }
        finally
        {
            try { if (File.Exists(tempZip)) File.Delete(tempZip); } catch { }
        }
    }
}

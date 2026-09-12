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
    private const string AppVersion = "3.9.0";
    private const string PayloadResource = "SitecQC.Payload.zip";

    [STAThread]
    private static int Main()
    {
        string? appRoot = null;
        try
        {
            if (!IsAdministrator())
            {
                RelaunchElevated();
                return 0;
            }

            var exe = Environment.ProcessPath ?? Process.GetCurrentProcess().MainModule?.FileName
                      ?? throw new InvalidOperationException("Unable to determine launcher path.");
            var launcherDir = Path.GetDirectoryName(exe) ?? Environment.CurrentDirectory;

            appRoot = ExtractPayloadToTemporaryFolder();
            var script = Path.Combine(appRoot, "Start-SitecQC.ps1");
            if (!File.Exists(script))
                throw new FileNotFoundException("The embedded SITEC QC application payload is incomplete.", script);

            var psi = new ProcessStartInfo
            {
                FileName = "powershell.exe",
                Arguments = $"-NoProfile -STA -ExecutionPolicy Bypass -File \"{script}\" -LauncherDir \"{launcherDir.Replace("\"", "\\\"")}\"",
                WorkingDirectory = appRoot,
                UseShellExecute = false,
                CreateNoWindow = true,
                WindowStyle = ProcessWindowStyle.Hidden
            };

            using var child = Process.Start(psi) ?? throw new InvalidOperationException("Unable to start the SITEC QC application.");
            child.WaitForExit();
            return child.ExitCode;
        }
        catch (Exception ex)
        {
            MessageBox.Show(ex.Message, "SITEC PC Assembly & QC", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        finally
        {
            if (!string.IsNullOrWhiteSpace(appRoot))
            {
                try { if (Directory.Exists(appRoot)) Directory.Delete(appRoot, true); } catch { }
            }
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

    private static string ExtractPayloadToTemporaryFolder()
    {
        var appRoot = Path.Combine(Path.GetTempPath(), $"SitecQC-App-{AppVersion}-{Guid.NewGuid():N}");
        Directory.CreateDirectory(appRoot);

        var assembly = Assembly.GetExecutingAssembly();
        var resourceName = assembly.GetManifestResourceNames().FirstOrDefault(n => string.Equals(n, PayloadResource, StringComparison.OrdinalIgnoreCase));
        if (resourceName is null)
            throw new InvalidOperationException("This SitecQC.exe build does not contain the embedded application payload.");

        var tempZip = Path.Combine(Path.GetTempPath(), $"SitecQC-Payload-{Guid.NewGuid():N}.zip");
        try
        {
            using (var input = assembly.GetManifestResourceStream(resourceName) ?? throw new InvalidOperationException("Unable to open embedded payload."))
            using (var output = File.Create(tempZip))
                input.CopyTo(output);

            ZipFile.ExtractToDirectory(tempZip, appRoot);
            return appRoot;
        }
        catch
        {
            try { if (Directory.Exists(appRoot)) Directory.Delete(appRoot, true); } catch { }
            throw;
        }
        finally
        {
            try { if (File.Exists(tempZip)) File.Delete(tempZip); } catch { }
        }
    }
}

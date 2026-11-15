using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;

internal static class SkillDockLauncher
{
    private const string ProductName = "SkillDock";
    private const string DriverName = "dsh-web";

    [STAThread]
    private static int Main(string[] args)
    {
        bool silent = HasArgument(args, "--silent");
        try
        {
            if (HasArgument(args, "--stop"))
            {
                return StopServer(silent);
            }
            return StartServer(silent, HasArgument(args, "--no-browser"));
        }
        catch (Exception error)
        {
            WriteLauncherLog(error.ToString());
            if (!silent)
            {
                MessageBox.Show(
                    error.Message + "\r\n\r\nLauncher log:\r\n" + LauncherLogPath,
                    ProductName + " could not start",
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Error
                );
            }
            return 1;
        }
    }

    private static int StartServer(bool silent, bool noBrowser)
    {
        string baseDirectory = AppDomain.CurrentDomain.BaseDirectory;
        string appDirectory = Path.Combine(baseDirectory, "app");
        string nodePath = Path.Combine(baseDirectory, "node", "node.exe");
        string serverPath = Path.Combine(appDirectory, "server.mjs");
        string dshHome = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".dsh"
        );
        string dshExecutable = @"C:\dsh\DeepSeek Harness.exe";
        string codexSkills = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".codex",
            "skills"
        );
        string dshSkills = Path.Combine(dshHome, "skills");
        string runtimeDirectory = Path.Combine(LocalRoot, "runtime-dsh-web");

        RequireFile(nodePath, "Bundled Node runtime is missing");
        RequireFile(serverPath, "SkillDock application files are missing");
        RequireFile(dshExecutable, "DeepSeek Harness was not found at C:\\dsh");
        RequireDirectory(dshHome, "The DSH home directory was not found");

        Directory.CreateDirectory(LocalRoot);
        Directory.CreateDirectory(runtimeDirectory);

        int port = FindFreePort();
        string url = "http://127.0.0.1:" + port + "/";
        ProcessStartInfo startInfo = new ProcessStartInfo();
        startInfo.FileName = nodePath;
        startInfo.Arguments = Quote(serverPath);
        startInfo.WorkingDirectory = appDirectory;
        startInfo.UseShellExecute = false;
        startInfo.CreateNoWindow = true;
        startInfo.WindowStyle = ProcessWindowStyle.Hidden;
        startInfo.EnvironmentVariables["PANEL_PORT"] = port.ToString();
        startInfo.EnvironmentVariables["PANEL_RUNTIME_DIR"] = runtimeDirectory;
        startInfo.EnvironmentVariables["PANEL_AGENT_DRIVER"] = DriverName;
        startInfo.EnvironmentVariables["PANEL_SKILL_ROOTS"] = codexSkills + ";" + dshSkills;
        startInfo.EnvironmentVariables["PANEL_SKILL_ID"] = "pc-hardware-workbench";
        startInfo.EnvironmentVariables["DSH_HOME"] = dshHome;
        startInfo.EnvironmentVariables["DSH_TELEMETRY_DISABLED"] = "1";
        startInfo.EnvironmentVariables["NODE_NO_WARNINGS"] = "1";

        WriteLauncherLog(
            "Starting " + ProductName + " with " + DriverName + " on " + url
        );
        Process process = Process.Start(startInfo);
        if (process == null)
        {
            throw new InvalidOperationException("The SkillDock server process did not start.");
        }

        bool ready = false;
        for (int attempt = 0; attempt < 160; attempt++)
        {
            if (process.HasExited)
            {
                throw new InvalidOperationException(
                    "The SkillDock server exited before it became ready (code " +
                    process.ExitCode + ")."
                );
            }
            if (IsHealthy(port))
            {
                ready = true;
                break;
            }
            Thread.Sleep(250);
        }
        process.Dispose();

        if (!ready)
        {
            throw new TimeoutException(
                "The SkillDock server did not become ready within 40 seconds."
            );
        }

        WriteLauncherLog("Ready: " + url);
        if (!noBrowser)
        {
            ProcessStartInfo browser = new ProcessStartInfo();
            browser.FileName = url;
            browser.UseShellExecute = true;
            Process.Start(browser);
        }
        if (!silent)
        {
            MessageBox.Show(
                ProductName + " is running.\r\n\r\n" + url,
                ProductName,
                MessageBoxButtons.OK,
                MessageBoxIcon.Information
            );
        }
        return 0;
    }

    private static int StopServer(bool silent)
    {
        string infoPath = Path.Combine(LocalRoot, "runtime-dsh-web", "server-info.json");
        string tokenPath = Path.Combine(
            LocalRoot,
            "runtime-dsh-web",
            "capability-token"
        );
        if (!File.Exists(infoPath) || !File.Exists(tokenPath))
        {
            if (!silent)
            {
                MessageBox.Show(
                    ProductName + " is not running.",
                    ProductName,
                    MessageBoxButtons.OK,
                    MessageBoxIcon.Information
                );
            }
            return 0;
        }

        string info = File.ReadAllText(infoPath);
        Match portMatch = Regex.Match(info, "\"port\"\\s*:\\s*(\\d+)");
        if (!portMatch.Success)
        {
            throw new InvalidOperationException("The server port is unavailable.");
        }
        int port = Int32.Parse(portMatch.Groups[1].Value);
        string token = File.ReadAllText(tokenPath).Trim();
        HttpWebRequest request = (HttpWebRequest)WebRequest.Create(
            "http://127.0.0.1:" + port + "/api/shutdown"
        );
        request.Method = "POST";
        request.ContentType = "application/json";
        request.Headers["Authorization"] = "Bearer " + token;
        byte[] body = Encoding.UTF8.GetBytes("{}");
        request.ContentLength = body.Length;
        using (Stream requestStream = request.GetRequestStream())
        {
            requestStream.Write(body, 0, body.Length);
        }
        using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
        {
            if ((int)response.StatusCode < 200 || (int)response.StatusCode >= 300)
            {
                throw new InvalidOperationException(
                    "The server rejected the shutdown request."
                );
            }
        }
        WriteLauncherLog("Stopped.");
        if (!silent)
        {
            MessageBox.Show(
                ProductName + " was stopped.",
                ProductName,
                MessageBoxButtons.OK,
                MessageBoxIcon.Information
            );
        }
        return 0;
    }

    private static bool IsHealthy(int port)
    {
        try
        {
            HttpWebRequest request = (HttpWebRequest)WebRequest.Create(
                "http://127.0.0.1:" + port + "/api/health"
            );
            request.Timeout = 1000;
            request.ReadWriteTimeout = 1000;
            using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
            using (StreamReader reader = new StreamReader(response.GetResponseStream()))
            {
                string body = reader.ReadToEnd();
                return response.StatusCode == HttpStatusCode.OK &&
                    body.IndexOf("\"ok\":true", StringComparison.OrdinalIgnoreCase) >= 0;
            }
        }
        catch
        {
            return false;
        }
    }

    private static int FindFreePort()
    {
        TcpListener listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        int port = ((IPEndPoint)listener.LocalEndpoint).Port;
        listener.Stop();
        return port;
    }

    private static void RequireFile(string path, string message)
    {
        if (!File.Exists(path))
        {
            throw new FileNotFoundException(message + ": " + path, path);
        }
    }

    private static void RequireDirectory(string path, string message)
    {
        if (!Directory.Exists(path))
        {
            throw new DirectoryNotFoundException(message + ": " + path);
        }
    }

    private static string Quote(string value)
    {
        return "\"" + value.Replace("\"", "\\\"") + "\"";
    }

    private static bool HasArgument(string[] args, string expected)
    {
        foreach (string argument in args)
        {
            if (String.Equals(argument, expected, StringComparison.OrdinalIgnoreCase))
            {
                return true;
            }
        }
        return false;
    }

    private static string LocalRoot
    {
        get
        {
            return Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
                ProductName
            );
        }
    }

    private static string LauncherLogPath
    {
        get
        {
            return Path.Combine(LocalRoot, "launcher.log");
        }
    }

    private static void WriteLauncherLog(string message)
    {
        try
        {
            Directory.CreateDirectory(LocalRoot);
            File.AppendAllText(
                LauncherLogPath,
                DateTimeOffset.Now.ToString("o") + " " + message + "\r\n",
                Encoding.UTF8
            );
        }
        catch
        {
            // A read-only portable folder must not prevent startup.
        }
    }
}

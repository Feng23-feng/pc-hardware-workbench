using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;
using System.Web.Script.Serialization;

internal static class SkillDockLauncher
{
    private const string ProductName = "SkillDock";
    private static string DriverName
    {
        get
        {
            return "source-external";
        }
    }

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
            return StartServer(silent, HasArgument(args, "--no-browser"), args);
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

    private static int StartServer(bool silent, bool noBrowser, string[] args)
    {
        string baseDirectory = AppDomain.CurrentDomain.BaseDirectory;
        string appDirectory = Path.Combine(baseDirectory, "app");
        string nodePath = Path.Combine(baseDirectory, "node", "node.exe");
        string serverPath = Path.Combine(appDirectory, "server.mjs");
        string requestedWorkspace = ArgumentValue(args, "--workspace");
        string workspace = ResolveWorkspace(requestedWorkspace);
        string codexSkills = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".codex",
            "skills"
        );
        string skillRoots = codexSkills;
        string runtimeDirectory = Path.Combine(LocalRoot, "runtime-pchw");
        bool replaceWorkspace = HasArgument(args, "--replace-workspace");

        RequireFile(nodePath, "Bundled Node runtime is missing");
        RequireFile(serverPath, "SkillDock application files are missing");

        Directory.CreateDirectory(LocalRoot);
        Directory.CreateDirectory(runtimeDirectory);

        ServerInfo existing;
        if (TryGetHealthyServer(out existing))
        {
            if (!String.Equals(
                Path.GetFullPath(existing.workspace),
                Path.GetFullPath(workspace),
                StringComparison.OrdinalIgnoreCase
            ))
            {
                if (!replaceWorkspace)
                {
                    throw new InvalidOperationException(
                        "SkillDock is already running for a different workspace. " +
                        "Keep that runtime, or repeat the launch with an explicit " +
                        "workspace replacement decision."
                    );
                }
                WriteLauncherLog(
                    "Switching workspace from " + existing.workspace +
                    " to " + workspace
                );
                StopServer(true);
                for (int attempt = 0; attempt < 40 && IsHealthy(existing.port); attempt++)
                {
                    Thread.Sleep(100);
                }
                if (IsHealthy(existing.port))
                {
                    throw new InvalidOperationException(
                        "The previous SkillDock workspace could not be stopped."
                    );
                }
            }
            else
            {
                WriteLaunchResult(existing);
                if (!noBrowser)
                {
                    OpenBrowser(existing);
                }
                if (!silent)
                {
                    MessageBox.Show(
                        ProductName + " is already running.\r\n\r\n" + existing.url,
                        ProductName,
                        MessageBoxButtons.OK,
                        MessageBoxIcon.Information
                    );
                }
                return 0;
            }
        }

        int port = FindFreePort();
        string url = "http://127.0.0.1:" + port + "/";
        string launchId = Guid.NewGuid().ToString("D");
        ProcessStartInfo startInfo = new ProcessStartInfo();
        startInfo.FileName = nodePath;
        startInfo.Arguments = Quote(serverPath);
        startInfo.WorkingDirectory = appDirectory;
        startInfo.UseShellExecute = false;
        startInfo.CreateNoWindow = true;
        startInfo.WindowStyle = ProcessWindowStyle.Hidden;
        startInfo.EnvironmentVariables["PANEL_PORT"] = port.ToString();
        startInfo.EnvironmentVariables["PANEL_LAUNCH_ID"] = launchId;
        startInfo.EnvironmentVariables["PANEL_RUNTIME_DIR"] = runtimeDirectory;
        startInfo.EnvironmentVariables["PANEL_AGENT_DRIVER"] = DriverName;
        startInfo.EnvironmentVariables["PANEL_SKILL_ROOTS"] = skillRoots;
        startInfo.EnvironmentVariables["PANEL_SKILL_ID"] = "pc-hardware-workbench";
        startInfo.EnvironmentVariables["PANEL_AGENT_WORKSPACE"] = workspace;
        startInfo.EnvironmentVariables["PANEL_SURFACE_MODE"] = "read-only";
        startInfo.EnvironmentVariables["PANEL_AGENT_SANDBOX"] = "read-only";
        startInfo.EnvironmentVariables["PANEL_AGENT_APPROVAL_POLICY"] = "never";
        startInfo.EnvironmentVariables["PANEL_SOURCE_HOSTED_ENTRY"] = "1";
        startInfo.EnvironmentVariables["PANEL_SOURCE_HOSTED_NON_MOCK"] = "1";
        startInfo.EnvironmentVariables["NODE_NO_WARNINGS"] = "1";

        WriteLauncherLog(
            "Starting " + ProductName + " with " + DriverName + " on " + url +
            " workspace=" + workspace
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
        int processId = process.Id;
        process.Dispose();

        if (!ready)
        {
            throw new TimeoutException(
                "The SkillDock server did not become ready within 40 seconds."
            );
        }

        WriteLauncherLog("Ready: " + url);
        ServerInfo started = new ServerInfo
        {
            ok = true,
            url = url,
            port = port,
            driver = DriverName,
            workspace = workspace,
            pid = processId,
            launch_id = launchId,
            origin = "http://127.0.0.1:" + port,
            exact_url = BuildExactUrl(url, launchId, processId, port)
        };
        WriteLaunchResult(started);
        if (!noBrowser)
        {
            OpenBrowser(started);
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
        string tokenPath = Path.Combine(
            LocalRoot,
            "runtime-pchw",
            "capability-token"
        );
        ServerInfo running;
        if (!TryGetHealthyServer(out running) || !File.Exists(tokenPath))
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
        int port = running.port;
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

    private static string BuildExactUrl(
        string url,
        string launchId,
        int pid,
        int port
    )
    {
        return url.TrimEnd('/') +
            "/?runtime_launch_id=" + Uri.EscapeDataString(launchId) +
            "&runtime_pid=" + pid +
            "&runtime_port=" + port;
    }

    private static string ResolveEdgeExecutable()
    {
        string[] candidates = new string[]
        {
            Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86),
                "Microsoft",
                "Edge",
                "Application",
                "msedge.exe"
            ),
            Path.Combine(
                Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles),
                "Microsoft",
                "Edge",
                "Application",
                "msedge.exe"
            )
        };
        foreach (string candidate in candidates)
        {
            if (File.Exists(candidate))
            {
                return candidate;
            }
        }
        return "";
    }

    private static void OpenBrowser(ServerInfo info)
    {
        string exactUrl = info.exact_url;
        if (String.IsNullOrWhiteSpace(exactUrl))
        {
            exactUrl = BuildExactUrl(info.url, info.launch_id, info.pid, info.port);
        }
        string edge = ResolveEdgeExecutable();
        ProcessStartInfo browser = new ProcessStartInfo();
        if (!String.IsNullOrWhiteSpace(edge))
        {
            browser.FileName = edge;
            browser.Arguments = "--new-window " + Quote(exactUrl);
            browser.UseShellExecute = false;
        }
        else
        {
            browser.FileName = exactUrl;
            browser.UseShellExecute = true;
        }
        Process.Start(browser);
    }

    private static bool TryGetHealthyServer(out ServerInfo info)
    {
        info = null;
        string infoPath = Path.Combine(LocalRoot, "launch-result.json");
        if (!File.Exists(infoPath))
        {
            return false;
        }
        try
        {
            string json = File.ReadAllText(infoPath);
            JavaScriptSerializer serializer = new JavaScriptSerializer();
            ServerInfo candidate = serializer.Deserialize<ServerInfo>(json);
            if (
                candidate == null ||
                !candidate.ok ||
                candidate.port <= 0 ||
                candidate.pid <= 0 ||
                String.IsNullOrWhiteSpace(candidate.workspace) ||
                String.IsNullOrWhiteSpace(candidate.launch_id)
            )
            {
                return false;
            }
            int bindingPid;
            int bindingPort;
            string bindingLaunchId;
            string bindingOrigin;
            if (!TryGetHealthBinding(
                candidate.port,
                out bindingPid,
                out bindingPort,
                out bindingLaunchId,
                out bindingOrigin
            ))
            {
                return false;
            }
            string candidateOrigin =
                "http://127.0.0.1:" + candidate.port;
            if (
                bindingPid != candidate.pid ||
                bindingPort != candidate.port ||
                bindingLaunchId != candidate.launch_id ||
                bindingOrigin != candidateOrigin
            )
            {
                return false;
            }
            info = new ServerInfo
            {
                ok = true,
                url = candidateOrigin + "/",
                port = candidate.port,
                driver = DriverName,
                workspace = candidate.workspace,
                pid = candidate.pid,
                launch_id = candidate.launch_id,
                origin = candidateOrigin,
                exact_url = BuildExactUrl(
                    candidateOrigin + "/",
                    candidate.launch_id,
                    candidate.pid,
                    candidate.port
                )
            };
            return true;
        }
        catch
        {
            return false;
        }
    }

    private static bool TryGetHealthBinding(
        int port,
        out int pid,
        out int bindingPort,
        out string launchId,
        out string origin
    )
    {
        pid = 0;
        bindingPort = 0;
        launchId = "";
        origin = "";
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
                if (response.StatusCode != HttpStatusCode.OK)
                {
                    return false;
                }
                JavaScriptSerializer serializer = new JavaScriptSerializer();
                Dictionary<string, object> payload =
                    serializer.DeserializeObject(reader.ReadToEnd())
                    as Dictionary<string, object>;
                object okValue;
                object bindingValue;
                if (
                    payload == null ||
                    !payload.TryGetValue("ok", out okValue) ||
                    !Convert.ToBoolean(okValue) ||
                    !payload.TryGetValue("runtime_binding", out bindingValue)
                )
                {
                    return false;
                }
                Dictionary<string, object> binding =
                    bindingValue as Dictionary<string, object>;
                if (binding == null)
                {
                    return false;
                }
                pid = Convert.ToInt32(binding["pid"]);
                bindingPort = Convert.ToInt32(binding["port"]);
                launchId = Convert.ToString(binding["launch_id"]);
                origin = Convert.ToString(binding["origin"]).TrimEnd('/');
                return (
                    pid > 0 &&
                    bindingPort == port &&
                    !String.IsNullOrWhiteSpace(launchId) &&
                    !String.IsNullOrWhiteSpace(origin)
                );
            }
        }
        catch
        {
            return false;
        }
    }

    private static void WriteLaunchResult(ServerInfo info)
    {
        Directory.CreateDirectory(LocalRoot);
        string resultPath = Path.Combine(LocalRoot, "launch-result.json");
        string temporaryPath = resultPath + "." +
            Guid.NewGuid().ToString("N") + ".tmp";
        File.WriteAllText(
            temporaryPath,
            new JavaScriptSerializer().Serialize(info) + "\r\n",
            Encoding.UTF8
        );
        try
        {
            if (File.Exists(resultPath))
            {
                File.Replace(temporaryPath, resultPath, null);
            }
            else
            {
                File.Move(temporaryPath, resultPath);
            }
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
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

    private static string ArgumentValue(string[] args, string expected)
    {
        for (int index = 0; index < args.Length - 1; index++)
        {
            if (String.Equals(args[index], expected, StringComparison.OrdinalIgnoreCase))
            {
                return args[index + 1];
            }
        }
        return "";
    }

    private static string ResolveWorkspace(string requested)
    {
        string userProfile = Environment.GetFolderPath(
            Environment.SpecialFolder.UserProfile
        );
        string workspace = requested;
        if (String.IsNullOrWhiteSpace(workspace))
        {
            string codexWorkspace = Path.Combine(userProfile, "Documents", "Codex");
            workspace = Directory.Exists(codexWorkspace) ? codexWorkspace : userProfile;
        }
        workspace = Path.GetFullPath(workspace);
        RequireDirectory(workspace, "The requested Agent workspace was not found");
        return workspace;
    }

    private static string LocalRoot
    {
        get
        {
            string configured = Environment.GetEnvironmentVariable(
                "SKILLDOCK_LOCAL_ROOT"
            );
            if (!String.IsNullOrWhiteSpace(configured))
            {
                return Path.GetFullPath(configured);
            }
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

    private sealed class ServerInfo
    {
        public bool ok;
        public string url;
        public int port;
        public string driver;
        public string workspace;
        public int pid;
        public string launch_id;
        public string origin;
        public string exact_url;
    }
}

using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading;
using System.Windows.Forms;
using System.Web.Script.Serialization;

internal static class SkillDockLauncher
{
    private const string ProductName = "SkillDock";
    private const string ExpectedSkillId = "pc-hardware-workbench";
    private const string ExpectedSurfaceContract = "pchw-source-hosted";
    private static string failureCode = "launcher_start_failed";
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
            if (error is LaunchFailureException)
            {
                failureCode = ((LaunchFailureException)error).Code;
            }
            else if (
                error is UnauthorizedAccessException ||
                error is DirectoryNotFoundException ||
                error is FileNotFoundException
            )
            {
                failureCode = "runtime_access_blocked";
            }
            TryWriteLaunchFailure(failureCode, error.Message);
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
        string nodePath = ResolveNodePath(baseDirectory);
        string serverPath = Path.Combine(appDirectory, "server.mjs");
        string requestedWorkspace = ArgumentValue(args, "--workspace");
        string workspace = ResolveWorkspace(requestedWorkspace);
        string codexSkills = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
            ".codex",
            "skills"
        );
        string callerSkillRoots = Environment.GetEnvironmentVariable(
            "PANEL_SKILL_ROOTS"
        );
        string launcherSkillRoots = Environment.GetEnvironmentVariable(
            "SKILLDOCK_SKILL_ROOTS"
        );
        string skillRoots = callerSkillRoots != null
            ? callerSkillRoots
            : (
                launcherSkillRoots != null
                    ? launcherSkillRoots
                    : codexSkills
            );
        string callerSkillManifest = Environment.GetEnvironmentVariable(
            "PANEL_SKILL_MANIFEST"
        );
        string callerWorkbenchManifest = Environment.GetEnvironmentVariable(
            "PANEL_WORKBENCH_MANIFEST"
        );
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
                ValidateActiveSkill(existing.port, runtimeDirectory);
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
        startInfo.EnvironmentVariables["PANEL_SKILL_ID"] = ExpectedSkillId;
        if (callerSkillManifest != null)
        {
            startInfo.EnvironmentVariables["PANEL_SKILL_MANIFEST"] =
                callerSkillManifest;
        }
        if (callerWorkbenchManifest != null)
        {
            startInfo.EnvironmentVariables["PANEL_WORKBENCH_MANIFEST"] =
                callerWorkbenchManifest;
        }
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
        if (!ready)
        {
            process.Dispose();
            throw new TimeoutException(
                "The SkillDock server did not become ready within 40 seconds."
            );
        }

        try
        {
            ValidateActiveSkill(port, runtimeDirectory);
        }
        catch
        {
            StopStartedServer(process, port, runtimeDirectory);
            process.Dispose();
            throw;
        }
        int processId = process.Id;
        process.Dispose();

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

    private static string ResolveNodePath(string baseDirectory)
    {
        string legacyNodePath = Path.Combine(
            baseDirectory,
            "node",
            "node.exe"
        );
        string referencePath = Path.Combine(
            baseDirectory,
            "engine-location.json"
        );
        if (!File.Exists(referencePath))
        {
            return legacyNodePath;
        }

        string nodePath;
        string expectedSha256;
        string engineId;
        try
        {
            JavaScriptSerializer serializer = new JavaScriptSerializer();
            Dictionary<string, object> reference =
                serializer.DeserializeObject(File.ReadAllText(referencePath))
                as Dictionary<string, object>;
            if (
                reference == null ||
                !reference.ContainsKey("schema_version") ||
                !String.Equals(
                    Convert.ToString(reference["schema_version"]),
                    "1.0",
                    StringComparison.Ordinal
                )
            )
            {
                throw new InvalidOperationException(
                    "Unsupported shared Node engine reference schema."
                );
            }
            engineId = Convert.ToString(
                reference.ContainsKey("engine_id")
                    ? reference["engine_id"]
                    : null
            );
            nodePath = Convert.ToString(
                reference.ContainsKey("node_path")
                    ? reference["node_path"]
                    : null
            );
            expectedSha256 = Convert.ToString(
                reference.ContainsKey("node_sha256")
                    ? reference["node_sha256"]
                    : null
            );
        }
        catch (Exception error)
        {
            throw new LaunchFailureException(
                "shared_engine_reference_invalid",
                "Shared Node engine reference is invalid: " + error.Message
            );
        }
        if (
            String.IsNullOrWhiteSpace(engineId) ||
            String.IsNullOrWhiteSpace(nodePath) ||
            expectedSha256 == null ||
            !Regex.IsMatch(expectedSha256, "^[0-9a-f]{64}$")
        )
        {
            throw new LaunchFailureException(
                "shared_engine_reference_invalid",
                "Shared Node engine reference is incomplete: " + referencePath
            );
        }

        string engineRoot = Path.GetFullPath(
            Path.Combine(LocalRoot, "engines")
        ).TrimEnd(Path.DirectorySeparatorChar);
        string resolvedNodePath = Path.GetFullPath(nodePath);
        if (
            !resolvedNodePath.StartsWith(
                engineRoot + Path.DirectorySeparatorChar,
                StringComparison.OrdinalIgnoreCase
            )
        )
        {
            throw new LaunchFailureException(
                "shared_engine_reference_invalid",
                "Shared Node engine path escapes the engine root: " +
                resolvedNodePath
            );
        }
        if (!File.Exists(resolvedNodePath))
        {
            throw new LaunchFailureException(
                "shared_engine_unavailable",
                "Shared Node engine is missing: " + resolvedNodePath
            );
        }
        string actualSha256 = ComputeSha256(resolvedNodePath);
        if (!String.Equals(
            actualSha256,
            expectedSha256,
            StringComparison.OrdinalIgnoreCase
        ))
        {
            throw new LaunchFailureException(
                "shared_engine_hash_mismatch",
                "Shared Node engine digest does not match its reference: " +
                resolvedNodePath
            );
        }
        return resolvedNodePath;
    }

    private static string ComputeSha256(string path)
    {
        using (FileStream stream = File.OpenRead(path))
        using (SHA256 sha256 = SHA256.Create())
        {
            byte[] digest = sha256.ComputeHash(stream);
            StringBuilder text = new StringBuilder(digest.Length * 2);
            foreach (byte value in digest)
            {
                text.Append(value.ToString("x2"));
            }
            return text.ToString();
        }
    }

    private static void OpenBrowser(ServerInfo info)
    {
        string exactUrl = info.exact_url;
        if (String.IsNullOrWhiteSpace(exactUrl))
        {
            exactUrl = BuildExactUrl(info.url, info.launch_id, info.pid, info.port);
        }
        string explorerPath = Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.Windows),
            "explorer.exe"
        );
        if (!File.Exists(explorerPath))
        {
            throw new LaunchFailureException(
                "interactive_desktop_unavailable",
                "Windows Explorer is unavailable, so the interactive desktop " +
                "could not be asked to open SkillDock."
            );
        }
        ProcessStartInfo browser = new ProcessStartInfo();
        browser.FileName = explorerPath;
        browser.Arguments = Quote(exactUrl);
        browser.UseShellExecute = true;
        Process browserProcess = Process.Start(browser);
        if (browserProcess == null)
        {
            throw new LaunchFailureException(
                "interactive_desktop_unavailable",
                "Windows Shell did not accept the SkillDock URL."
            );
        }
        browserProcess.Dispose();
        WriteLauncherLog("Browser handoff: windows-shell " + exactUrl);
    }

    private static void ValidateActiveSkill(int port, string runtimeDirectory)
    {
        string tokenPath = Path.Combine(runtimeDirectory, "capability-token");
        if (!File.Exists(tokenPath))
        {
            throw new LaunchFailureException(
                "skill_runtime_mismatch",
                "SkillDock did not create the capability token required for " +
                "active-Skill validation."
            );
        }
        HttpWebRequest request = (HttpWebRequest)WebRequest.Create(
            "http://127.0.0.1:" + port + "/api/state"
        );
        request.Timeout = 5000;
        request.ReadWriteTimeout = 5000;
        request.Headers["Authorization"] =
            "Bearer " + File.ReadAllText(tokenPath).Trim();
        using (HttpWebResponse response = (HttpWebResponse)request.GetResponse())
        using (StreamReader reader = new StreamReader(response.GetResponseStream()))
        {
            if (response.StatusCode != HttpStatusCode.OK)
            {
                throw new LaunchFailureException(
                    "skill_runtime_mismatch",
                    "SkillDock rejected active-Skill validation."
                );
            }
            JavaScriptSerializer serializer = new JavaScriptSerializer();
            Dictionary<string, object> state =
                serializer.DeserializeObject(reader.ReadToEnd())
                as Dictionary<string, object>;
            Dictionary<string, object> skill = null;
            if (state != null && state.ContainsKey("skill"))
            {
                skill = state["skill"] as Dictionary<string, object>;
            }
            if (skill == null)
            {
                throw new LaunchFailureException(
                    "skill_runtime_mismatch",
                    "SkillDock state does not describe an active Skill."
                );
            }
            string skillId = Convert.ToString(skill.ContainsKey("skill_id")
                ? skill["skill_id"]
                : null);
            string skillVersion = Convert.ToString(skill.ContainsKey("skill_version")
                ? skill["skill_version"]
                : null);
            string status = Convert.ToString(skill.ContainsKey("status")
                ? skill["status"]
                : null);
            Dictionary<string, object> surfaceCompatibility = null;
            if (skill.ContainsKey("surface_compatibility"))
            {
                surfaceCompatibility =
                    skill["surface_compatibility"] as Dictionary<string, object>;
            }
            bool surfaceCompatible = false;
            string surfaceCode = "(missing)";
            string surfaceContractId = null;
            string surfaceContractVersion = null;
            string surfaceSkillVersion = null;
            string surfaceMode = null;
            if (surfaceCompatibility != null)
            {
                if (surfaceCompatibility.ContainsKey("compatible"))
                {
                    surfaceCompatible = Convert.ToBoolean(
                        surfaceCompatibility["compatible"]
                    );
                }
                surfaceCode = Convert.ToString(
                    surfaceCompatibility.ContainsKey("code")
                        ? surfaceCompatibility["code"]
                        : null
                );
                surfaceContractId = Convert.ToString(
                    surfaceCompatibility.ContainsKey("contract_id")
                        ? surfaceCompatibility["contract_id"]
                        : null
                );
                surfaceContractVersion = Convert.ToString(
                    surfaceCompatibility.ContainsKey("contract_version")
                        ? surfaceCompatibility["contract_version"]
                        : null
                );
                surfaceSkillVersion = Convert.ToString(
                    surfaceCompatibility.ContainsKey("skill_version")
                        ? surfaceCompatibility["skill_version"]
                        : null
                );
                surfaceMode = Convert.ToString(
                    surfaceCompatibility.ContainsKey("mode")
                        ? surfaceCompatibility["mode"]
                        : null
                );
            }
            int candidateCount = 0;
            int compatibleCount = 0;
            Dictionary<string, object> discovery = null;
            if (skill.ContainsKey("discovery"))
            {
                discovery = skill["discovery"] as Dictionary<string, object>;
            }
            if (discovery != null)
            {
                if (discovery.ContainsKey("candidate_count"))
                {
                    candidateCount = Convert.ToInt32(
                        discovery["candidate_count"]
                    );
                }
                if (discovery.ContainsKey("compatible_count"))
                {
                    compatibleCount = Convert.ToInt32(
                        discovery["compatible_count"]
                    );
                }
            }
            bool hasAnalyzeCapability = false;
            object capabilitiesValue;
            if (skill.TryGetValue("capabilities", out capabilitiesValue))
            {
                object[] capabilities = capabilitiesValue as object[];
                if (capabilities == null && capabilitiesValue is object)
                {
                    capabilities = new object[] { capabilitiesValue };
                }
                foreach (object capabilityValue in capabilities ?? new object[0])
                {
                    Dictionary<string, object> capability =
                        capabilityValue as Dictionary<string, object>;
                    if (
                        capability != null &&
                        capability.ContainsKey("id") &&
                        String.Equals(
                            Convert.ToString(capability["id"]),
                            "telemetry.csv.analyze",
                            StringComparison.Ordinal
                        )
                    )
                    {
                        hasAnalyzeCapability = true;
                        break;
                    }
                }
            }
            if (
                !String.Equals(skillId, ExpectedSkillId, StringComparison.Ordinal) ||
                !surfaceCompatible ||
                !String.Equals(
                    surfaceContractId,
                    ExpectedSurfaceContract,
                    StringComparison.Ordinal
                ) ||
                !String.Equals(
                    surfaceSkillVersion,
                    skillVersion,
                    StringComparison.Ordinal
                ) ||
                !String.Equals(status, "active", StringComparison.Ordinal) ||
                candidateCount < 1 ||
                compatibleCount < 1 ||
                !hasAnalyzeCapability
            )
            {
                throw new LaunchFailureException(
                    "skill_runtime_mismatch",
                    "SkillDock loaded " + (skillId ?? "(none)") + " " +
                    (skillVersion ?? "(none)") + " with status " +
                    (status ?? "(none)") + ", candidate_count=" +
                    candidateCount + ", compatible_count=" +
                    compatibleCount + ", telemetry.csv.analyze=" +
                    (hasAnalyzeCapability ? "present" : "missing") +
                    ", surface_contract=" + (surfaceContractId ?? "(none)") +
                    ", surface_contract_version=" +
                    (surfaceContractVersion ?? "(none)") +
                    ", surface_mode=" + (surfaceMode ?? "(none)") +
                    ", surface_compatibility=" + (surfaceCode ?? "(none)") +
                    ". Refusing compatibility-fixture fallback."
                );
            }
        }
    }

    private static void StopStartedServer(
        Process process,
        int port,
        string runtimeDirectory
    )
    {
        try
        {
            string tokenPath = Path.Combine(runtimeDirectory, "capability-token");
            if (File.Exists(tokenPath))
            {
                HttpWebRequest request = (HttpWebRequest)WebRequest.Create(
                    "http://127.0.0.1:" + port + "/api/shutdown"
                );
                request.Method = "POST";
                request.ContentType = "application/json";
                request.Headers["Authorization"] =
                    "Bearer " + File.ReadAllText(tokenPath).Trim();
                byte[] body = Encoding.UTF8.GetBytes("{}");
                request.ContentLength = body.Length;
                using (Stream stream = request.GetRequestStream())
                {
                    stream.Write(body, 0, body.Length);
                }
                using (HttpWebResponse response =
                    (HttpWebResponse)request.GetResponse())
                {
                }
            }
        }
        catch
        {
            // Fall back to terminating the launcher-owned child below.
        }
        try
        {
            if (process != null && !process.WaitForExit(5000))
            {
                process.Kill();
                process.WaitForExit(5000);
            }
        }
        catch
        {
            // The original validation failure remains the primary error.
        }
    }

    private static void TryWriteLaunchFailure(string code, string message)
    {
        try
        {
            Directory.CreateDirectory(LocalRoot);
            string failurePath = Path.Combine(LocalRoot, "launch-failure.json");
            Dictionary<string, object> payload = new Dictionary<string, object>();
            payload["ok"] = false;
            payload["error_code"] = code;
            payload["error"] = message;
            payload["failed_at"] = DateTimeOffset.Now.ToString("o");
            File.WriteAllText(
                failurePath,
                new JavaScriptSerializer().Serialize(payload) + "\r\n",
                Encoding.UTF8
            );
        }
        catch
        {
            // The launch-panel also probes writability before starting.
        }
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

    private sealed class LaunchFailureException : Exception
    {
        public string Code { get; private set; }

        public LaunchFailureException(string code, string message)
            : base(message)
        {
            Code = code;
        }
    }
}

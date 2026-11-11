# Installation and Upgrade

[中文](../installation.md) | [English](installation.md)

## Requirements

- Windows 10 or Windows 11.
- Windows PowerShell 5.1 or PowerShell 7 for automated collection.
- Other operating systems receive manual troubleshooting guidance only; the Skill
  does not read hardware automatically there.
- Optional monitoring requires an already-running LibreHardwareMonitor instance. This
  project does not install or start it.

## Codex one-command installation

The installer downloads the `main` branch archive and copies only
`skill/pc-hardware-workbench` into the Codex Skill directory. It does not run the
hardware collector.

1. Open a normal PowerShell window.
2. Download and run the installer.
3. Restart Codex.
4. Invoke `$pc-hardware-workbench` to verify that the Skill is available.

```powershell
$installer = Join-Path $env:TEMP "install-pc-hardware-workbench.ps1"
curl.exe -fsSL "https://raw.githubusercontent.com/Feng23-feng/pc-hardware-workbench/main/tools/install-skill.ps1" -o $installer
powershell -NoProfile -ExecutionPolicy Bypass -File $installer
```

The default destination is:

```text
%USERPROFILE%\.codex\skills\pc-hardware-workbench
```

To upgrade, add `-Force`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File $installer -Force
```

The previous version is moved outside the Codex Skill scan root:

```text
%USERPROFILE%\.codex\skill-backups\pc-hardware-workbench\
```

Do not leave an older version under `%USERPROFILE%\.codex\skills`. Codex scans that
tree for `SKILL.md`, so an old backup containing the original manifest can be
discovered as a second Skill with the same name, causing route ambiguity or startup
warnings.

The current installer also migrates `.backup-*` directories left inside the Skill
scan root by older installer versions. To choose a custom backup directory, pass
`-BackupRoot <directory>`. The path must be outside the Skill scan root and must not
pass through a symbolic link, directory junction, or other reparse point that leads
back to that root.

## Codex manual installation

When installing from source, copy the complete Skill directory:

```text
skill\pc-hardware-workbench
```

to:

```text
%USERPROFILE%\.codex\skills\pc-hardware-workbench
```

If that destination already exists, move it to a timestamped directory under:

```text
%USERPROFILE%\.codex\skill-backups\pc-hardware-workbench\
```

Do not copy only `SKILL.md`. The entry point depends on the adjacent `scripts/`,
`references/`, and `assets/` directories.

## Codex release ZIP installation

Each test release provides two Codex assets:

1. Open [GitHub Releases](https://github.com/Feng23-feng/pc-hardware-workbench/releases).
2. Choose `pc-hardware-workbench-v<version>-installer.zip`, extract it, and run
   `Install-PC-Hardware-Workbench.cmd`. This package supports automatic installation
   and upgrade.
3. Alternatively, choose `pc-hardware-workbench-v<version>-manual.zip`, extract the
   included `pc-hardware-workbench/` directory, and place it at
   `%USERPROFILE%\.codex\skills\pc-hardware-workbench`. The manual ZIP does not create
   a backup automatically, so first move any existing installation under
   `%USERPROFILE%\.codex\skill-backups\pc-hardware-workbench\`.
4. If the automatic installer finds an old version, it first moves it to
   `%USERPROFILE%\.codex\skill-backups\pc-hardware-workbench\`.
5. Restart Codex and invoke `$pc-hardware-workbench`.

The installer ZIP includes `安装说明.txt` and `BUILD-INFO.json` so that version,
commit, and build time can be checked. It also includes `README.en.md` and the English
installation and privacy guides. The manual ZIP contains only the Skill directory. Do
not place either ZIP file directly inside the Skill directory. Codex needs the
extracted `pc-hardware-workbench` folder.

## Let an AI install it

```text
Install the PC Hardware Workbench Skill from:
https://github.com/Feng23-feng/pc-hardware-workbench

Before installation, inspect the destination:
%USERPROFILE%\.codex\skills\pc-hardware-workbench

Copy only skill\pc-hardware-workbench from the repository.

If the destination already exists, do not overwrite it. Move it to a timestamped
directory under:
%USERPROFILE%\.codex\skill-backups\pc-hardware-workbench\

Do not leave an older copy inside .codex\skills. After installation, verify that
SKILL.md, scripts, and references are present. Do not run the hardware collector,
request administrator privileges, or modify BIOS, drivers, or system settings.
Report the installation path, backup path if any, and the required Codex restart step.
```

## DeepSeek Harness

See the [DeepSeek Harness adapter](../../adapters/dsh/README.md).

The default Skill path is:

```text
%USERPROFILE%\.dsh\skills\pc-hardware-workbench
```

When `DSH_HOME` is set, use:

```text
%DSH_HOME%\skills\pc-hardware-workbench
```

Invoke the Skill with:

```text
/pc-hardware-workbench
```

On first load, the Harness adapter can use `AGENTS.md` or `DEEPSEEK.md` as its project
entry point.

## Portable Windows tools

The standalone version does not require a Skill host. Its interactive interface is
currently Chinese-only:

```powershell
cd portable
.\开始使用.cmd
```

Run the non-hardware self-test with:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\start.ps1 -SelfTest
```

For interactive collection, choose either the standard or privacy-redacted mode in
the menu and enter `y` to authorize the read-only operation. The command-line flags
are required for a direct live self-test:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass `
  -File .\start.ps1 -SelfTest -AllowLiveCollector -CollectorPrivacyMode Redacted
```

## Verify the installation

Check the key paths:

```powershell
$skill = Join-Path $HOME ".codex\skills\pc-hardware-workbench"
Test-Path (Join-Path $skill "SKILL.md")
Test-Path (Join-Path $skill "scripts")
Test-Path (Join-Path $skill "references")
```

All three checks should return `True`. If the Skill is still absent from Codex,
restart the application before retrying the invocation.

## Upgrade and rollback

- Upgrade by rerunning the installer with `-Force`.
- The installer moves the old version to
  `.codex\skill-backups\pc-hardware-workbench\`.
- To roll back, close Codex, move the current Skill directory elsewhere, and move the
  selected backup directory back to
  `.codex\skills\pc-hardware-workbench`.
- Keep only one active Workbench directory containing `SKILL.md` at a time to avoid
  duplicate Skill discovery.
- Do not remove or overwrite an active installation until the rollback backup has been
  verified.

## Uninstall

Close Codex before removing:

```text
%USERPROFILE%\.codex\skills\pc-hardware-workbench
```

You can move the directory to another backup location before deleting it. Read
[Privacy and safety boundaries](privacy-and-safety.md) for the data-handling policy.

from __future__ import annotations

import argparse
import json
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path


VERSION_DIR_RE = re.compile(r"^(?P<version>\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)$")
VERSION_ZIP_RE = re.compile(
    r"v(?P<version>\d+\.\d+\.\d+(?:-[0-9A-Za-z.-]+)?)(?:-[^/]*)?\.zip$"
)
ZIP_DIRS = ("share", "share-r1", "share-r2", "dist")


def read_json(path: Path) -> dict | None:
    if not path.is_file():
        return None
    return json.loads(path.read_text(encoding="utf-8"))


def skill_version(path: Path) -> str | None:
    if not path.is_file():
        return None
    match = re.search(r'(?m)^\s*version:\s*"([^"]+)"\s*$', path.read_text(encoding="utf-8"))
    return match.group(1) if match else None


def version_key(version: str) -> tuple[int, int, int, str]:
    match = re.match(
        r"^(?P<major>\d+)\.(?P<minor>\d+)\.(?P<patch>\d+)(?:-(?P<label>.*))?$",
        version,
    )
    if not match:
        return (0, 0, 0, version)
    return (
        int(match["major"]),
        int(match["minor"]),
        int(match["patch"]),
        match["label"] or "",
    )


def build_info(version_root: Path) -> dict | None:
    direct = version_root / "BUILD-INFO.json"
    if direct.is_file():
        return read_json(direct)
    bundle_root = version_root / "bundle"
    if bundle_root.is_dir():
        for directory in sorted(bundle_root.iterdir()):
            candidate = directory / "BUILD-INFO.json"
            if candidate.is_file():
                return read_json(candidate)
    return None


def release_zips(version_root: Path) -> list[Path]:
    zips = sorted(path for path in version_root.glob("*.zip") if path.is_file())
    for folder_name in ZIP_DIRS:
        folder = version_root / folder_name
        if folder.is_dir():
            zips.extend(sorted(path for path in folder.glob("*.zip") if path.is_file()))
    return zips


def date_for(path: Path, info: dict | None) -> str:
    if info and info.get("BuiltAt"):
        try:
            return datetime.fromisoformat(info["BuiltAt"]).date().isoformat()
        except ValueError:
            pass
    return datetime.fromtimestamp(path.stat().st_mtime).date().isoformat()


def release_entry(channel: str, version: str, path: Path) -> dict:
    info = build_info(path) if path.is_dir() else None
    zips = release_zips(path) if path.is_dir() else [path]
    package_files = None
    if info:
        package_files = info.get("SkillFiles", info.get("PortableFiles"))
    return {
        "channel": channel,
        "version": version,
        "date": date_for(path, info),
        "zip_count": len(zips),
        "bytes": sum(item.stat().st_size for item in zips),
        "package_file_count": package_files,
        "git_commit": info.get("GitCommit") if info else None,
        "human_acceptance": info.get("HumanAcceptance") if info else None,
        "broad_distribution": info.get("BroadDistributionApproved") if info else None,
        "path": str(path),
    }


def channel_entries(channel: str, root: Path) -> list[dict]:
    if not root.is_dir():
        return []
    entries: list[dict] = []
    for directory in sorted(root.iterdir()):
        if directory.is_dir() and VERSION_DIR_RE.fullmatch(directory.name):
            entries.append(release_entry(channel, directory.name, directory))
    for archive in sorted(root.glob("*.zip")):
        match = VERSION_ZIP_RE.search(archive.name)
        if match:
            entries.append(release_entry(channel, match.group("version"), archive))
    return sorted(
        entries,
        key=lambda item: (
            version_key(item["version"])[:3],
            item["date"],
            version_key(item["version"])[3],
        ),
        reverse=True,
    )


def installed_entry(name: str, root: Path) -> dict | None:
    if not root.is_dir():
        return None
    info = read_json(root / "INSTALL-INFO.json")
    return {
        "name": name,
        "path": str(root),
        "skill_version": skill_version(root / "SKILL.md"),
        "installed_at": info.get("InstalledAt") if info else None,
        "release_name": info.get("ReleaseName") if info else None,
        "release_label": info.get("ReleaseLabel") if info else None,
        "git_commit": info.get("GitCommit") if info else None,
        "file_count": sum(1 for path in root.rglob("*") if path.is_file()),
    }


def backup_entries(root: Path) -> list[dict]:
    if not root.is_dir():
        return []
    entries = []
    for directory in sorted(root.iterdir(), reverse=True):
        if not directory.is_dir():
            continue
        entries.append(
            {
                "name": directory.name,
                "version": skill_version(directory / "SKILL.md"),
                "date": datetime.fromtimestamp(directory.stat().st_mtime).date().isoformat(),
                "file_count": sum(1 for path in directory.rglob("*") if path.is_file()),
                "path": str(directory),
            }
        )
    return entries


def git_rows(repository: Path) -> tuple[list[dict], str, str, str, bool]:
    def git(*args: str) -> str:
        return subprocess.check_output(
            ["git", "-C", str(repository), *args],
            text=True,
            encoding="utf-8",
        ).strip()

    raw_tags = git(
        "for-each-ref",
        "--sort=-creatordate",
        "--format=%(refname:short)%09%(creatordate:short)%09%(objectname:short)%09%(subject)",
        "refs/tags",
    )
    tags = []
    for line in raw_tags.splitlines():
        fields = line.split("\t", 3)
        if len(fields) == 4:
            tags.append(
                {
                    "tag": fields[0],
                    "date": fields[1],
                    "commit": fields[2],
                    "subject": fields[3],
                }
            )
    commit = git("rev-parse", "HEAD")
    tree = git("rev-parse", "HEAD^{tree}")
    try:
        tag = git("describe", "--tags", "--exact-match", "HEAD")
    except subprocess.CalledProcessError:
        tag = ""
    dirty = bool(git("status", "--porcelain", "--untracked-files=normal"))
    return tags, commit, tree, tag, dirty


def documented_versions(repository: Path) -> list[str]:
    changelog = repository / "CHANGELOG.md"
    if not changelog.is_file():
        return []
    text = changelog.read_text(encoding="utf-8")
    return re.findall(r"(?m)^## (\d+\.\d+\.\d+)\b", text)


def table_text(value) -> str:
    if value is None or value == "":
        return "—"
    return str(value).replace("|", r"\|").replace("\r", " ").replace("\n", " ")


def link(path: str, label: str) -> str:
    return f"[{label}](<{path.replace(chr(92), '/')}>)"


def size_text(byte_count: int) -> str:
    return f"{byte_count / (1024 * 1024):.2f} MiB" if byte_count else "—"


def render_markdown(index: dict) -> str:
    lines = [
        "# PC Hardware Workbench 统一版本索引",
        "",
        f"生成时间：`{index['generated_at']}`",
        "",
        "## 当前状态",
        "",
        "| 项目 | 值 |",
        "|---|---|",
        f"| 源码版本 | `{index['source_version']}` |",
        f"| 当前 Git 标签 | {table_text(index['current_git_tag'])} |",
        f"| 当前提交 | `{index['current_git_commit']}` |",
        f"| 当前 Tree | `{index['current_git_tree']}` |",
        f"| 工作区 | {'有未提交或未跟踪改动' if index['worktree_dirty'] else '干净'} |",
        "",
        "## 本机安装",
        "",
        "| 宿主 | Skill 版本 | Release | 提交 | 文件数 | 安装时间 | 路径 |",
        "|---|---|---|---|---:|---|---|",
    ]
    for entry in index["installed"]:
        lines.append(
            "| {} | {} | {} | {} | {} | {} | {} |".format(
                table_text(entry["name"]),
                table_text(entry["skill_version"]),
                table_text(entry["release_name"]),
                table_text(entry["git_commit"]),
                entry["file_count"],
                table_text(entry["installed_at"]),
                link(entry["path"], "打开"),
            )
        )

    lines.extend(["", "## 历史发行包", ""])
    for channel_name, entries in index["releases"].items():
        lines.extend(
            [
                f"### {channel_name}",
                "",
                f"共 {len(entries)} 项，按版本从新到旧。",
                "",
                "| 版本 | 日期 | Zip | 包内文件 | Zip 大小 | 提交 | 人工验收 | 可广泛分发 | 位置 |",
                "|---|---|---:|---:|---:|---|---|---|---|",
            ]
        )
        for entry in entries:
            broad = (
                "—"
                if entry["broad_distribution"] is None
                else ("yes" if entry["broad_distribution"] else "no")
            )
            lines.append(
                "| {} | {} | {} | {} | {} | {} | {} | {} | {} |".format(
                    table_text(entry["version"]),
                    table_text(entry["date"]),
                    entry["zip_count"],
                    table_text(entry["package_file_count"]),
                    size_text(entry["bytes"]),
                    table_text(entry["git_commit"]),
                    table_text(entry["human_acceptance"]),
                    broad,
                    link(entry["path"], "打开"),
                )
            )
        lines.append("")

    lines.extend(["## 本机安装备份", ""])
    for host in index["backups"]:
        lines.extend([f"### {host['host']}", ""])
        if not host["entries"]:
            lines.extend(["暂无备份。", ""])
            continue
        lines.extend(
            [
                "| 备份 | 版本 | 日期 | 文件数 | 位置 |",
                "|---|---|---|---:|---|",
            ]
        )
        for entry in host["entries"]:
            lines.append(
                "| {} | {} | {} | {} | {} |".format(
                    table_text(entry["name"]),
                    table_text(entry["version"]),
                    table_text(entry["date"]),
                    entry["file_count"],
                    link(entry["path"], "打开"),
                )
            )
        lines.append("")

    lines.extend(
        [
            "## Git 标签",
            "",
            "| 标签 | 日期 | 提交 | 说明 |",
            "|---|---|---|---|",
        ]
    )
    for entry in index["git_tags"]:
        lines.append(
            "| {} | {} | {} | {} |".format(
                table_text(entry["tag"]),
                table_text(entry["date"]),
                table_text(entry["commit"]),
                table_text(entry["subject"]),
            )
        )
    lines.extend(
        [
            "",
            "## 记录与限制",
            "",
            f"- 版本命名规则：{link(str(Path(index['releases_root']) / 'VERSIONING.txt'), 'VERSIONING.txt')}",
            f"- 当前发行指针：{link(str(Path(index['releases_root']) / 'pc-hardware-workbench' / 'CURRENT.txt'), 'CURRENT.txt')}",
            f"- 仓库主变更记录：{link(str(Path(index['repository_root']) / 'CHANGELOG.md'), 'CHANGELOG.md')}",
            "- 本索引只列出磁盘上实际存在的发行目录或 ZIP；没有发行包的版本只能从 Git 历史恢复。",
            "- `HumanAcceptance` 和 `BroadDistribution` 仅在存在 `BUILD-INFO.json` 时填写；空白不代表通过。",
            "- 包内文件数和 Zip 大小只统计版本目录顶层及 `share`、`share-r1`、`share-r2`、`dist` 中的发行 ZIP。",
            "",
        ]
    )
    if index["documented_missing_packages"]:
        insert_at = len(lines) - 2
        lines.insert(
            insert_at,
            "- CHANGELOG 已记录但本地没有单独发行包："
            + "、".join(index["documented_missing_packages"]),
        )
    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--repository-root",
        type=Path,
        default=Path(__file__).resolve().parent.parent,
    )
    parser.add_argument(
        "--releases-root",
        type=Path,
        default=Path(r"C:\Users\28271\Documents\Codex\releases"),
    )
    parser.add_argument("--output-markdown", type=Path)
    parser.add_argument("--output-json", type=Path)
    args = parser.parse_args()

    repository_root = args.repository_root.resolve()
    releases_root = args.releases_root.resolve()
    output_markdown = (
        args.output_markdown.resolve()
        if args.output_markdown
        else releases_root / "VERSION-INDEX.md"
    )
    output_json = (
        args.output_json.resolve()
        if args.output_json
        else releases_root / "VERSION-INDEX.json"
    )

    releases = {
        "Codex Skill": channel_entries(
            "Codex Skill", releases_root / "pc-hardware-workbench"
        ),
        "Portable": channel_entries("Portable", releases_root / "pc-hardware-portable"),
        "DeepSeek Harness": channel_entries(
            "DeepSeek Harness", releases_root / "deepseek-harness-adapter"
        ),
    }
    installed = [
        item
        for item in (
            installed_entry(
                "Codex", Path.home() / ".codex" / "skills" / "pc-hardware-workbench"
            ),
            installed_entry(
                "DeepSeek Harness",
                Path.home() / ".dsh" / "skills" / "pc-hardware-workbench",
            ),
        )
        if item
    ]
    backups = [
        {
            "host": "Codex",
            "entries": backup_entries(
                Path.home() / ".codex" / "skill-backups" / "pc-hardware-workbench"
            ),
        },
        {
            "host": "DeepSeek Harness",
            "entries": backup_entries(
                Path.home() / ".dsh" / "skill-backups" / "pc-hardware-workbench"
            ),
        },
    ]
    tags, commit, tree, tag, dirty = git_rows(repository_root)
    available_version_keys = {
        version_key(entry["version"])[:3]
        for entries in releases.values()
        for entry in entries
    }
    missing_packages = [
        version
        for version in documented_versions(repository_root)
        if version_key(version)[:3] not in available_version_keys
    ]
    index = {
        "generated_at": datetime.now(timezone.utc).astimezone().isoformat(),
        "repository_root": str(repository_root),
        "releases_root": str(releases_root),
        "source_version": skill_version(
            repository_root / "skill" / "pc-hardware-workbench" / "SKILL.md"
        ),
        "current_git_commit": commit,
        "current_git_tree": tree,
        "current_git_tag": tag,
        "worktree_dirty": dirty,
        "installed": installed,
        "backups": backups,
        "releases": releases,
        "git_tags": tags,
        "documented_missing_packages": missing_packages,
    }
    output_markdown.write_text(render_markdown(index), encoding="utf-8")
    output_json.write_text(
        json.dumps(index, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    print("Release index: PASS")
    print(f"  Markdown: {output_markdown}")
    print(f"  JSON:     {output_json}")
    print(f"  Codex Skill releases: {len(releases['Codex Skill'])}")
    print(f"  Portable releases:    {len(releases['Portable'])}")
    print(f"  DSH releases:         {len(releases['DeepSeek Harness'])}")


if __name__ == "__main__":
    main()

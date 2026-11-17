import { createHash } from "node:crypto";
import {
  lstat,
  readdir,
  readFile,
} from "node:fs/promises";
import { join, relative, resolve, sep } from "node:path";

const EXCLUDED_ROOT_FILES = new Set([
  "INSTALL-INFO.json",
]);

function normalizeRelativePath(root, filePath) {
  return relative(root, filePath).split(sep).join("/");
}

async function collectFiles(root, current = root) {
  const entries = await readdir(current, { withFileTypes: true });
  const files = [];
  for (const entry of entries) {
    const filePath = join(current, entry.name);
    const stats = await lstat(filePath);
    if (stats.isSymbolicLink()) {
      throw new Error(`Skill tree contains a symbolic link: ${filePath}`);
    }
    if (entry.isDirectory()) {
      files.push(...await collectFiles(root, filePath));
      continue;
    }
    if (!entry.isFile()) continue;
    const relativePath = normalizeRelativePath(root, filePath);
    if (
      EXCLUDED_ROOT_FILES.has(relativePath) ||
      relativePath.startsWith(".git/")
    ) {
      continue;
    }
    files.push({
      path: relativePath,
      filePath,
    });
  }
  return files;
}

export async function computeSkillTreeIdentity(rootPath) {
  const root = resolve(rootPath);
  const files = await collectFiles(root);
  files.sort((left, right) =>
    left.path < right.path ? -1 : left.path > right.path ? 1 : 0
  );
  const manifest = [];
  for (const file of files) {
    const body = await readFile(file.filePath);
    const sha256 = createHash("sha256").update(body).digest("hex");
    manifest.push(`${sha256}  ${file.path}\n`);
  }
  const manifestText = manifest.join("");
  return {
    root,
    tree_sha256: createHash("sha256")
      .update(manifestText)
      .digest("hex"),
    tree_file_count: files.length,
    files: files.map((file, index) => ({
      path: file.path,
      sha256: manifest[index].slice(0, 64),
    })),
  };
}

export async function compareSkillTrees(sourcePath, installedPath) {
  const source = await computeSkillTreeIdentity(sourcePath);
  const installed = await computeSkillTreeIdentity(installedPath);
  const sourceFiles = new Map(
    source.files.map((file) => [file.path, file.sha256]),
  );
  const installedFiles = new Map(
    installed.files.map((file) => [file.path, file.sha256]),
  );
  const missing = [];
  const changed = [];
  for (const [filePath, sha256] of sourceFiles) {
    if (!installedFiles.has(filePath)) {
      missing.push(filePath);
    } else if (installedFiles.get(filePath) !== sha256) {
      changed.push(filePath);
    }
  }
  const extra = [...installedFiles.keys()]
    .filter((filePath) => !sourceFiles.has(filePath))
    .sort();
  return {
    ok:
      source.tree_sha256 === installed.tree_sha256 &&
      missing.length === 0 &&
      changed.length === 0 &&
      extra.length === 0,
    source,
    installed,
    missing,
    changed,
    extra,
  };
}

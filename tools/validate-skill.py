#!/usr/bin/env python3
"""Validate the frontmatter and basic Skill packaging invariants."""

from __future__ import annotations

import re
import sys
from pathlib import Path

import yaml


ALLOWED_KEYS = {"name", "description", "license", "allowed-tools", "metadata"}
NAME_PATTERN = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")


def fail(message: str) -> None:
    print(f"Skill validation failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def validate(skill_dir: Path) -> None:
    skill_file = skill_dir / "SKILL.md"
    if not skill_file.is_file():
        fail("SKILL.md not found")

    content = skill_file.read_text(encoding="utf-8-sig")
    match = re.match(r"^---\r?\n(.*?)\r?\n---(?:\r?\n|$)", content, re.DOTALL)
    if not match:
        fail("missing or malformed YAML frontmatter")

    try:
        frontmatter = yaml.safe_load(match.group(1))
    except yaml.YAMLError as exc:
        fail(f"invalid YAML: {exc}")

    if not isinstance(frontmatter, dict):
        fail("frontmatter must be a YAML mapping")

    unexpected = set(frontmatter) - ALLOWED_KEYS
    if unexpected:
        fail(f"unexpected frontmatter keys: {', '.join(sorted(unexpected))}")

    name = frontmatter.get("name")
    description = frontmatter.get("description")
    if not isinstance(name, str) or not name.strip():
        fail("name must be a non-empty string")
    if len(name) > 64 or not NAME_PATTERN.fullmatch(name):
        fail("name must be hyphen-case and at most 64 characters")
    if name != skill_dir.name:
        fail("skill folder name must match frontmatter name")

    if not isinstance(description, str) or not description.strip():
        fail("description must be a non-empty string")
    if len(description) > 1024:
        fail("description exceeds 1024 characters")
    if "<" in description or ">" in description:
        fail("description cannot contain angle brackets")

    if re.search(r"(?m)^\s*\[TODO:[^\n]*\]\s*$", content):
        fail("unfinished TODO placeholder found")

    print("Skill is valid!")


def main() -> None:
    if len(sys.argv) != 2:
        print("Usage: python validate-skill.py <skill-directory>", file=sys.stderr)
        raise SystemExit(2)
    validate(Path(sys.argv[1]).resolve())


if __name__ == "__main__":
    main()

"""Shared rules for the FDAM manifest tools.

These rules mirror the Dart validator in packages/fdam (ManifestValidator),
so a manifest that passes validate_manifest.py is accepted by the app.
Standard library only.
"""

from __future__ import annotations

import hashlib
import os
import re
import zipfile
from typing import Iterable
from urllib.parse import urlparse

SCHEMA_VERSION = 1
SUPPORTED_SCHEMAS = {1}

ASSET_ID_RE = re.compile(r"^[a-z0-9][a-z0-9_.-]{0,63}$")
SHA256_RE = re.compile(r"^[a-f0-9]{64}$")
SEMVER_RE = re.compile(
    r"^(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})\.(0|[1-9]\d{0,8})"
    r"(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?$"
)
# Release asset names are kept URL-safe so the download URL is predictable.
SAFE_FILE_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,200}$")

CATEGORIES = {"audio", "image", "video", "database", "resource", "config", "data"}
CATEGORY_ALIASES = {
    "images": "image",
    "videos": "video",
    "databases": "database",
    "resources": "resource",
}
# Folder used for the default localPath of each category.
CATEGORY_DIRS = {
    "audio": "audio",
    "image": "images",
    "video": "videos",
    "database": "",
    "resource": "resources",
    "config": "config",
    "data": "data",
}
EXTENSION_CATEGORIES = {
    "audio": {".mp3", ".wav", ".ogg", ".m4a", ".aac", ".flac", ".opus"},
    "image": {".jpg", ".jpeg", ".png", ".webp", ".svg", ".gif", ".bmp"},
    "video": {".mp4", ".mkv", ".webm", ".mov", ".3gp", ".m4v"},
    "database": {".db", ".sqlite", ".sqlite3"},
    "config": {".json", ".yaml", ".yml", ".toml"},
    "resource": {".zip"},
}

GITHUB_HOSTS = (
    "github.com",
    "raw.githubusercontent.com",
    "objects.githubusercontent.com",
    "release-assets.githubusercontent.com",
    "codeload.github.com",
)

KNOWN_ROOT_KEYS = ("schemaVersion", "appId", "releaseVersion", "minimumManagerVersion", "generatedAt", "assets")


def sha256_file(path: str, chunk_size: int = 1 << 20) -> str:
    """Streaming SHA-256 (never loads the whole file in memory)."""
    h = hashlib.sha256()
    with open(path, "rb") as f:
        while True:
            block = f.read(chunk_size)
            if not block:
                break
            h.update(block)
    return h.hexdigest()


def parse_semver(value: object):
    if not isinstance(value, str):
        return None
    m = SEMVER_RE.match(value.strip())
    if not m:
        return None
    pre = m.group(4) or ""
    return int(m.group(1)), int(m.group(2)), int(m.group(3)), pre


def semver_key(value: str):
    """Sort key consistent with SemVer precedence (pre-release < release)."""
    major, minor, patch, pre = parse_semver(value)
    if not pre:
        return (major, minor, patch, 1, ())
    parts = []
    for p in pre.split("."):
        parts.append((0, int(p), "") if p.isdigit() else (1, 0, p))
    return (major, minor, patch, 0, tuple(parts))


def normalize_category(value: object):
    if not isinstance(value, str):
        return None
    v = value.strip().lower()
    v = CATEGORY_ALIASES.get(v, v)
    return v if v in CATEGORIES else None


def category_for_file(name: str) -> str:
    ext = os.path.splitext(name)[1].lower()
    for cat, exts in EXTENSION_CATEGORIES.items():
        if ext in exts:
            return cat
    return "data"


def slug_id(name: str) -> str:
    stem = os.path.splitext(name)[0].lower()
    s = re.sub(r"[^a-z0-9_.-]+", "_", stem).strip("_.-")
    if not s:
        s = "asset"
    if not s[0].isalnum():
        s = "a" + s
    return s[:64]


def relative_path_problem(path: object):
    """None when `path` is a safe relative POSIX path (same rules as Dart)."""
    if not isinstance(path, str) or path == "":
        return "empty"
    if len(path) > 512:
        return "too_long"
    if any(ord(c) < 32 or ord(c) == 127 for c in path):
        return "control_chars"
    if "\\" in path:
        return "backslash"
    if path.startswith("/"):
        return "absolute"
    if re.match(r"^[A-Za-z]:", path):
        return "drive_letter"
    if path.startswith("~"):
        return "home_reference"
    segs = path.split("/")
    for i, s in enumerate(segs):
        if s == "" and i == len(segs) - 1 and i > 0:
            continue
        if s == "":
            return "empty_segment"
        if s == "..":
            return "traversal"
        if s == ".":
            return "dot_segment"
        if len(s) > 255:
            return "segment_too_long"
    return None


def install_relative_path(category: str, local_path: str, extract: bool) -> str:
    rel = local_path[:-4] if extract and local_path.lower().endswith(".zip") else local_path
    root = "databases" if category == "database" else "assets"
    return f"{root}/{rel}"


def url_problem(url: object, allowed_hosts: Iterable[str] = GITHUB_HOSTS, prefixes: Iterable[str] = ()):
    if not isinstance(url, str):
        return "missing"
    u = urlparse(url.strip())
    if u.scheme != "https":
        return "not_https"
    if not u.hostname:
        return "malformed"
    if u.username or u.password:
        return "credentials_in_url"
    if u.fragment:
        return "fragment"
    host = u.hostname.lower()
    if not any(host == h or host.endswith("." + h) for h in allowed_hosts):
        return "host_not_allowed"
    prefixes = list(prefixes)
    if prefixes and not any(url.startswith(p) for p in prefixes):
        return "prefix_not_allowed"
    return None


def release_url(owner: str, repo: str, tag: str, name: str) -> str:
    return f"https://github.com/{owner}/{repo}/releases/download/{tag}/{name}"


def zip_problems(path: str, max_entries: int = 20000, max_total: int = 8 * 1024 ** 3, max_ratio: float = 200.0):
    """Returns (problems, total_uncompressed_size). Mirrors the app's
    extraction rules so a ZIP rejected on the device is rejected here."""
    problems = []
    total = 0
    try:
        with zipfile.ZipFile(path) as z:
            infos = z.infolist()
            if not infos:
                problems.append("empty archive")
            if len(infos) > max_entries:
                problems.append(f"too many entries ({len(infos)})")
            seen = set()
            for info in infos:
                p = relative_path_problem(info.filename)
                if p:
                    problems.append(f"unsafe entry {info.filename!r} ({p})")
                mode = (info.external_attr >> 16) & 0xF000
                if mode == 0xA000:
                    problems.append(f"symbolic link {info.filename!r}")
                key = info.filename.rstrip("/").lower()
                if key in seen:
                    problems.append(f"duplicate entry {info.filename!r}")
                seen.add(key)
                if not info.is_dir():
                    total += info.file_size
                    if info.file_size > 1024 * 1024 and info.compress_size > 0 and info.file_size / info.compress_size > max_ratio:
                        problems.append(f"suspicious compression ratio for {info.filename!r}")
            if total > max_total:
                problems.append("uncompressed size over limit")
            size = os.path.getsize(path)
            if total > 1024 * 1024 and size > 0 and total / size > max_ratio:
                problems.append("suspicious overall compression ratio")
            bad = z.testzip()
            if bad is not None:
                problems.append(f"CRC error in {bad!r}")
    except zipfile.BadZipFile as e:
        problems.append(f"not a valid ZIP: {e}")
    return problems, total


def validate_manifest_dict(m: object, app_id: str | None = None, allowed_hosts=GITHUB_HOSTS, prefixes=(),
                           manager_version: str = "1.0.0", max_asset_size: int | None = None):
    """Returns a list of error strings (empty when valid)."""
    errors = []
    if not isinstance(m, dict):
        return ["root: must be a JSON object"]
    for k in KNOWN_ROOT_KEYS:
        if k not in m:
            errors.append(f'root: missing "{k}"')
    if errors:
        return errors
    if not isinstance(m["schemaVersion"], int) or isinstance(m["schemaVersion"], bool) \
            or m["schemaVersion"] not in SUPPORTED_SCHEMAS:
        errors.append(f"schemaVersion: unsupported value {m['schemaVersion']!r}")
    if not isinstance(m["appId"], str) or not m["appId"]:
        errors.append("appId: must be a non-empty string")
    elif app_id is not None and m["appId"] != app_id:
        errors.append(f'appId: "{m["appId"]}" does not match "{app_id}"')
    if not parse_semver(m["releaseVersion"]):
        errors.append("releaseVersion: not a semantic version")
    if not parse_semver(m["minimumManagerVersion"]):
        errors.append("minimumManagerVersion: not a semantic version")
    elif semver_key(m["minimumManagerVersion"]) > semver_key(manager_version):
        errors.append(f"minimumManagerVersion: {m['minimumManagerVersion']} is newer than manager {manager_version}")
    gen = m["generatedAt"]
    if not isinstance(gen, str) or not re.match(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(\.\d+)?(Z|[+-]\d{2}:\d{2})$", gen):
        errors.append("generatedAt: not an ISO-8601 UTC date")
    assets = m["assets"]
    if not isinstance(assets, list):
        errors.append("assets: must be a list")
        return errors

    ids, paths, installs = set(), set(), []
    for i, a in enumerate(assets):
        where = f"assets[{i}]"
        if not isinstance(a, dict):
            errors.append(f"{where}: must be an object")
            continue
        aid = a.get("id")
        label = f"{where} ({aid})" if isinstance(aid, str) else where
        if not isinstance(aid, str) or not ASSET_ID_RE.match(aid):
            errors.append(f"{label}.id: must match {ASSET_ID_RE.pattern}")
        elif aid in ids:
            errors.append(f"{label}.id: duplicate id")
        else:
            ids.add(aid)
        name = a.get("name")
        if not isinstance(name, str) or "/" in name or relative_path_problem(name) or name.strip() != name:
            errors.append(f"{label}.name: must be a plain file name")
        cat = normalize_category(a.get("category"))
        if cat is None:
            errors.append(f"{label}.category: unknown category {a.get('category')!r}")
        if not parse_semver(a.get("version")):
            errors.append(f"{label}.version: not a semantic version")
        up = url_problem(a.get("url"), allowed_hosts, prefixes)
        if up:
            errors.append(f"{label}.url: {up}")
        lp = a.get("localPath")
        lp_problem = relative_path_problem(lp)
        if lp_problem or (isinstance(lp, str) and lp.endswith("/")):
            errors.append(f"{label}.localPath: unsafe path ({lp_problem or 'trailing_slash'})")
        else:
            key = f"{'databases' if cat == 'database' else 'assets'}/{lp}".lower()
            if key in paths:
                errors.append(f"{label}.localPath: duplicate path")
            paths.add(key)
        size = a.get("sizeBytes")
        if not isinstance(size, int) or isinstance(size, bool) or size <= 0:
            errors.append(f"{label}.sizeBytes: must be a positive integer")
        elif max_asset_size is not None and size > max_asset_size:
            errors.append(f"{label}.sizeBytes: larger than the configured limit")
        ext = a.get("extractedSizeBytes")
        if ext is not None and (not isinstance(ext, int) or isinstance(ext, bool) or ext < 0):
            errors.append(f"{label}.extractedSizeBytes: must be a non-negative integer")
        sha = a.get("sha256")
        if not isinstance(sha, str) or not SHA256_RE.match(sha.lower()):
            errors.append(f"{label}.sha256: must be 64 hex characters")
        for f in ("required", "downloadOnStartup", "extract", "deprecated"):
            if f in a and not isinstance(a[f], bool):
                errors.append(f"{label}.{f}: must be true/false")
        extract = a.get("extract") is True
        if extract and not (isinstance(name, str) and name.lower().endswith(".zip")):
            errors.append(f"{label}.extract: only .zip files can be extracted")
        if extract and isinstance(lp, str) and not lp.lower().endswith(".zip"):
            errors.append(f"{label}.localPath: must end with .zip when extract is true")
        if cat and isinstance(lp, str) and not lp_problem:
            ip = install_relative_path(cat, lp, extract).lower()
            for other in installs:
                if ip == other or ip.startswith(other + "/") or other.startswith(ip + "/"):
                    errors.append(f"{label}.localPath: overlaps another asset ({other})")
                    break
            installs.append(ip)
    return errors

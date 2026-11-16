#!/usr/bin/env python3
"""Generate manifest/manifest.json from the files in release-assets/.

For every file in the source folder:
  * detects the category from the extension (or config/assets_config.json),
  * computes size and SHA-256 (streaming),
  * builds the GitHub Release download URL for --tag,
  * for ZIP files: checks the archive is safe and records extractedSizeBytes.

With --previous (the manifest currently published), an asset whose SHA-256
did not change keeps its old version AND its old URL. Only changed or new
files need to be uploaded to the new release; they are listed in
--upload-list. This is what makes app updates download only changed files.

Example:
  python tools/generate_manifest.py --owner USER --repo MyFlutterApp-Assets \
      --tag v1.1.0 --source release-assets --output manifest/manifest.json \
      --app-id com.example.myapp --previous manifest/manifest.json \
      --upload-list upload.txt

Exit code 0 = manifest written, 1 = validation errors (nothing written).
"""

from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fdam_common import (  # noqa: E402
    ASSET_ID_RE,
    CATEGORY_DIRS,
    SAFE_FILE_NAME_RE,
    SCHEMA_VERSION,
    category_for_file,
    normalize_category,
    parse_semver,
    relative_path_problem,
    release_url,
    sha256_file,
    slug_id,
    validate_manifest_dict,
    zip_problems,
)

ASSET_KEYS = {"id", "category", "version", "localPath", "required", "downloadOnStartup", "extract",
              "deprecated", "description"}


def load_json(path: str):
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def build_manifest(*, owner: str, repo: str, tag: str, source: str, app_id: str, config: dict,
                   previous: dict | None, release_version: str, min_manager: str, now: dt.datetime | None = None):
    """Returns (manifest, upload_files, errors)."""
    errors: list[str] = []
    cfg_assets: dict = config.get("assets", {}) or {}
    defaults: dict = config.get("defaults", {}) or {}
    ignore = set(config.get("ignore", [])) | {".gitkeep", ".DS_Store", "Thumbs.db"}

    if not os.path.isdir(source):
        return None, [], [f"source folder {source!r} does not exist"]
    if not parse_semver(release_version):
        errors.append(f"release version {release_version!r} is not a semantic version (use tags like v1.2.0)")

    files = sorted(n for n in os.listdir(source)
                   if os.path.isfile(os.path.join(source, n)) and n not in ignore and not n.startswith("."))
    for name in cfg_assets:
        if name not in files:
            errors.append(f"config lists {name!r} but release-assets/{name} is missing")
    unknown_keys = {name: set(v) - ASSET_KEYS for name, v in cfg_assets.items() if isinstance(v, dict)}
    for name, keys in unknown_keys.items():
        if keys:
            errors.append(f"config for {name!r} has unknown keys: {sorted(keys)}")

    prev_by_id = {}
    if previous:
        for a in previous.get("assets", []):
            if isinstance(a, dict) and "id" in a:
                prev_by_id[a["id"]] = a

    assets, uploads = [], []
    for name in files:
        path = os.path.join(source, name)
        meta = {**defaults, **(cfg_assets.get(name) or {})}
        if not SAFE_FILE_NAME_RE.match(name):
            errors.append(f"{name!r}: rename it to letters, digits, '.', '_' or '-' (URL-safe)")
            continue
        category = normalize_category(meta.get("category")) if "category" in meta else category_for_file(name)
        if category is None:
            errors.append(f"{name!r}: unknown category {meta.get('category')!r}")
            continue
        asset_id = meta.get("id") or slug_id(name)
        if not ASSET_ID_RE.match(asset_id):
            errors.append(f"{name!r}: id {asset_id!r} must match {ASSET_ID_RE.pattern}")
        is_zip = name.lower().endswith(".zip")
        extract = bool(meta.get("extract", is_zip))
        if extract and not is_zip:
            errors.append(f"{name!r}: extract=true is only possible for .zip files")
        sub = CATEGORY_DIRS[category]
        local_path = meta.get("localPath") or (f"{sub}/{name}" if sub else name)
        lp_problem = relative_path_problem(local_path)
        if lp_problem:
            errors.append(f"{name!r}: localPath {local_path!r} is unsafe ({lp_problem})")

        size = os.path.getsize(path)
        if size <= 0:
            errors.append(f"{name!r}: file is empty")
        digest = sha256_file(path)
        extracted = None
        if extract and is_zip:
            problems, extracted = zip_problems(path)
            errors.extend(f"{name!r}: {p}" for p in problems)

        prev = prev_by_id.get(asset_id)
        unchanged = prev is not None and prev.get("sha256") == digest and prev.get("name") == name
        if "version" in meta:
            version = meta["version"]
            if unchanged and prev.get("version") != version:
                unchanged = False  # explicit version bump forces a new upload
        elif unchanged:
            version = prev["version"]
        else:
            version = release_version
        if not parse_semver(version):
            errors.append(f"{name!r}: version {version!r} is not a semantic version")

        url = prev["url"] if unchanged else release_url(owner, repo, tag, name)
        if not unchanged:
            uploads.append(name)

        item = {
            "id": asset_id,
            "name": name,
            "category": category,
            "version": version,
            "url": url,
            "localPath": local_path,
            "sizeBytes": size,
            "sha256": digest,
            "required": bool(meta.get("required", False)),
            "downloadOnStartup": bool(meta.get("downloadOnStartup", False)),
            "extract": extract,
        }
        if extracted is not None:
            item["extractedSizeBytes"] = extracted
        if meta.get("deprecated"):
            item["deprecated"] = True
        if meta.get("description"):
            item["description"] = str(meta["description"])
        assets.append(item)

    # Duplicates (also caught by the validator, reported here with file names).
    seen_ids, seen_paths = {}, {}
    for a in assets:
        if a["id"] in seen_ids:
            errors.append(f"duplicate id {a['id']!r} for {seen_ids[a['id']]!r} and {a['name']!r}")
        seen_ids[a["id"]] = a["name"]
        key = a["localPath"].lower()
        if key in seen_paths:
            errors.append(f"duplicate localPath {a['localPath']!r} for {seen_paths[key]!r} and {a['name']!r}")
        seen_paths[key] = a["name"]

    now = now or dt.datetime.now(dt.timezone.utc)
    manifest = {
        "schemaVersion": SCHEMA_VERSION,
        "appId": app_id,
        "releaseVersion": release_version,
        "minimumManagerVersion": min_manager,
        "generatedAt": now.astimezone(dt.timezone.utc).replace(microsecond=0).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "assets": assets,
    }
    if not errors:
        errors += validate_manifest_dict(
            manifest, app_id=app_id, prefixes=[f"https://github.com/{owner}/{repo}/releases/download/"])
    if previous and not errors:
        prev_v = previous.get("releaseVersion")
        if parse_semver(prev_v) and parse_semver(release_version):
            from fdam_common import semver_key
            if semver_key(release_version) <= semver_key(prev_v) and uploads:
                errors.append(f"release version {release_version} must be newer than {prev_v}")
    return manifest, uploads, errors


def write_json_atomic(path: str, data) -> None:
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--owner", required=True, help="GitHub user or organization")
    ap.add_argument("--repo", required=True, help="assets repository name")
    ap.add_argument("--tag", required=True, help="release tag, e.g. v1.1.0")
    ap.add_argument("--source", default="release-assets", help="folder with the files to publish")
    ap.add_argument("--output", default="manifest/manifest.json")
    ap.add_argument("--version-output", default=None,
                    help="manifest-version.json path (default: next to --output)")
    ap.add_argument("--app-id", default=None, help="application id (default: config appId)")
    ap.add_argument("--config", default="config/assets_config.json")
    ap.add_argument("--previous", default=None, help="currently published manifest (keeps unchanged assets)")
    ap.add_argument("--release-version", default=None, help="default: tag without leading 'v'")
    ap.add_argument("--min-manager", default=None, help="minimumManagerVersion (default: config or 1.0.0)")
    ap.add_argument("--upload-list", default=None, help="write the names of files to upload to this file")
    args = ap.parse_args(argv)

    config = load_json(args.config) if os.path.isfile(args.config) else {}
    app_id = args.app_id or config.get("appId")
    if not app_id:
        print("error: --app-id is required (or set appId in the config)", file=sys.stderr)
        return 1
    previous = None
    if args.previous and os.path.isfile(args.previous):
        try:
            previous = load_json(args.previous)
            if previous.get("appId") != app_id:
                print(f"error: previous manifest is for {previous.get('appId')!r}", file=sys.stderr)
                return 1
        except json.JSONDecodeError:
            print(f"warning: {args.previous} is not valid JSON, ignoring it", file=sys.stderr)
            previous = None
    release_version = args.release_version or (args.tag[1:] if args.tag.startswith("v") else args.tag)
    min_manager = args.min_manager or config.get("minimumManagerVersion", "1.0.0")

    manifest, uploads, errors = build_manifest(
        owner=args.owner, repo=args.repo, tag=args.tag, source=args.source, app_id=app_id, config=config,
        previous=previous, release_version=release_version, min_manager=min_manager)
    if errors:
        print(f"FAILED: {len(errors)} problem(s); manifest NOT written")
        for e in errors:
            print(f"  - {e}")
        return 1

    write_json_atomic(args.output, manifest)
    from fdam_common import sha256_file as _sha
    version_path = args.version_output or os.path.join(os.path.dirname(args.output) or ".", "manifest-version.json")
    write_json_atomic(version_path, {
        "releaseVersion": manifest["releaseVersion"],
        "generatedAt": manifest["generatedAt"],
        "assetCount": len(manifest["assets"]),
        "manifestSha256": _sha(args.output),
    })
    if args.upload_list:
        with open(args.upload_list, "w", encoding="utf-8", newline="\n") as f:
            for name in uploads:
                f.write(os.path.join(args.source, name) + "\n")
    print(f"OK: wrote {args.output} (release {release_version}, {len(manifest['assets'])} assets)")
    if uploads:
        print("Upload these files to release " + args.tag + ":")
        for n in uploads:
            print(f"  {os.path.join(args.source, n)}")
    else:
        print("No file changed; nothing to upload.")
    return 0


if __name__ == "__main__":
    sys.exit(main())

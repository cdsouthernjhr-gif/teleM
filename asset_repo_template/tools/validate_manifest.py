#!/usr/bin/env python3
"""Validate manifest/manifest.json before a release is published.

Checks the same rules as the app (schema, appId, versions, URLs, paths,
sizes, SHA-256 format, duplicates, overlaps). Optional extra checks:

  --check-files DIR   every asset that points at --tag must exist in DIR with
                      the exact size and SHA-256 from the manifest
  --check-urls        every URL must be reachable on GitHub (HEAD request,
                      redirects followed). Needs network access.

Exit code 0 = valid, 1 = errors found.

Example:
  python tools/validate_manifest.py manifest/manifest.json \
      --app-id com.example.myapp --owner USER --repo MyFlutterApp-Assets \
      --check-files release-assets --tag v1.1.0
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from fdam_common import (  # noqa: E402
    GITHUB_HOSTS,
    sha256_file,
    url_problem,
    validate_manifest_dict,
    zip_problems,
)


def check_files(manifest: dict, folder: str, tag: str | None) -> list[str]:
    errors = []
    for a in manifest.get("assets", []):
        url = a.get("url", "")
        if tag and f"/releases/download/{tag}/" not in url:
            continue  # unchanged asset served from an older release
        path = os.path.join(folder, a["name"])
        if not os.path.isfile(path):
            errors.append(f"{a['id']}: file {path} is missing")
            continue
        size = os.path.getsize(path)
        if size != a["sizeBytes"]:
            errors.append(f"{a['id']}: size {size} != manifest {a['sizeBytes']}")
        digest = sha256_file(path)
        if digest != a["sha256"].lower():
            errors.append(f"{a['id']}: sha256 {digest[:12]}… != manifest {a['sha256'][:12]}…")
        if a.get("extract"):
            problems, total = zip_problems(path)
            errors.extend(f"{a['id']}: {p}" for p in problems)
            if a.get("extractedSizeBytes") not in (None, total):
                errors.append(f"{a['id']}: extractedSizeBytes {a['extractedSizeBytes']} != {total}")
    return errors


class _NoRedirectToForeignHosts(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        problem = url_problem(newurl, GITHUB_HOSTS)
        if problem:
            raise urllib.error.HTTPError(newurl, code, f"redirect rejected ({problem})", headers, fp)
        return super().redirect_request(req, fp, code, msg, headers, newurl)


def check_urls(manifest: dict, timeout: float = 20.0) -> list[str]:
    errors = []
    opener = urllib.request.build_opener(_NoRedirectToForeignHosts)
    for a in manifest.get("assets", []):
        req = urllib.request.Request(a["url"], method="HEAD", headers={"User-Agent": "fdam-validate/1.0"})
        try:
            with opener.open(req, timeout=timeout) as r:
                length = r.headers.get("Content-Length")
                if length is not None and int(length) != a["sizeBytes"]:
                    errors.append(f"{a['id']}: server size {length} != manifest {a['sizeBytes']}")
        except urllib.error.HTTPError as e:
            errors.append(f"{a['id']}: HTTP {e.code} for {a['url']}")
        except (urllib.error.URLError, TimeoutError, OSError) as e:
            errors.append(f"{a['id']}: cannot reach {a['url']} ({e})")
    return errors


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("manifest", nargs="?", default="manifest/manifest.json")
    ap.add_argument("--app-id", help="expected appId")
    ap.add_argument("--owner", help="restrict URLs to this GitHub owner")
    ap.add_argument("--repo", help="restrict URLs to this repository")
    ap.add_argument("--manager-version", default="1.0.0", help="FDAM version shipped in the app")
    ap.add_argument("--max-asset-size", type=int)
    ap.add_argument("--check-files", metavar="DIR")
    ap.add_argument("--tag", help="with --check-files: only check assets of this release tag")
    ap.add_argument("--check-urls", action="store_true")
    args = ap.parse_args(argv)

    try:
        with open(args.manifest, encoding="utf-8") as f:
            manifest = json.load(f)
    except FileNotFoundError:
        print(f"error: {args.manifest} not found", file=sys.stderr)
        return 1
    except json.JSONDecodeError as e:
        print(f"error: invalid JSON: {e}", file=sys.stderr)
        return 1

    prefixes = []
    if args.owner and args.repo:
        prefixes = [f"https://github.com/{args.owner}/{args.repo}/releases/download/"]
    errors = validate_manifest_dict(manifest, app_id=args.app_id, prefixes=prefixes,
                                    manager_version=args.manager_version, max_asset_size=args.max_asset_size)
    if not errors and args.check_files:
        errors += check_files(manifest, args.check_files, args.tag)
    if not errors and args.check_urls:
        errors += check_urls(manifest)

    if errors:
        print(f"INVALID: {len(errors)} problem(s) in {args.manifest}")
        for e in errors:
            print(f"  - {e}")
        return 1
    n = len(manifest["assets"])
    total = sum(a["sizeBytes"] for a in manifest["assets"])
    print(f"OK: {args.manifest} release {manifest['releaseVersion']}, {n} assets, {total} bytes")
    return 0


if __name__ == "__main__":
    sys.exit(main())

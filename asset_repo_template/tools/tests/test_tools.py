"""Tests for the manifest tools. Run: python -m unittest discover -s tools/tests"""

import io
import json
import os
import shutil
import sys
import tempfile
import unittest
import zipfile
from contextlib import redirect_stdout

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.dirname(HERE))

import calculate_hash  # noqa: E402
import generate_manifest  # noqa: E402
import validate_manifest  # noqa: E402
from fdam_common import relative_path_problem, semver_key, sha256_file  # noqa: E402


class ToolsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="fdam_tools_")
        self.src = os.path.join(self.tmp, "release-assets")
        os.makedirs(self.src)
        self.out = os.path.join(self.tmp, "manifest", "manifest.json")
        self.cfg = os.path.join(self.tmp, "assets_config.json")
        with open(self.cfg, "w") as f:
            json.dump({
                "appId": "com.example.myapp",
                "assets": {
                    "audio.zip": {"id": "audio_pack_01", "category": "audio", "localPath": "audio/audio.zip",
                                  "required": True, "downloadOnStartup": True, "extract": True},
                    "main.db": {"id": "main_db", "required": True},
                },
            }, f)
        self._write_zip("audio.zip", {"a.mp3": os.urandom(5000), "sub/b.wav": os.urandom(3000)})
        self._write("logo.png", os.urandom(2000))
        self._write("main.db", os.urandom(4000))

    def tearDown(self):
        shutil.rmtree(self.tmp)

    def _write(self, name, data):
        with open(os.path.join(self.src, name), "wb") as f:
            f.write(data)

    def _write_zip(self, name, entries):
        with zipfile.ZipFile(os.path.join(self.src, name), "w", zipfile.ZIP_DEFLATED) as z:
            for n, d in entries.items():
                z.writestr(n, d)

    def gen(self, tag, previous=None, extra=()):
        argv = ["--owner", "USER", "--repo", "MyFlutterApp-Assets", "--tag", tag, "--source", self.src,
                "--output", self.out, "--config", self.cfg,
                "--upload-list", os.path.join(self.tmp, "upload.txt"), *extra]
        if previous:
            argv += ["--previous", previous]
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = generate_manifest.main(argv)
        return rc, buf.getvalue()

    def manifest(self):
        with open(self.out) as f:
            return json.load(f)

    def uploads(self):
        with open(os.path.join(self.tmp, "upload.txt")) as f:
            return [os.path.basename(x) for x in f.read().split()]

    def test_generates_valid_manifest_with_real_hashes(self):
        rc, out = self.gen("v1.0.0")
        self.assertEqual(rc, 0, out)
        m = self.manifest()
        self.assertEqual(m["appId"], "com.example.myapp")
        self.assertEqual(m["releaseVersion"], "1.0.0")
        by_id = {a["id"]: a for a in m["assets"]}
        self.assertEqual(set(by_id), {"audio_pack_01", "logo", "main_db"})
        audio = by_id["audio_pack_01"]
        self.assertEqual(audio["sha256"], sha256_file(os.path.join(self.src, "audio.zip")))
        self.assertEqual(audio["url"],
                         "https://github.com/USER/MyFlutterApp-Assets/releases/download/v1.0.0/audio.zip")
        self.assertTrue(audio["extract"])
        self.assertEqual(audio["extractedSizeBytes"], 8000)
        self.assertEqual(by_id["logo"]["category"], "image")
        self.assertEqual(by_id["logo"]["localPath"], "images/logo.png")
        self.assertEqual(by_id["main_db"]["category"], "database")
        self.assertEqual(by_id["main_db"]["localPath"], "main.db")
        self.assertEqual(sorted(self.uploads()), ["audio.zip", "logo.png", "main.db"])
        with open(os.path.join(self.tmp, "manifest", "manifest-version.json")) as f:
            mv = json.load(f)
        self.assertEqual(mv["manifestSha256"], sha256_file(self.out))
        # Validator agrees.
        with redirect_stdout(io.StringIO()):
            self.assertEqual(validate_manifest.main([self.out, "--app-id", "com.example.myapp",
                                                     "--owner", "USER", "--repo", "MyFlutterApp-Assets",
                                                     "--check-files", self.src, "--tag", "v1.0.0"]), 0)

    def test_update_only_changed_file(self):
        self.assertEqual(self.gen("v1.0.0")[0], 0)
        prev = os.path.join(self.tmp, "prev.json")
        shutil.copy(self.out, prev)
        self._write("logo.png", os.urandom(2100))
        rc, out = self.gen("v1.1.0", previous=prev)
        self.assertEqual(rc, 0, out)
        by_id = {a["id"]: a for a in self.manifest()["assets"]}
        self.assertEqual(by_id["logo"]["version"], "1.1.0")
        self.assertIn("/v1.1.0/logo.png", by_id["logo"]["url"])
        self.assertEqual(by_id["audio_pack_01"]["version"], "1.0.0")
        self.assertIn("/v1.0.0/audio.zip", by_id["audio_pack_01"]["url"])
        self.assertEqual(self.uploads(), ["logo.png"])

    def test_release_version_must_increase_when_files_change(self):
        self.assertEqual(self.gen("v1.0.0")[0], 0)
        prev = os.path.join(self.tmp, "prev.json")
        shutil.copy(self.out, prev)
        self._write("logo.png", os.urandom(10))
        rc, out = self.gen("v1.0.0", previous=prev)
        self.assertEqual(rc, 1)
        self.assertIn("must be newer", out)

    def test_missing_file_in_config_and_bad_names_fail(self):
        with open(self.cfg) as f:
            cfg = json.load(f)
        cfg["assets"]["gone.mp3"] = {"required": True}
        with open(self.cfg, "w") as f:
            json.dump(cfg, f)
        self._write("bad name.png", b"x")
        rc, out = self.gen("v1.0.0")
        self.assertEqual(rc, 1)
        self.assertIn("gone.mp3", out)
        self.assertIn("bad name.png", out)
        self.assertFalse(os.path.exists(self.out), "nothing written on failure")

    def test_duplicate_ids_rejected(self):
        with open(self.cfg) as f:
            cfg = json.load(f)
        cfg["assets"]["logo.png"] = {"id": "main_db"}
        with open(self.cfg, "w") as f:
            json.dump(cfg, f)
        rc, out = self.gen("v1.0.0")
        self.assertEqual(rc, 1)
        self.assertIn("duplicate id", out)

    def test_zip_slip_archive_rejected(self):
        with zipfile.ZipFile(os.path.join(self.src, "evil.zip"), "w") as z:
            z.writestr("../../escape.txt", b"x")
        rc, out = self.gen("v1.0.0")
        self.assertEqual(rc, 1)
        self.assertIn("traversal", out)

    def test_validator_rejects_placeholders_and_bad_urls(self):
        self.assertEqual(self.gen("v1.0.0")[0], 0)
        m = self.manifest()
        m["assets"][0]["sha256"] = "REAL_SHA256_HASH"
        m["assets"][1]["url"] = "http://example.com/x"
        m["assets"][2]["localPath"] = "../x"
        bad = os.path.join(self.tmp, "bad.json")
        with open(bad, "w") as f:
            json.dump(m, f)
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = validate_manifest.main([bad])
        self.assertEqual(rc, 1)
        text = buf.getvalue()
        self.assertIn("sha256", text)
        self.assertIn("not_https", text)
        self.assertIn("unsafe path", text)

    def test_validator_detects_changed_file(self):
        self.assertEqual(self.gen("v1.0.0")[0], 0)
        self._write("logo.png", os.urandom(2000))
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = validate_manifest.main([self.out, "--check-files", self.src])
        self.assertEqual(rc, 1)
        self.assertIn("logo: sha256", buf.getvalue())

    def test_calculate_hash(self):
        buf = io.StringIO()
        with redirect_stdout(buf):
            rc = calculate_hash.main(["--json", os.path.join(self.src, "logo.png")])
        self.assertEqual(rc, 0)
        row = json.loads(buf.getvalue())[0]
        self.assertEqual(row["sizeBytes"], 2000)
        self.assertEqual(row["sha256"], sha256_file(os.path.join(self.src, "logo.png")))

    def test_helpers(self):
        self.assertIsNone(relative_path_problem("audio/a.mp3"))
        for bad in ["../a", "/a", "a\\b", "C:/a", "a//b"]:
            self.assertIsNotNone(relative_path_problem(bad), bad)
        self.assertLess(semver_key("1.0.0-rc.1"), semver_key("1.0.0"))
        self.assertLess(semver_key("1.9.0"), semver_key("1.10.0"))


if __name__ == "__main__":
    unittest.main()

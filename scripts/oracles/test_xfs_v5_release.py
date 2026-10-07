"""Tests of the job contract, not tests of the XFS format or Apple's FSKit."""

import copy
import importlib.util
import io
import json
import plistlib
import sys
import tempfile
import unittest
from contextlib import contextmanager, redirect_stdout
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "xfs-v5-release.py"
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("xfs_release", SCRIPT)
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class MatrixTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.image = self.root / "fixture.img"
        self.image.write_bytes(b"independently supplied fixture")
        self.matrix = []
        for name, (mode, features) in runner.REQUIRED.items():
            broken = name in ("repairable", "unrepairable", "unsupported")
            self.matrix.append(
                {
                    "id": name,
                    "mode": mode,
                    "features": features,
                    "image": "fixture.img",
                    "sha256": runner.digest(self.image),
                    "files": {"sf/aaaa": "a" * 64},
                    "check": {
                        "exit": 1 if broken else 0,
                        "pattern": "corruption" if broken else "",
                    },
                    "repair": {
                        "exit": 1 if name in ("unrepairable", "unsupported") else 0,
                        "pattern": "unsupported"
                        if name == "unsupported"
                        else "corruption",
                    },
                    "mount": {
                        "exit": 1 if name == "unsupported" else 0,
                        "pattern": "unsupported",
                    },
                }
            )

    def load(self, matrix=None):
        path = self.root / "matrix.json"
        path.write_text(json.dumps(self.matrix if matrix is None else matrix))
        return runner.load_matrix(path)

    def test_complete_matrix(self):
        self.assertEqual(len(self.load()), len(runner.REQUIRED))

    def test_missing_or_duplicate_case(self):
        for matrix in (self.matrix[:-1], self.matrix + [self.matrix[0]]):
            with self.assertRaises(ValueError):
                self.load(matrix)

    def test_bad_fixture_hash(self):
        self.image.write_bytes(b"wrong fixture")
        with self.assertRaises(ValueError):
            self.load()

    def test_missing_fixture_is_failure(self):
        self.matrix[0]["image"] = "absent.img"
        with self.assertRaises(FileNotFoundError):
            self.load()

    def test_paths_cannot_escape_mount(self):
        for path in ("../escape", "/escape", "sf/../../escape", ""):
            with self.assertRaises(ValueError):
                runner.relative_path(path)

    def test_wrong_mode_features_or_check_expectation(self):
        for field, value in (
            ("mode", "deny"),
            ("features", []),
            ("check", {"exit": 1, "pattern": ""}),
        ):
            matrix = copy.deepcopy(self.matrix)
            matrix[0][field] = value
            with self.assertRaises(ValueError):
                self.load(matrix)

    def test_refusal_needs_exact_status_and_diagnostic(self):
        runner.expect_result(
            1, "unsupported feature", {"exit": 1, "pattern": "unsupported"}
        )
        for code, output in (
            (0, "unsupported"),
            (69, "unsupported"),
            (1, "module disabled"),
        ):
            with self.assertRaises(ValueError):
                runner.expect_result(
                    code, output, {"exit": 1, "pattern": "unsupported"}
                )

    def test_oracle_must_check_features_contents_and_filesystem(self):
        expected = {"sf/aaaa": "a" * 64, "removed": None}
        report = {
            "filesystem_version": 5,
            "features": ["crc"],
            "files": expected,
            "verdict": "clean",
            "kernel_version": "Linux test",
            "xfsprogs_version": "test",
        }
        runner.validate_oracle(report, ["crc"], expected, "clean")
        for field, value in (
            ("filesystem_version", 4),
            ("features", []),
            ("files", {}),
            ("verdict", "corrupt"),
            ("kernel_version", ""),
        ):
            bad = dict(report, **{field: value})
            with self.assertRaises(ValueError):
                runner.validate_oracle(bad, ["crc"], expected, "clean")

    def test_write_workload_and_remount_expectations(self):
        mounted = self.root / "mounted"
        mounted.mkdir()
        expected = runner.write_workload(mounted)
        runner.verify_files(mounted, expected)
        self.assertIsNone(expected["dj-release/removed"])
        (mounted / "dj-release/renamed").write_bytes(b"lost write")
        with self.assertRaises(ValueError):
            runner.verify_files(mounted, expected)

    def test_read_only_denial_is_not_permission_denial(self):
        import errno

        self.assertTrue(runner.write_denied(OSError(errno.EROFS, "read-only")))
        self.assertTrue(runner.write_denied(OSError(errno.ENOTSUP, "unsupported")))
        self.assertFalse(runner.write_denied(OSError(errno.EACCES, "permissions")))

    def test_write_expectation_does_not_trust_driver_readback(self):
        mounted = self.root / "mounted"
        mounted.mkdir()
        with patch.object(runner, "digest", return_value="a" * 64):
            expected = runner.write_workload(mounted)
        self.assertNotEqual(expected["dj-release/renamed"], "a" * 64)

    def test_appended_bytes_survive_in_a_separate_file(self):
        mounted = self.root / "mounted"
        mounted.mkdir()
        expected = runner.write_workload(mounted)
        self.assertEqual(
            expected["dj-release/appended"],
            runner.hashlib.sha256(b"prefix\nsuffix\n").hexdigest(),
        )

    def test_attached_device_detaches_on_failure(self):
        job = runner.Job(self.root)
        calls = []

        def command(args, expected=None):
            calls.append(args)
            return plistlib.dumps({"system-entities": [{"dev-entry": "/dev/disk999"}]})

        with (
            patch.object(job, "command", side_effect=command),
            self.assertRaisesRegex(ValueError, "body failed"),
            job.attached(self.image),
        ):
            raise ValueError("body failed")
        self.assertEqual(calls[-1], ["/usr/bin/hdiutil", "detach", "/dev/disk999"])

    def test_partitioned_fixture_refused_and_detached(self):
        job = runner.Job(self.root)
        result = plistlib.dumps(
            {
                "system-entities": [
                    {"dev-entry": "/dev/disk999"},
                    {"dev-entry": "/dev/disk999s1"},
                ]
            }
        )
        with (
            patch.object(job, "command", return_value=result) as command,
            self.assertRaises(ValueError),
            job.attached(self.image),
        ):
            self.fail("partitioned fixture reached the job")
        self.assertEqual(
            command.call_args.args[0], ["/usr/bin/hdiutil", "detach", "/dev/disk999"]
        )

    def test_mount_success_requires_mount_table_evidence_and_cleanup(self):
        job = runner.Job(self.root)
        with (
            patch.object(job, "command", return_value=b"") as command,
            self.assertRaisesRegex(ValueError, "mount table"),
            job.mounted("/dev/disk999", self.root, False, {"exit": 0}),
        ):
            self.fail("empty mount table reached the job")
        self.assertEqual(
            command.call_args.args[0], ["sudo", "-n", "/sbin/umount", self.root]
        )

    def test_failed_mount_does_not_unmount_another_volume(self):
        job = runner.Job(self.root)
        with (
            patch.object(job, "command", return_value=b"unsupported") as command,
            job.mounted(
                "/dev/disk999", self.root, False, {"exit": 1, "pattern": "unsupported"}
            ) as mounted,
        ):
            self.assertFalse(mounted)
        self.assertEqual(command.call_count, 1)

    def test_command_retains_failure_transcript(self):
        job = runner.Job(self.root)
        with self.assertRaises(ValueError):
            job.command(["/bin/sh", "-c", "echo module-disabled >&2; exit 69"])
        log = json.loads((self.root / "command-001.json").read_text())
        self.assertEqual(log["exit"], 69)
        self.assertIn("module-disabled", log["output"])

    def fake_job(self, mutate_check=False, corrupt_oracle=False, case_id="rw-base"):
        """Exercise orchestration with local directories, never claim an FSKit result."""
        case = next(c for c in self.matrix if c["id"] == case_id)
        case["files"] = {"sf/aaaa": runner.hashlib.sha256(b"Linux seed\n").hexdigest()}

        class FakeJob(runner.Job):
            @contextmanager
            def attached(self, image, readonly=False):
                self.image = image
                yield "/dev/disk999"

            @contextmanager
            def mounted(self, device, mountpoint, readonly, expected):
                seed = mountpoint / "sf/aaaa"
                if not seed.exists():
                    seed.parent.mkdir()
                    seed.write_bytes(b"Linux seed\n")
                yield expected["exit"] == 0

            def command(self, args, expected=None):
                if args[-2] == "-n" and "fsck_fskit" in str(args):
                    if mutate_check:
                        self.image.write_bytes(b"check must not write")
                    return b""
                if "-y" in args:
                    if case_id == "repairable":
                        self.image.write_bytes(b"independent known repair result")
                    return b""
                expectation = json.loads(Path(args[2]).read_text())
                report = {
                    **expectation,
                    "filesystem_version": 5,
                    "kernel_version": "test kernel",
                    "xfsprogs_version": "test tools",
                }
                if corrupt_oracle:
                    report["files"] = {}
                return json.dumps(report).encode()

        return FakeJob(self.root), next(c for c in self.load() if c["id"] == case_id)

    def test_case_remount_oracle_and_source_preservation(self):
        job, case = self.fake_job()
        source_sha = runner.digest(self.image)
        job.case(case, "/test/oracle")
        result = json.loads((self.root / "rw-base/result.json").read_text())
        self.assertTrue(result["passed"])
        self.assertEqual(runner.digest(self.image), source_sha)
        self.assertIn("dj-release/renamed", result["oracle"]["files"])

    def test_mutating_check_fails_before_mount(self):
        job, case = self.fake_job(mutate_check=True)
        with self.assertRaisesRegex(ValueError, "read-only check changed"):
            job.case(case, "/test/oracle")
        self.assertFalse((self.root / "rw-base/result.json").exists())

    def test_bad_oracle_never_marks_case_passed(self):
        job, case = self.fake_job(corrupt_oracle=True)
        with self.assertRaisesRegex(ValueError, "Linux oracle disagrees"):
            job.case(case, "/test/oracle")
        self.assertFalse((self.root / "rw-base/result.json").exists())

    def test_failed_preflight_records_failed_summary(self):
        self.load()
        release = self.root / "release.json"
        release.write_text("{}")
        output = self.root / "output"
        argv = [
            str(SCRIPT),
            "--matrix",
            str(self.root / "matrix.json"),
            "--app",
            str(self.root / "app"),
            "--release-evidence",
            str(release),
            "--oracle",
            "/missing/oracle",
            "--output",
            str(output),
        ]
        with (
            patch("sys.argv", argv),
            patch.object(runner.platform, "system", return_value="Darwin"),
            patch.object(runner.platform, "mac_ver", return_value=("26.0", (), "")),
            self.assertRaises(KeyError),
        ):
            runner.main()
        self.assertFalse(json.loads((output / "summary.json").read_text())["passed"])

    def test_read_only_cases_require_denied_write_and_unchanged_image(self):
        import errno

        original_open = Path.open

        def denied_open(path, *args, **kwargs):
            if path.name == "dj-release-probe":
                raise OSError(errno.EROFS, "read-only")
            return original_open(path, *args, **kwargs)

        for case_id in ("ro-request", "ro-resource"):
            job, case = self.fake_job(case_id=case_id)
            with patch.object(Path, "open", denied_open):
                job.case(case, "/test/oracle")
            result = json.loads((self.root / case_id / "result.json").read_text())
            self.assertEqual(result["before_sha256"], result["after_sha256"])

    def test_read_only_case_cannot_pass_when_write_succeeds(self):
        job, case = self.fake_job(case_id="ro-request")
        with self.assertRaisesRegex(ValueError, "accepted a write"):
            job.case(case, "/test/oracle")
        self.assertFalse((self.root / "ro-request/result.json").exists())

    def test_repair_and_refusal_cases_have_distinct_oracle_verdicts(self):
        for case_id, verdict in (
            ("repairable", "clean"),
            ("unrepairable", "corrupt"),
            ("unsupported", "unsupported"),
        ):
            job, case = self.fake_job(case_id=case_id)
            job.case(case, "/test/oracle")
            result = json.loads((self.root / case_id / "result.json").read_text())
            self.assertEqual(result["oracle"]["verdict"], verdict)
            self.assertEqual(
                result["before_sha256"] == result["after_sha256"],
                case_id != "repairable",
            )

    def test_main_checks_build_receipt_and_records_complete_run(self):
        self.load()
        bundle = self.root / "lib/bundle_xfs"
        bundle.mkdir(parents=True)
        (bundle / "VERSION.txt").write_text("  rust-fs-xfs 1.2.3\n")
        archive = bundle / "libdj_xfs_bundle.a"
        archive.write_bytes(b"published bundle")
        lock = self.root / "rust-bundles/dj-xfs-bundle/Cargo.lock"
        lock.parent.mkdir(parents=True)
        lock.write_text('[[package]]\nname = "rust-fs-xfs"\nversion = "1.2.3"\n')
        app = self.root / "DiskJockey.app"
        extension = app / "Contents/Extensions/DiskJockeyXFS.appex"
        binary = extension / "Contents/MacOS/DiskJockeyXFS"
        binary.parent.mkdir(parents=True)
        binary.write_bytes(b"signed candidate")
        release = self.root / "release.json"
        receipt = {
            "driver_version": "1.2.3",
            "extension_sha256": runner.digest(binary),
            "archive_sha256": runner.digest(archive),
            "rust_release_url": "https://example.test/release",
            "rust_gates_url": "https://example.test/gates",
            "fixture_provenance_url": "https://example.test/fixtures",
        }
        release.write_text(json.dumps(receipt))
        output = self.root / "output"
        argv = [
            str(SCRIPT),
            "--matrix",
            str(self.root / "matrix.json"),
            "--app",
            str(app),
            "--release-evidence",
            str(release),
            "--oracle",
            "/usr/bin/true",
            "--output",
            str(output),
        ]

        def command(job, args, expected=None):
            if "pluginkit" in str(args):
                return f"Path = {extension}\n".encode()
            return b"test-commit"

        with (
            patch("sys.argv", argv),
            patch.object(runner, "ROOT", self.root),
            patch.object(runner.platform, "system", return_value="Darwin"),
            patch.object(runner.platform, "mac_ver", return_value=("26.0", (), "")),
            patch.object(runner.Job, "command", command),
            patch.object(runner.Job, "case") as case,
        ):
            runner.main()
        self.assertEqual(case.call_count, len(runner.REQUIRED))
        self.assertTrue(json.loads((output / "summary.json").read_text())["passed"])
        self.assertEqual(
            json.loads((output / "release.json").read_text())["release"], receipt
        )


if __name__ == "__main__":
    # Fake-job verdicts must not appear as successful real FSKit release runs.
    with redirect_stdout(io.StringIO()):
        unittest.main()

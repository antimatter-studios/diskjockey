#!/usr/bin/env python3
"""A fail-closed, destructive-on-copies macOS FSKit release job for XFS v5."""

import argparse
import errno
import hashlib
import json
import os
import platform
import plistlib
import re
import shutil
import subprocess
import sys
from contextlib import contextmanager
from pathlib import Path, PurePosixPath

ROOT = Path(__file__).resolve().parents[1]
REQUIRED = {
    "rw-base": ("rw", ["crc"]),
    "rw-features": ("rw", ["crc", "finobt", "inobtcount", "rmapbt", "reflink"]),
    "rw-encoding": ("rw", ["crc", "bigtime", "nrext64", "sparse"]),
    "ro-request": ("deny", ["crc"]),
    "ro-resource": ("deny", ["crc"]),
    "unsupported": ("reject", ["crc"]),
    "repairable": ("rw", ["crc"]),
    "unrepairable": ("reject", ["crc"]),
}


def digest(path):
    with Path(path).open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def relative_path(path):
    value = PurePosixPath(path)
    if not path or value.is_absolute() or ".." in value.parts or str(value) == ".":
        raise ValueError(f"unsafe fixture path: {path!r}")
    return value


def expect_result(code, output, expected):
    if code != expected["exit"] or (
        expected.get("pattern") and not re.search(expected["pattern"], output)
    ):
        raise ValueError(f"expected {expected}, got exit {code}: {output[-1000:]}")


def load_matrix(path):
    path = Path(path).resolve()
    cases = json.loads(path.read_text())
    if not isinstance(cases, list) or sorted(c["id"] for c in cases) != sorted(
        REQUIRED
    ):
        raise ValueError("matrix must contain each required case exactly once")
    for case in cases:
        mode, features = REQUIRED[case["id"]]
        if case["mode"] != mode or not set(features).issubset(case["features"]):
            raise ValueError(f"incorrect mode/features: {case['id']}")
        case["image"] = str((path.parent / relative_path(case["image"])).resolve())
        if digest(case["image"]) != case["sha256"]:
            raise ValueError(f"fixture digest mismatch: {case['id']}")
        for name, sha in case["files"].items():
            relative_path(name)
            if not re.fullmatch(r"[0-9a-f]{64}", sha):
                raise ValueError(f"invalid seed file digest: {name}")
            if PurePosixPath(name).parts[0].startswith("dj-release"):
                raise ValueError("fixture uses the reserved workload directory")
        if mode != "reject" and not case["files"]:
            raise ValueError("mounted cases need Linux-derived seed file hashes")
        for operation in ("check", "repair", "mount"):
            expected = case[operation]
            if type(expected["exit"]) is not int or not 0 <= expected["exit"] <= 255:
                raise ValueError("expected exit must be an exact status in 0..255")
            re.compile(expected.get("pattern", ""))
            if expected["exit"] and not expected.get("pattern"):
                raise ValueError(
                    "refusal needs a reviewed diagnostic, not merely nonzero"
                )
        broken = case["id"] in ("repairable", "unrepairable", "unsupported")
        if (case["check"]["exit"] != 0) != broken:
            raise ValueError(
                "clean and corrupt checks must have different expected results"
            )
        if case["id"] in ("unsupported", "unrepairable"):
            if not case["repair"]["exit"]:
                raise ValueError("unsupported/unrepairable repair must refuse")
        elif case["repair"]["exit"] != 0:
            raise ValueError("supported repair must succeed")
        if case["id"] == "unsupported" and not case["mount"]["exit"]:
            raise ValueError("unsupported mount must refuse")
        if mode != "reject" and case["mount"]["exit"] != 0:
            raise ValueError("supported mount must succeed")
    return cases


def validate_oracle(report, features, files, verdict):
    if (
        report["filesystem_version"] != 5
        or set(report["features"]) != set(features)
        or report["files"] != files
        or report["verdict"] != verdict
        or not report["kernel_version"]
        or not report["xfsprogs_version"]
    ):
        raise ValueError(
            "Linux oracle disagrees with features, contents or check/repair outcome"
        )


def verify_files(mountpoint, expected):
    for name, sha in expected.items():
        path = mountpoint / relative_path(name)
        # A seed symlink must not turn a content check into a host-file read.
        if path.is_symlink() or not path.resolve().is_relative_to(mountpoint.resolve()):
            raise ValueError(f"fixture path escapes the volume: {name}")
        if (sha is None and path.exists()) or (sha is not None and digest(path) != sha):
            raise ValueError(f"persisted content mismatch: {name}")


def write_workload(mountpoint):
    directory = mountpoint / "dj-release"
    directory.mkdir()
    data = directory / "created"
    payload = bytearray(b"XFS v5 release validation\n" * 1024)
    with data.open("wb") as stream:
        stream.write(payload)
        stream.flush()
        os.fsync(stream.fileno())
    payload[37 : 37 + len(b"overwrite persists")] = b"overwrite persists"
    payload.extend(b"append persists\n")
    del payload[8193:]
    with data.open("r+b") as stream:
        stream.seek(37)
        stream.write(b"overwrite persists")
        stream.seek(0, 2)
        stream.write(b"append persists\n")
        stream.truncate(8193)
        stream.flush()
        os.fsync(stream.fileno())
    data.rename(directory / "renamed")
    appended = directory / "appended"
    appended.write_bytes(b"prefix\n")
    with appended.open("ab") as stream:
        stream.write(b"suffix\n")
        stream.flush()
        os.fsync(stream.fileno())
    removed = directory / "removed"
    removed.write_bytes(b"unlink persists")
    removed.unlink()
    return {
        "dj-release/renamed": hashlib.sha256(payload).hexdigest(),
        "dj-release/appended": hashlib.sha256(b"prefix\nsuffix\n").hexdigest(),
        "dj-release/removed": None,
    }


def write_denied(error):
    return error.errno in (errno.EROFS, errno.ENOTSUP, errno.EOPNOTSUPP)


class Job:
    def __init__(self, evidence):
        self.evidence = evidence
        self.sequence = 0

    def command(self, args, expected=None):
        self.sequence += 1
        result = subprocess.run(
            [str(a) for a in args], capture_output=True, timeout=120, check=False
        )
        output = (result.stdout + result.stderr).decode(errors="replace")
        record = {
            "argv": [str(a) for a in args],
            "exit": result.returncode,
            "output": output,
        }
        (self.evidence / f"command-{self.sequence:03}.json").write_text(
            json.dumps(record, indent=2)
        )
        expect_result(result.returncode, output, expected or {"exit": 0})
        return result.stdout

    @contextmanager
    def attached(self, image, readonly=False):
        args = [
            "/usr/bin/hdiutil",
            "attach",
            "-nomount",
            "-nobrowse",
            "-noverify",
            "-plist",
            "-imagekey",
            "diskimage-class=CRawDiskImage",
            "-readonly" if readonly else "-readwrite",
            image,
        ]
        result = plistlib.loads(self.command(args))
        devices = [
            e["dev-entry"] for e in result["system-entities"] if "dev-entry" in e
        ]
        if not devices:
            raise ValueError("hdiutil did not return a device")
        try:
            if len(devices) != 1 or not re.fullmatch(r"/dev/disk[0-9]+", devices[0]):
                raise ValueError(
                    "use a raw whole-volume fixture, not a partitioned image"
                )
            yield devices[0]
        finally:
            self.command(["/usr/bin/hdiutil", "detach", devices[0]])

    @contextmanager
    def mounted(self, device, mountpoint, readonly, expected):
        self.command(
            [
                "sudo",
                "-n",
                "/sbin/mount",
                "-F",
                "-t",
                "xfs",
                "-o",
                "rdonly" if readonly else "rw",
                device,
                mountpoint,
            ],
            expected,
        )
        if expected["exit"]:
            yield False
            return
        try:
            table = self.command(["/sbin/mount"]).decode()
            if not any(
                f" on {mountpoint} (" in line and re.search(r"\((?:fs)?xfs[,)]", line)
                for line in table.splitlines()
            ):
                raise ValueError(
                    "mount returned success without an XFS volume in the mount table"
                )
            yield True
        finally:
            self.command(["sudo", "-n", "/sbin/umount", mountpoint])

    def case(self, case, oracle):
        directory = self.evidence / case["id"]
        directory.mkdir()
        image = directory / "volume.img"
        shutil.copyfile(case["image"], image)
        before = digest(image)
        expected_files = dict(case["files"])
        with self.attached(image) as device:
            self.command(
                ["sudo", "-n", "/sbin/fsck_fskit", "-t", "xfs", "-n", device],
                case["check"],
            )
        if digest(image) != before:
            raise ValueError("read-only check changed image bytes")
        with self.attached(image) as device:
            self.command(
                ["sudo", "-n", "/sbin/fsck_fskit", "-t", "xfs", "-y", device],
                case["repair"],
            )
        after_repair = digest(image)
        if case["id"] == "repairable":
            if after_repair == before:
                raise ValueError(
                    "repair reported success without repairing the known corruption"
                )
        elif after_repair != before:
            raise ValueError("clean/refused repair changed image bytes")
        if case["id"] not in ("unsupported", "unrepairable"):
            with self.attached(image) as device:
                self.command(
                    ["sudo", "-n", "/sbin/fsck_fskit", "-t", "xfs", "-n", device]
                )
            if digest(image) != after_repair:
                raise ValueError("post-repair check changed image bytes")
        mountpoint = directory / "mount"
        mountpoint.mkdir()
        if case["id"] != "unrepairable":
            # Separate contexts make the unmount-before-detach ordering explicit.
            with self.attached(image, case["id"] == "ro-resource") as device:  # noqa: SIM117
                with self.mounted(
                    device, mountpoint, case["id"] == "ro-request", case["mount"]
                ) as mounted:
                    if mounted:
                        verify_files(mountpoint, expected_files)
                        if case["mode"] == "rw":
                            expected_files.update(write_workload(mountpoint))
                        else:
                            try:
                                with (mountpoint / "dj-release-probe").open(
                                    "xb"
                                ) as stream:
                                    stream.write(b"must refuse")
                            except OSError as error:
                                if not write_denied(error):
                                    raise
                            else:
                                raise ValueError("read-only volume accepted a write")
            if case["mode"] != "reject":
                # A new attachment and mount discard both extension and device caches.
                with self.attached(image) as device:  # noqa: SIM117
                    with self.mounted(device, mountpoint, True, {"exit": 0}):
                        verify_files(mountpoint, expected_files)
                before_check = digest(image)
                with self.attached(image) as device:
                    self.command(
                        ["sudo", "-n", "/sbin/fsck_fskit", "-t", "xfs", "-n", device]
                    )
                if digest(image) != before_check:
                    raise ValueError("post-write check changed image bytes")
        after = digest(image)
        if case["mode"] != "rw" and after != before:
            raise ValueError(
                "read-only/unsupported/unrepairable case changed image bytes"
            )
        expectation = {
            "features": case["features"],
            "files": expected_files if case["mode"] != "reject" else {},
            "verdict": "unsupported"
            if case["id"] == "unsupported"
            else "corrupt"
            if case["id"] == "unrepairable"
            else "clean",
        }
        expected_path = directory / "oracle-expectation.json"
        expected_path.write_text(json.dumps(expectation, indent=2))
        report = json.loads(self.command([oracle, image, expected_path, directory]))
        validate_oracle(report, **expectation)
        if digest(image) != after:
            raise ValueError("independent oracle modified the evidence image")
        (directory / "result.json").write_text(
            json.dumps(
                {
                    "id": case["id"],
                    "before_sha256": before,
                    "after_repair_sha256": after_repair,
                    "after_sha256": after,
                    "oracle": report,
                    "passed": True,
                },
                indent=2,
            )
        )
        print(f"PASS {case['id']}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("matrix", "app", "release-evidence", "oracle", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    args.output = args.output.resolve()
    args.output.mkdir(parents=True, exist_ok=False)
    job = Job(args.output)
    passed = False
    try:
        if (
            platform.system() != "Darwin"
            or int(platform.mac_ver()[0].split(".")[0]) < 26
        ):
            raise ValueError(
                "requires macOS 26, signed FSKit app and an interactive GUI session"
            )
        cases = load_matrix(args.matrix)
        release = json.loads(args.release_evidence.read_text())
        for field in ("rust_release_url", "rust_gates_url", "fixture_provenance_url"):
            if not release[field].startswith("https://"):
                raise ValueError(f"reviewed evidence URL required: {field}")
        version = release["driver_version"]
        provenance = (ROOT / "lib/bundle_xfs/VERSION.txt").read_text()
        if f"  rust-fs-xfs {version}\n" not in provenance:
            raise ValueError(
                "driver version differs from vendored VERSION.txt; run make vendor-bundles"
            )
        import tomllib

        lock = tomllib.loads(
            (ROOT / "rust-bundles/dj-xfs-bundle/Cargo.lock").read_text()
        )
        versions = [p["version"] for p in lock["package"] if p["name"] == "rust-fs-xfs"]
        extension = args.app.resolve() / "Contents/Extensions/DiskJockeyXFS.appex"
        binary = extension / "Contents/MacOS/DiskJockeyXFS"
        if versions != [version] or digest(binary) != release["extension_sha256"]:
            raise ValueError(
                "reviewed release provenance does not match lockfile/extension binary"
            )
        archive = ROOT / "lib/bundle_xfs/libdj_xfs_bundle.a"
        if digest(archive) != release["archive_sha256"]:
            raise ValueError(
                "reviewed release provenance does not match vendored archive"
            )
        if not args.oracle.is_absolute() or not os.access(args.oracle, os.X_OK):
            raise ValueError(
                "provide an executable absolute --oracle adapter; see docs/xfs-v5-release-validation.md"
            )
        job.command(["/usr/bin/codesign", "--verify", "--strict", extension])
        registry = job.command(
            [
                "/usr/bin/pluginkit",
                "-mAvvv",
                "-i",
                "com.antimatterstudios.diskjockey.xfs",
            ]
        ).decode()
        paths = re.findall(r"Path = (.+)", registry)
        if len(paths) != 1 or Path(paths[0].strip()).resolve() != extension:
            raise ValueError(
                "register and enable exactly the reviewed app's XFS extension; see the mount runbook"
            )
        job.command(["sudo", "-n", "true"])
        (args.output / "release.json").write_text(
            json.dumps(
                {
                    "release": release,
                    "resolved_crates": provenance,
                    "lock_sha256": digest(
                        ROOT / "rust-bundles/dj-xfs-bundle/Cargo.lock"
                    ),
                    "macos": platform.mac_ver()[0],
                    "commit": job.command(["git", "-C", ROOT, "rev-parse", "HEAD"])
                    .decode()
                    .strip(),
                },
                indent=2,
            )
        )
        (args.output / "matrix.json").write_text(args.matrix.read_text())
        for case in cases:
            job.case(case, args.oracle)
        passed = True
    finally:
        (args.output / "summary.json").write_text(
            json.dumps({"passed": passed, "required_cases": len(REQUIRED)})
        )
    print(
        f"XFS v5 release: {len(REQUIRED)} cases passed; driver {version}; evidence {args.output}"
    )


if __name__ == "__main__":
    try:
        main()
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        subprocess.SubprocessError,
    ) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        sys.exit(1)

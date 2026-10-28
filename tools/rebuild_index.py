#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""Rebuild Cydia/Sileo repo index (Packages / Packages.bz2 / Packages.xz / Packages.gz / Release)
for a debs/ directory. Pure-python .deb parsing (ar + tar), no dpkg required.

Usage:  python3 tools/rebuild_index.py   (run from repo root)
"""
import bz2
import gzip
import glob
import hashlib
import io
import lzma
import os
import re
import struct
import tarfile
import time
import datetime

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # repo root
DEBS_DIR = os.path.join(ROOT, "debs")

ORIGIN = "陈先生源"
LABEL = "陈先生源"
DESC = "陈先生源 - Airaw 系列插件越狱源"


# ---------- .deb parsing (ar archive + control.tar) ----------
def parse_ar(data):
    if data[:8] != b"!<arch>\n":
        raise ValueError("not an ar archive")
    files = {}
    off = 8
    while off + 60 <= len(data):
        name = data[off:off + 16].decode().strip()
        size = int(data[off + 48:off + 58].decode().strip())
        content = data[off + 60:off + 60 + size]
        files[name.rstrip("/")] = content
        off += 60 + size + (size & 1)
    return files


def extract_control(deb_path):
    with open(deb_path, "rb") as f:
        data = f.read()
    ar = parse_ar(data)
    ctl_name = None
    for cand in ("control.tar.xz", "control.tar.gz", "control.tar.zst", "control.tar.bz2", "control.tar"):
        if cand in ar:
            ctl_name = cand
            break
    if ctl_name is None:
        raise ValueError("no control.tar in %s" % deb_path)
    blob = ar[ctl_name]
    if ctl_name.endswith(".zst"):
        # zstd tar: prefer zstandard module, else zstd CLI
        try:
            import zstandard as zstd
            blob = zstd.ZstdDecompressor().decompress(blob)
        except ImportError:
            import subprocess, tempfile
            with tempfile.NamedTemporaryFile(suffix=".zst", delete=False) as tf:
                tf.write(blob)
                tmp = tf.name
            blob = subprocess.run(["zstd", "-d", "-f", tmp, "-o", tmp + ".tar"],
                                  capture_output=True).stdout
            with open(tmp + ".tar", "rb") as f2:
                blob = f2.read()
            os.unlink(tmp)
            if os.path.exists(tmp + ".tar"):
                os.unlink(tmp + ".tar")
    tf = tarfile.open(fileobj=io.BytesIO(blob), mode="r:*")
    for m in tf.getmembers():
        if m.name.endswith("control") and "/" not in m.name.lstrip("./"):
            return tf.extractfile(m).read().decode("utf-8", "replace")
    raise ValueError("no control member in %s" % deb_path)


# ---------- control fields ----------
def parse_control(text):
    fields = []
    cur_key = None
    cur_val = []
    for raw in text.splitlines():
        if raw.startswith(" ") or raw.startswith("\t"):
            if cur_key:
                cur_val.append(raw.strip())
            continue
        if not raw.strip():
            continue
        m = re.match(r"^([A-Za-z0-9-]+):\s?(.*)$", raw)
        if m:
            if cur_key:
                fields.append((cur_key, " ".join(cur_val).strip()))
            cur_key = m.group(1)
            cur_val = [m.group(2)]
    if cur_key:
        fields.append((cur_key, " ".join(cur_val).strip()))
    return fields


# ---------- index build ----------
def build_packages():
    debs = sorted(glob.glob(os.path.join(DEBS_DIR, "*.deb")))
    blocks = []
    for deb in debs:
        ctl = parse_control(extract_control(deb))
        with open(deb, "rb") as f:
            blob = f.read()
        rel = os.path.relpath(deb, ROOT).replace("\\", "/")
        lines = []
        for k, v in ctl:
            lines.append("%s: %s" % (k, v))
        lines.append("Filename: %s" % rel)
        lines.append("Size: %d" % len(blob))
        lines.append("MD5sum: %s" % hashlib.md5(blob).hexdigest())
        lines.append("SHA1: %s" % hashlib.sha1(blob).hexdigest())
        lines.append("SHA256: %s" % hashlib.sha256(blob).hexdigest())
        blocks.append("\n".join(lines) + "\n")
    return "\n".join(blocks) + "\n"


def write_release(packages, pkg_bz2, pkg_xz, pkg_gz):
    now = datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
    lines = []
    lines.append("Origin: %s" % ORIGIN)
    lines.append("Label: %s" % LABEL)
    lines.append("Suite: stable")
    lines.append("Version: 1.0")
    lines.append("Codename: ios")
    lines.append("Architectures: iphoneos-arm iphoneos-arm64 iphoneos-arm64e")
    lines.append("Components: main")
    lines.append("Description: %s" % DESC)
    lines.append("Date: %s" % now)

    def hashes_for(name, data):
        return [
            ("MD5Sum", hashlib.md5(data).hexdigest(), len(data)),
            ("SHA1", hashlib.sha1(data).hexdigest(), len(data)),
            ("SHA256", hashlib.sha256(data).hexdigest(), len(data)),
        ]

    items = [("Packages", packages.encode("utf-8")), ("Packages.bz2", pkg_bz2),
             ("Packages.xz", pkg_xz), ("Packages.gz", pkg_gz)]
    for algo in ("MD5Sum", "SHA1", "SHA256"):
        lines.append("%s:" % algo)
        for name, data in items:
            for a, h, l in hashes_for(name, data):
                if a == algo:
                    lines.append(" %s %12d %s" % (h, l, name))
    return "\n".join(lines) + "\n"


def main():
    packages = build_packages()
    pkg_bz2 = bz2.compress(packages.encode("utf-8"))
    pkg_xz = lzma.compress(packages.encode("utf-8"), preset=6)
    pkg_gz = gzip.compress(packages.encode("utf-8"))

    with open(os.path.join(ROOT, "Packages"), "w", encoding="utf-8") as f:
        f.write(packages)
    with open(os.path.join(ROOT, "Packages.bz2"), "wb") as f:
        f.write(pkg_bz2)
    with open(os.path.join(ROOT, "Packages.xz"), "wb") as f:
        f.write(pkg_xz)
    with open(os.path.join(ROOT, "Packages.gz"), "wb") as f:
        f.write(pkg_gz)
    with open(os.path.join(ROOT, "Release"), "w", encoding="utf-8") as f:
        f.write(write_release(packages, pkg_bz2, pkg_xz, pkg_gz))

    n = packages.count("Package: ")
    print("index rebuilt: %d packages, Packages=%dB bz2=%dB xz=%dB gz=%dB" % (
        n, len(packages), len(pkg_bz2), len(pkg_xz), len(pkg_gz)))


if __name__ == "__main__":
    main()

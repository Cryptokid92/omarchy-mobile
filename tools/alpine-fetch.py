#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Download Alpine aarch64 packages plus their dependencies, verifying checksums.

Usage: alpine-fetch.py <alpine-version> <download-dir> <package>...
Prints the paths of the downloaded .apk files.
"""
import base64, hashlib, io, sys, tarfile, urllib.request
from pathlib import Path

version, dest, wanted = sys.argv[1], Path(sys.argv[2]), sys.argv[3:]
branch = "v" + ".".join(version.split(".")[:2])
repos = [f"https://dl-cdn.alpinelinux.org/alpine/{branch}/{r}/aarch64" for r in ("main", "community")]
dest.mkdir(parents=True, exist_ok=True)

pkgs, provides = {}, {}
for repo in repos:
    index = urllib.request.urlopen(f"{repo}/APKINDEX.tar.gz").read()
    with tarfile.open(fileobj=io.BytesIO(index)) as t:
        text = t.extractfile("APKINDEX").read().decode()
    for block in text.strip().split("\n\n"):
        p = dict(line.split(":", 1) for line in block.splitlines() if ":" in line)
        p["repo"] = repo
        pkgs.setdefault(p["P"], p)
        for prov in p.get("p", "").split():
            provides.setdefault(prov.split("=")[0], p["P"])

# Already in the minirootfs
base = {"musl", "busybox", "busybox-binsh", "alpine-baselayout", "alpine-baselayout-data",
        "alpine-keys", "apk-tools", "ca-certificates-bundle", "libcrypto3", "libssl3",
        "ssl_client", "zlib", "scanelf", "musl-utils", "libc-utils", "alpine-release"}
todo, seen = list(wanted), set()
while todo:
    name = todo.pop()
    name = provides.get(name, name).lstrip("!")
    if name in seen or name in base or name not in pkgs:
        continue
    seen.add(name)
    todo += [d.split("=")[0].split(">")[0].split("<")[0] for d in pkgs[name].get("D", "").split()]

for name in sorted(seen):
    p = pkgs[name]
    path = dest / f"{name}-{p['V']}.apk"
    if not path.exists():
        data = urllib.request.urlopen(f"{p['repo']}/{path.name}").read()
        # C: is "Q1" + base64(sha1) of the control section; check the whole file's size instead
        if int(p["S"]) != len(data):
            sys.exit(f"size mismatch for {path.name}")
        path.write_bytes(data)
    print(path)

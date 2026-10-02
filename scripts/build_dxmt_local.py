#!/usr/bin/env python3
"""Prepare/build the private DXMT patch set; builds run only with --build.

--check is read-only; --configure runs compiler detection, never the translator
build. Requires a separately prepared development toolchain and engine.
No global package installation, Xcode selection, sudo, or live DLL replacement.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "runtime/source/dxmt-ow2"
TOOLS = ROOT / "runtime/toolchains"
LLVM = TOOLS / "clang+llvm-15.0.7-x86_64-apple-darwin21.0"
MINGW = TOOLS / "llvm-mingw-20251216-ucrt-macos-universal"
MESON = TOOLS / "python/bin/meson"
ENGINE = ROOT / "runtime/soju-engine-dxmt-ow2-v0.2"
BUILD = ROOT / "runtime/build/dxmt-local"
INSTALL = BUILD / "install"
BASE_COMMIT = "c5dc3a0dfe9108e667da43de871324bd298c9c02"


def command(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def preflight(incremental=False):
    required = [MESON, TOOLS / "python/bin/ninja", MINGW / "bin/x86_64-w64-mingw32-g++",
                LLVM / "include/llvm/IR/Module.h", LLVM / "lib/libLLVMCore.a",
                ENGINE / "bin/winebuild", SOURCE / "include/native/directx/d3d11.h"]
    missing = [str(p.relative_to(ROOT)) for p in required if not p.is_file()]
    if missing:
        raise SystemExit("Missing local prerequisites:\n" + "\n".join(missing))
    head = subprocess.check_output(["git", "-C", str(SOURCE), "rev-parse", "HEAD"], text=True).strip()
    if head != BASE_COMMIT:
        raise SystemExit("Source revision differs from the reviewed fork. Review before building.")
    command("git", "-C", SOURCE, "diff", "--check")
    command("xcrun", "--find", "metal", stdout=subprocess.DEVNULL)
    command("xcrun", "--find", "metallib", stdout=subprocess.DEVNULL)
    free = shutil.disk_usage(ROOT).free / 2**30
    if incremental and not all(path.is_file() for path in
                               (BUILD / 'meson-private/coredata.dat', INSTALL / 'build-manifest.json')):
        raise SystemExit('Incremental mode requires the existing configured and previously built tree.')
    minimum = 2 if incremental else 6
    if free < minimum:
        raise SystemExit(f"Only {free:.1f} GiB free; this build mode requires at least {minimum} GiB headroom.")
    print(f"Prerequisites found; {free:.1f} GiB free. Source revision: {head}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--configure", action="store_true")
    mode.add_argument("--build", action="store_true")
    parser.add_argument("--jobs", type=int, choices=range(1, 5), default=2)
    parser.add_argument('--incremental', action='store_true',
                        help='Reuse the configured build, one job only; requires 2 GiB instead of full-build 6 GiB headroom.')
    args = parser.parse_args()
    if args.incremental and (not args.build or args.jobs != 1):
        parser.error('--incremental requires --build --jobs 1')
    preflight(args.incremental)
    if not (args.configure or args.build):
        return
    env = os.environ.copy()
    env.pop("DESTDIR", None)
    env["PATH"] = os.pathsep.join([str(MINGW / "bin"), str(TOOLS / "python/bin"), env.get("PATH", "")])
    setup = [MESON, "setup", BUILD, SOURCE, "--cross-file", SOURCE / "build-win64.txt",
             "--buildtype=release", "--prefix", INSTALL, "--strip",
             "-Dnative_llvm_path=" + str(LLVM), "-Dwine_install_path=" + str(ENGINE),
             "-Denable_tests=false", "-Denable_nvapi=false", "-Denable_nvngx=false",
             "-Denable_d3d12=false"]
    if (BUILD / "meson-private/coredata.dat").exists():
        setup.append("--reconfigure")
    if not args.incremental:
        command(*setup, env=env, cwd=ROOT)
    if not args.build:
        print("Configuration complete. Translator has NOT been built.", flush=True)
        return
    # Limit parallelism to preserve memory on this 16 GB machine.
    command(MESON, "compile", "-C", BUILD, "-j", args.jobs, env=env, cwd=ROOT)
    command(MESON, "install", "-C", BUILD, "--no-rebuild", env=env, cwd=ROOT)
    outputs = [INSTALL / "x86_64-windows" / n for n in
               ("d3d11.dll", "dxgi.dll", "d3d10core.dll", "winemetal.dll")]
    outputs.append(INSTALL / "x86_64-unix/winemetal.so")
    manifest = {str(p.relative_to(INSTALL)): hashlib.sha256(p.read_bytes()).hexdigest() for p in outputs}
    diff = subprocess.check_output(["git", "-C", str(SOURCE), "diff", "--binary"])
    (INSTALL / "build-manifest.json").write_text(json.dumps(
        dict(base_commit=BASE_COMMIT, patch_sha256=hashlib.sha256(diff).hexdigest(), files=manifest), indent=2) + "\n")
    print("Build complete in runtime/build/dxmt-local/install. No running environment was changed.")


if __name__ == "__main__":
    main()

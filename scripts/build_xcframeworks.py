#!/usr/bin/env python3
"""build_xcframeworks.py: build the four ggml-stack xcframeworks locally on macOS arm64.

Produces (in dist/):
    Ggml.xcframework             (libggml{,-base,-cpu,-metal,-blas})
    LlamaCpp.xcframework         (libllama, libmtmd) -> Ggml
    Whisper.xcframework          (libwhisper)        -> Ggml
    StableDiffusion.xcframework  (libstable-diffusion) -> Ggml
    ggml-cpp-stack-xcframework-arm64-<stack-version>.zip   (ditto-zipped bundle)

All four share one set of ggml dylibs (Metal + CPU + BLAS) sourced from llama.cpp.
Each framework ships an umbrella binary that re-exports its component libs,
so a consumer can `-framework LlamaCpp -framework Ggml` and pick up every
public symbol.

Install-name scheme:
    @rpath/<Component>.framework/Versions/A/Libraries/<basename>.dylib
    @rpath/<Component>.framework/Versions/A/<Component>             (umbrella)

Consumers add ONE rpath (e.g. @executable_path/../Frameworks) pointing at
the directory that holds all four .framework bundles as siblings, and all
inter-framework references resolve.

This script is the local-build counterpart to scripts/fetch_combined_framework.sh
(which downloads pre-built zips from shakfu/cyllama releases). The two paths
produce byte-equivalent layouts at default versions; this one lets you pin
your own llama.cpp / whisper.cpp / stable-diffusion.cpp tags via CLI flags.

Usage:
    python3 scripts/build_xcframeworks.py
    python3 scripts/build_xcframeworks.py --llama-version b8931 --no-zip
    python3 scripts/build_xcframeworks.py --stack-version 0.3.0
"""

from __future__ import annotations

import argparse
import os
import plistlib
import re
import shutil
import subprocess
import sys
from collections.abc import Sequence
from dataclasses import dataclass, field
from pathlib import Path

# ---------------------------------------------------------------------------
# Defaults

# Default upstream tags. These are the same versions the cyllama 0.2.14
# release zip was cut against, so a build at the defaults is drop-in
# compatible with what `make fetch-stack` currently installs.
DEFAULT_LLAMA_VERSION = "b8931"
DEFAULT_WHISPER_VERSION = "v1.8.4"
DEFAULT_SD_VERSION = "master-587-b8bdffc"
DEFAULT_STACK_VERSION = "0.2.14"

LLAMA_REPO = "https://github.com/ggml-org/llama.cpp.git"
WHISPER_REPO = "https://github.com/ggml-org/whisper.cpp.git"
SD_REPO = "https://github.com/leejet/stable-diffusion.cpp.git"

ROOT = Path(__file__).resolve().parent.parent
DIST = ROOT / "dist"
STAGE = ROOT / "build" / "xcframework"

LLAMA_SRC = ROOT / "build" / "llama.cpp"
WHISPER_SRC = ROOT / "build" / "whisper.cpp"
SD_SRC = ROOT / "build" / "stable-diffusion.cpp"

LLAMA_DYN = LLAMA_SRC / "dynamic"
WHISPER_DYN = WHISPER_SRC / "dynamic"
SD_DYN = SD_SRC / "dynamic"

FRAMEWORK_VERSION = "A"
BUNDLE_VERSION = "1"
SHORT_VERSION = "0.1.0"
MIN_MACOS = os.environ.get("MACOSX_DEPLOYMENT_TARGET", "14.0")

# stable-diffusion.cpp requires GGML_MAX_NAME=128 (its CMakeLists.txt and
# ggml_extend.hpp). llama.cpp defaults to 64. Since SD shares llama.cpp's
# ggml dylibs in this build, both sides must agree or the ggml_tensor
# struct layout diverges and tensor copies crash.
GGML_MAX_NAME = 128


# ---------------------------------------------------------------------------
# Component model


@dataclass
class Component:
    name: str  # bundle name, e.g. "LlamaCpp"
    bundle_id: str
    src_dyn_dir: Path  # where to pick the dylibs from
    lib_stems: list[str]  # bare names without ".dylib"
    header_sources: list[tuple[Path, list[str]]]  # (include_dir, [filenames])
    deps: list[str] = field(default_factory=list)  # other Component.name strings


def build_components() -> list[Component]:
    """Build the component list. Deferred so source paths reflect the
    cloned trees that exist after `clone_sources` runs."""
    return [
        Component(
            name="Ggml",
            bundle_id="com.cyllama.ggml",
            src_dyn_dir=LLAMA_DYN,
            lib_stems=["libggml", "libggml-base", "libggml-cpu", "libggml-metal", "libggml-blas"],
            header_sources=[
                (
                    LLAMA_SRC / "ggml" / "include",
                    [
                        "ggml.h",
                        "ggml-alloc.h",
                        "ggml-backend.h",
                        "ggml-blas.h",
                        "ggml-cpp.h",
                        "ggml-cpu.h",
                        "ggml-metal.h",
                        "ggml-opt.h",
                        "gguf.h",
                    ],
                )
            ],
        ),
        Component(
            name="LlamaCpp",
            bundle_id="com.cyllama.llamacpp",
            src_dyn_dir=LLAMA_DYN,
            lib_stems=["libllama", "libmtmd"],
            header_sources=[
                (LLAMA_SRC / "include", ["llama.h", "llama-cpp.h"]),
                (LLAMA_SRC / "tools" / "mtmd", ["mtmd.h", "mtmd-helper.h"]),
            ],
            deps=["Ggml"],
        ),
        Component(
            name="Whisper",
            bundle_id="com.cyllama.whisper",
            src_dyn_dir=WHISPER_DYN,
            lib_stems=["libwhisper"],
            header_sources=[(WHISPER_SRC / "include", ["whisper.h"])],
            deps=["Ggml"],
        ),
        Component(
            name="StableDiffusion",
            bundle_id="com.cyllama.stablediffusion",
            src_dyn_dir=SD_DYN,
            lib_stems=["libstable-diffusion"],
            header_sources=[(SD_SRC, ["stable-diffusion.h"])],
            deps=["Ggml"],
        ),
    ]


def _owner_map(components: list[Component]) -> dict[str, Component]:
    """Map each library basename to the framework that owns it."""
    m: dict[str, Component] = {}
    for c in components:
        for stem in c.lib_stems:
            m[f"{stem}.dylib"] = c
    return m


def _header_owner_map(components: list[Component]) -> dict[str, Component]:
    """Map every shipped header filename to its owning component."""
    m: dict[str, Component] = {}
    for c in components:
        for _inc, names in c.header_sources:
            for n in names:
                m[n] = c
    return m


# ---------------------------------------------------------------------------
# Shell helpers


def run(cmd: Sequence[str | Path], cwd: Path | str | None = None) -> None:
    print(f"+ {' '.join(str(c) for c in cmd)}")
    subprocess.run([str(c) for c in cmd], check=True, cwd=cwd)


def run_capture(cmd: Sequence[str | Path]) -> str:
    return subprocess.run([str(c) for c in cmd], check=True, capture_output=True, text=True).stdout


def fail(msg: str) -> None:
    print(f"error: {msg}", file=sys.stderr)
    sys.exit(1)


# ---------------------------------------------------------------------------
# Step 1: clone source repos at their pinned tags


def clone_sources(llama_ver: str, whisper_ver: str, sd_ver: str) -> None:
    """Shallow-clone the three upstream repos at their tags.

    Idempotent per-repo: a repo whose checkout already exists is left alone.
    Re-tagging requires an explicit `rm -rf build/<name>` first.
    """
    for src, repo, ver in (
        (LLAMA_SRC, LLAMA_REPO, llama_ver),
        (WHISPER_SRC, WHISPER_REPO, whisper_ver),
        (SD_SRC, SD_REPO, sd_ver),
    ):
        if src.exists():
            print(f"  source already present: {src}")
            continue
        src.parent.mkdir(parents=True, exist_ok=True)
        run(
            [
                "git",
                "clone",
                "--depth",
                "1",
                "--branch",
                ver,
                "--recurse-submodules",
                "--shallow-submodules",
                repo,
                str(src),
            ]
        )


# ---------------------------------------------------------------------------
# Step 2: shared-lib cmake builds


def build_dylibs() -> None:
    """Build llama / whisper / SD as shared libs sharing llama.cpp's ggml.

    Idempotent: skips any project whose dylib output is already present.
    Re-building requires `rm -rf build/<name>/dynamic` (or the whole
    `build/<name>` tree to also force a re-clone).
    """
    if not (LLAMA_DYN / "libllama.dylib").exists():
        _build_shared_cmake(
            src=LLAMA_SRC,
            targets=["llama", "mtmd", "ggml", "ggml-base", "ggml-cpu", "ggml-metal", "ggml-blas"],
            dst=LLAMA_DYN,
            extra_cmake=[
                "-DGGML_METAL=ON",
                "-DGGML_METAL_EMBED_LIBRARY=ON",
                "-DGGML_BLAS=ON",
                "-DGGML_BACKEND_DL=OFF",
                "-DLLAMA_CURL=OFF",
                "-DLLAMA_BUILD_SERVER=OFF",
                "-DLLAMA_BUILD_TESTS=OFF",
                "-DLLAMA_BUILD_EXAMPLES=OFF",
            ],
            sync_ggml_from=None,
            collect_globs=["**/libllama*.dylib", "**/libmtmd*.dylib", "**/libggml*.dylib"],
            require=[
                "libllama.dylib",
                "libmtmd.dylib",
                "libggml.dylib",
                "libggml-base.dylib",
                "libggml-cpu.dylib",
                "libggml-metal.dylib",
                "libggml-blas.dylib",
            ],
        )

    if not (WHISPER_DYN / "libwhisper.dylib").exists():
        _build_shared_cmake(
            src=WHISPER_SRC,
            targets=["whisper"],
            dst=WHISPER_DYN,
            extra_cmake=[
                "-DGGML_METAL=ON",
                "-DGGML_METAL_EMBED_LIBRARY=ON",
                "-DGGML_BACKEND_DL=OFF",
                "-DWHISPER_BUILD_TESTS=OFF",
                "-DWHISPER_BUILD_EXAMPLES=OFF",
            ],
            sync_ggml_from=LLAMA_SRC / "ggml",
            collect_globs=["**/libwhisper*.dylib"],
            require=["libwhisper.dylib"],
        )

    if not (SD_DYN / "libstable-diffusion.dylib").exists():
        os.environ["SD_USE_VENDORED_GGML"] = "0"
        _build_shared_cmake(
            src=SD_SRC,
            targets=["stable-diffusion"],
            dst=SD_DYN,
            extra_cmake=[
                "-DSD_METAL=ON",
                "-DSD_BUILD_SHARED_LIBS=ON",
                "-DSD_BUILD_SHARED_GGML_LIB=ON",
                "-DSD_BUILD_EXAMPLES=OFF",
                "-DGGML_METAL_EMBED_LIBRARY=ON",
                "-DGGML_BACKEND_DL=OFF",
            ],
            sync_ggml_from=LLAMA_SRC / "ggml",
            collect_globs=["**/libstable-diffusion*.dylib"],
            require=["libstable-diffusion.dylib"],
        )


def _build_shared_cmake(
    src: Path,
    targets: list[str],
    dst: Path,
    extra_cmake: list[str],
    sync_ggml_from: Path | None,
    collect_globs: list[str],
    require: list[str],
) -> None:
    """Run a fresh cmake build with BUILD_SHARED_LIBS=ON and collect dylibs.

    `targets` is a list of cmake target names to build.
    `require` lists basenames that MUST appear in `dst` after collection;
    the function fails loudly otherwise (catches silent static-lib builds).

    Note: GGML_BACKEND_DL=OFF in `extra_cmake` is load-bearing for the
    umbrella's `-reexport_library` step. With BACKEND_DL=ON, ggml backends
    are built as CMake MODULE libs (MH_BUNDLE on Apple) which cannot be
    re-exported. OFF gives us proper MH_DYLIB output.

    GGML_MAX_NAME=128 is propagated through CMAKE_C/CXX_FLAGS so that
    ggml_tensor's struct layout matches across all three projects (SD
    requires 128; llama defaults to 64).
    """
    if sync_ggml_from and sync_ggml_from.exists() and (src / "ggml").exists():
        print(f"syncing ggml: {sync_ggml_from} -> {src / 'ggml'}")
        shutil.rmtree(src / "ggml")
        shutil.copytree(sync_ggml_from, src / "ggml")

    bld = src / "build_shared"
    if bld.exists():
        shutil.rmtree(bld)
    bld.mkdir(parents=True)

    cmake_cmd: list[str | Path] = [
        "cmake",
        "-S",
        src,
        "-B",
        bld,
        "-DCMAKE_BUILD_TYPE=Release",
        "-DBUILD_SHARED_LIBS=ON",
        "-DCMAKE_POSITION_INDEPENDENT_CODE=ON",
        "-DGGML_NATIVE=OFF",
        f"-DCMAKE_C_FLAGS=-DGGML_MAX_NAME={GGML_MAX_NAME}",
        f"-DCMAKE_CXX_FLAGS=-DGGML_MAX_NAME={GGML_MAX_NAME}",
        f"-DCMAKE_OSX_DEPLOYMENT_TARGET={MIN_MACOS}",
        *extra_cmake,
    ]
    run(cmake_cmd)
    build_cmd: list[str | Path] = ["cmake", "--build", bld, "--config", "Release", "-j"]
    for t in targets:
        build_cmd += ["--target", t]
    run(build_cmd)

    dst.mkdir(parents=True, exist_ok=True)
    collected: set[str] = set()
    for pattern in collect_globs:
        seen: set[Path] = set()
        for f in bld.glob(pattern):
            real = f.resolve()
            if real in seen or not real.is_file():
                continue
            seen.add(real)
            target_name = _strip_soname(f.name)
            shutil.copy2(real, dst / target_name)
            collected.add(target_name)
            print(f"  collected {target_name}")

    missing = [n for n in require if n not in collected]
    if missing:
        fail(f"shared build of {src.name} failed to produce: {missing}. Built artifacts in {bld}.")


# ---------------------------------------------------------------------------
# Step 3: stage one .framework per component


def install_name_for(component: Component, basename: str) -> str:
    return f"@rpath/{component.name}.framework/Versions/{FRAMEWORK_VERSION}/Libraries/{basename}"


def umbrella_install_name(component: Component) -> str:
    return f"@rpath/{component.name}.framework/Versions/{FRAMEWORK_VERSION}/{component.name}"


def stage_framework(
    component: Component,
    owners: dict[str, Component],
    header_owners: dict[str, Component],
) -> Path:
    fw = STAGE / f"{component.name}.framework"
    if fw.exists():
        shutil.rmtree(fw)

    versioned = fw / "Versions" / FRAMEWORK_VERSION
    libs = versioned / "Libraries"
    headers = versioned / "Headers"
    modules = versioned / "Modules"
    resources = versioned / "Resources"
    for d in (libs, headers, modules, resources):
        d.mkdir(parents=True)

    _copy_resolved(component.src_dyn_dir, component.lib_stems, libs)
    _normalize_libs(component, libs, owners)
    _copy_headers(component, headers)
    _patch_cross_framework_includes(component, headers, header_owners)

    umbrella = versioned / component.name
    _build_umbrella(component, umbrella, libs)

    _write_info_plist(resources / "Info.plist", component)
    _write_module_map(modules / "module.modulemap", component, headers)
    _make_version_symlinks(fw, component)
    return fw


def _copy_resolved(src_dir: Path, stems: list[str], dst_dir: Path) -> None:
    """Copy each <stem>.dylib from src_dir to dst_dir, resolving symlinks
    so we get a single real file per name (no versioned soname duplicates)."""
    for stem in stems:
        src = src_dir / f"{stem}.dylib"
        if not src.exists():
            fail(f"missing dylib: {src}")
        real = src.resolve()
        dst = dst_dir / f"{stem}.dylib"
        shutil.copy2(real, dst)
        os.chmod(dst, 0o755)
        print(f"  staged {dst.name}")


def _normalize_libs(component: Component, libs_dir: Path, owners: dict[str, Component]) -> None:
    """Set install names + rewrite LC_LOAD_DYLIB so every reference uses
    the canonical @rpath/<Owner>.framework/Versions/A/Libraries/<name> form,
    and replace rpaths with @loader_path/../../../.. so @rpath/<Owner>...
    resolves at the directory holding all .framework bundles."""
    for f in sorted(libs_dir.glob("*.dylib")):
        run(["install_name_tool", "-id", install_name_for(component, f.name), str(f)])

        otool = run_capture(["otool", "-L", str(f)])
        for line in otool.splitlines()[1:]:
            line = line.strip()
            if not line:
                continue
            old = line.split(" (", 1)[0].strip()
            base = Path(old).name
            stripped = _strip_soname(base)
            owner = owners.get(stripped) or owners.get(base)
            if owner is None:
                continue
            new = install_name_for(owner, stripped)
            if new != old:
                run(["install_name_tool", "-change", old, new, str(f)])

        for rp in _existing_rpaths(f):
            subprocess.run(
                ["install_name_tool", "-delete_rpath", rp, str(f)],
                check=False,
                capture_output=True,
            )
        run(["install_name_tool", "-add_rpath", "@loader_path/../../../..", str(f)])


def _strip_soname(name: str) -> str:
    """libggml.0.dylib -> libggml.dylib; libfoo.1.2.3.dylib -> libfoo.dylib."""
    if not name.endswith(".dylib"):
        return name
    stem = name[: -len(".dylib")]
    parts = stem.split(".")
    while len(parts) > 1 and parts[-1].isdigit():
        parts.pop()
    return ".".join(parts) + ".dylib"


def _existing_rpaths(dylib: Path) -> list[str]:
    out = run_capture(["otool", "-l", str(dylib)])
    rpaths: list[str] = []
    lines = out.splitlines()
    for i, line in enumerate(lines):
        if "cmd LC_RPATH" not in line:
            continue
        for j in range(i + 1, min(i + 4, len(lines))):
            if "path " in lines[j]:
                seg = lines[j].split("path ", 1)[1]
                rpaths.append(seg.split(" (offset", 1)[0].strip())
                break
    return rpaths


def _copy_headers(component: Component, dst: Path) -> None:
    for inc, names in component.header_sources:
        for name in names:
            src = inc / name
            if not src.exists():
                print(f"  warn: missing header {src}")
                continue
            shutil.copy2(src, dst / name)
            print(f"  header {component.name}/{name}")


_INCLUDE_RE = re.compile(r'^(\s*#\s*include\s*)"([^"]+)"', re.MULTILINE)


def _patch_cross_framework_includes(
    component: Component,
    headers_dir: Path,
    owners: dict[str, Component],
) -> None:
    """Rewrite quoted #include directives that reference headers owned by
    another component, into Apple framework form `<Owner/header.h>`.

    Example: in LlamaCpp/llama.h, `#include "ggml.h"` -> `#include <Ggml/ggml.h>`
    so Swift's `import LlamaCpp` (which builds the Clang module) can resolve
    the cross-framework reference via the standard framework search path
    without consumers adding extra -I flags.
    """
    for hdr in sorted(headers_dir.glob("*.h")):
        text = hdr.read_text()
        changed = False

        def repl(match: re.Match[str]) -> str:
            nonlocal changed
            prefix, included = match.group(1), match.group(2)
            base = Path(included).name
            owner = owners.get(base)
            if owner is None or owner.name == component.name:
                return match.group(0)
            changed = True
            return f"{prefix}<{owner.name}/{base}>"

        new_text = _INCLUDE_RE.sub(repl, text)
        if changed:
            hdr.write_text(new_text)
            print(f"  patched cross-framework includes in {component.name}/{hdr.name}")


def _build_umbrella(component: Component, out: Path, libs_dir: Path) -> None:
    """Build a thin dylib that re-exports the component's public libraries.

    Re-export is recorded against each dependency's *current* install name,
    so we run this AFTER _normalize_libs has set the canonical @rpath ids.
    """
    stub_c = STAGE / f"_{component.name.lower()}_umbrella.c"
    stub_c.write_text(f"void {component.name.lower()}_umbrella_anchor(void) {{}}\n")

    cmd: list[str | Path] = [
        "clang",
        "-dynamiclib",
        f"-mmacosx-version-min={MIN_MACOS}",
        "-o",
        str(out),
        str(stub_c),
        "-install_name",
        umbrella_install_name(component),
    ]
    for stem in component.lib_stems:
        cmd += ["-Wl,-reexport_library," + str(libs_dir / f"{stem}.dylib")]
    cmd += ["-Wl,-rpath,@loader_path/../../.."]
    run(cmd)
    os.chmod(out, 0o755)


def _write_info_plist(path: Path, component: Component) -> None:
    plist = {
        "CFBundleDevelopmentRegion": "en",
        "CFBundleExecutable": component.name,
        "CFBundleIdentifier": component.bundle_id,
        "CFBundleInfoDictionaryVersion": "6.0",
        "CFBundleName": component.name,
        "CFBundlePackageType": "FMWK",
        "CFBundleShortVersionString": SHORT_VERSION,
        "CFBundleSignature": "????",
        "CFBundleVersion": BUNDLE_VERSION,
        "LSMinimumSystemVersion": MIN_MACOS,
    }
    with path.open("wb") as f:
        plistlib.dump(plist, f)


def _write_module_map(path: Path, component: Component, headers_dir: Path) -> None:
    c_headers: list[str] = []
    cpp_headers: list[str] = []
    for hdr in sorted(headers_dir.glob("*.h")):
        # Headers ending in -cpp.h gate themselves with `#error` for C
        # consumers. Put them behind `requires cplusplus`.
        if hdr.stem.endswith("-cpp"):
            cpp_headers.append(hdr.name)
        else:
            c_headers.append(hdr.name)

    lines = [f"framework module {component.name} {{"]
    for name in c_headers:
        lines.append(f'    header "{name}"')
    lines.append("    export *")
    for dep in component.deps:
        lines.append(f"    use {dep}")
    if cpp_headers:
        lines.append("    explicit module Cpp {")
        lines.append("        requires cplusplus")
        for name in cpp_headers:
            lines.append(f'        header "{name}"')
        lines.append("        export *")
        lines.append("    }")
    lines.append("}")
    path.write_text("\n".join(lines) + "\n")


def _make_version_symlinks(fw: Path, component: Component) -> None:
    versions = fw / "Versions"
    current = versions / "Current"
    if current.exists() or current.is_symlink():
        current.unlink()
    current.symlink_to(FRAMEWORK_VERSION)

    for entry in (component.name, "Headers", "Modules", "Resources", "Libraries"):
        link = fw / entry
        if link.exists() or link.is_symlink():
            link.unlink()
        link.symlink_to(f"Versions/Current/{entry}")


# ---------------------------------------------------------------------------
# Step 4: xcodebuild -create-xcframework + zip


def create_xcframework(framework: Path, name: str) -> Path:
    DIST.mkdir(parents=True, exist_ok=True)
    out = DIST / f"{name}.xcframework"
    if out.exists():
        shutil.rmtree(out)
    run(
        [
            "xcodebuild",
            "-create-xcframework",
            "-framework",
            str(framework),
            "-output",
            str(out),
        ]
    )
    return out


def package_zip(xcframeworks: list[Path], stack_version: str) -> Path:
    """Bundle the four xcframeworks into a versioned dir and zip via ditto.

    `ditto -c -k` preserves symlinks, extended attributes, and the structure
    macOS framework consumers expect (Versions/Current -> A, top-level
    Headers -> Versions/Current/Headers, etc.) — `zipfile`/`shutil.make_archive`
    flatten or duplicate them.

    Output filename matches scripts/fetch_combined_framework.sh's expectation
    so a built zip drops in for a release zip.
    """
    bundle_name = f"ggml-cpp-stack-xcframework-arm64-{stack_version}"
    bundle_dir = DIST / bundle_name
    if bundle_dir.exists():
        shutil.rmtree(bundle_dir)
    bundle_dir.mkdir()
    for fw in xcframeworks:
        shutil.copytree(fw, bundle_dir / fw.name, symlinks=True)

    zip_path = DIST / f"{bundle_name}.zip"
    if zip_path.exists():
        zip_path.unlink()
    run(["ditto", "-c", "-k", "--keepParent", str(bundle_dir), str(zip_path)])
    return zip_path


# ---------------------------------------------------------------------------


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description=__doc__.split("\n\n", 1)[0],
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    parser.add_argument(
        "--llama-version",
        default=DEFAULT_LLAMA_VERSION,
        help=f"llama.cpp git tag (default: {DEFAULT_LLAMA_VERSION})",
    )
    parser.add_argument(
        "--whisper-version",
        default=DEFAULT_WHISPER_VERSION,
        help=f"whisper.cpp git tag (default: {DEFAULT_WHISPER_VERSION})",
    )
    parser.add_argument(
        "--sd-version",
        default=DEFAULT_SD_VERSION,
        help=f"stable-diffusion.cpp git tag (default: {DEFAULT_SD_VERSION})",
    )
    parser.add_argument(
        "--stack-version",
        default=os.environ.get("STACK_VERSION", DEFAULT_STACK_VERSION),
        help=f"output zip version tag (default: env STACK_VERSION or {DEFAULT_STACK_VERSION})",
    )
    parser.add_argument(
        "--no-zip",
        action="store_true",
        help="skip the final ditto-zip bundling step",
    )
    return parser.parse_args()


def main() -> None:
    if sys.platform != "darwin":
        fail("xcframework target is macOS-only")

    args = parse_args()

    STAGE.mkdir(parents=True, exist_ok=True)

    print("\n=== cloning sources ===")
    clone_sources(args.llama_version, args.whisper_version, args.sd_version)

    print("\n=== building shared dylibs ===")
    build_dylibs()

    components = build_components()
    owners = _owner_map(components)
    header_owners = _header_owner_map(components)

    built: list[Path] = []
    for component in components:
        print(f"\n=== staging {component.name}.framework ===")
        fw = stage_framework(component, owners, header_owners)
        print(f"\n=== creating {component.name}.xcframework ===")
        built.append(create_xcframework(fw, component.name))

    print("\nbuilt:")
    for p in built:
        print(f"  {p}")

    if not args.no_zip:
        print("\n=== packaging zip ===")
        zip_path = package_zip(built, args.stack_version)
        print(f"\npackaged:\n  {zip_path}")


if __name__ == "__main__":
    main()

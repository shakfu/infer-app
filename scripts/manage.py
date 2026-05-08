#!/usr/bin/env python3
"""manage.py: unified fetch + build + cache manager for thirdparty/ artifacts.

Single CLI with shared hash-based cache invalidation for every external
input the build needs. Each target declares its inputs (version strings,
glob-resolved file fingerprints); a JSON marker under
`thirdparty/.cache/<kind>-<target>.json` records the SHA-256 of the
canonical input JSON. A second invocation with the same inputs is a no-op.

Two subcommands sharing the cache layer:

    fetch <target>   download a prebuilt artifact
    build <target>   compile from source

The fetch bodies are inlined in this file (urlretrieve + tarfile/zipfile
+ subprocess for git/patch/buildpy). `build stack` imports
build_xcframeworks.build_all() in-process.

Targets:

    stack        ggml-stack xcframeworks (Ggml/LlamaCpp/Whisper/StableDiffusion)
                   inputs: version
                   downloads + extracts release zip from shakfu/cyllama
    sqlitevec    Vendored SQLiteVec checkout + local patches
                   inputs: tag, scripts/patches/sqlitevec/* (file SHAs)
                   note: patch-aware hash is the killer feature here —
                   editing a patch invalidates the cache.
    webassets    KaTeX + highlight.js bundle for the print pipeline
                   inputs: katex_version, hljs_version
    python       Embedded Python.framework via buildpy
                   inputs: py_version, py_pkgs
                   delegates to scripts/buildpy.py for the heavy lifting

Build targets:

    stack        ggml-stack xcframeworks built locally from upstream sources
                   inputs: llama_version, whisper_version, sd_version, stack_version
                   delegate: scripts/build_xcframeworks.py (in-process)
                   note: shares thirdparty/ output paths with `fetch stack`;
                   running one supersedes the other.

CLI:

    manage.py fetch <target> [overrides] [--check] [--offline] [--force]
    manage.py build <target> [overrides] [--check] [--force]
    manage.py fetch all
    manage.py list

    --check     report cache state, do not fetch/build (exit 0 = hit, 1 = miss)
    --offline   no network: succeed on cache hit, fail on miss (fetch only)
    --force     ignore cache, always fetch/build
"""

from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from urllib.request import urlretrieve

ROOT = Path(__file__).resolve().parent.parent
SCRIPTS = ROOT / "scripts"
CACHE_DIR = ROOT / "thirdparty" / ".cache"


# ---------------------------------------------------------------------------
# Target model


@dataclass
class Target:
    name: str
    description: str
    # `inputs` is a dict of input name -> value, where values are either
    # str (version-like) or a list of glob patterns rooted at ROOT (their
    # contents get hashed individually). Override values come from CLI flags.
    default_inputs: dict[str, object]
    fetch: Callable[[dict[str, object]], None]


# Resolve the input dict into a fully-concrete dict suitable for hashing.
# - str values pass through verbatim
# - list-of-glob values get expanded to {relpath: sha256} mappings
# Keeping this resolution in one place means the hash computation and the
# marker-JSON contents are guaranteed to agree.
def resolve_inputs(inputs: dict[str, object]) -> dict[str, object]:
    resolved: dict[str, object] = {}
    for key, val in inputs.items():
        if isinstance(val, str):
            resolved[key] = val
        elif isinstance(val, list):
            file_hashes: dict[str, str] = {}
            for pattern in val:
                for p in sorted(ROOT.glob(pattern)):
                    if not p.is_file():
                        continue
                    rel = str(p.relative_to(ROOT))
                    file_hashes[rel] = _sha256_file(p)
            resolved[key] = file_hashes
        else:
            raise TypeError(f"unsupported input type for {key}: {type(val).__name__}")
    return resolved


def _sha256_file(p: Path) -> str:
    h = hashlib.sha256()
    with p.open("rb") as f:
        for chunk in iter(lambda: f.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def hash_inputs(resolved: dict[str, object]) -> str:
    # sort_keys + separators give a stable canonical encoding so the same
    # logical inputs always hash identically across invocations.
    blob = json.dumps(resolved, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(blob.encode("utf-8")).hexdigest()


# ---------------------------------------------------------------------------
# Cache marker I/O


def marker_path(kind: str, target: str) -> Path:
    """Markers are namespaced by kind so `fetch stack` and `build stack`
    don't share a marker (their outputs collide in thirdparty/, but their
    cache identities are different)."""
    return CACHE_DIR / f"{kind}-{target}.json"


def read_marker(kind: str, target: str) -> dict | None:
    p = marker_path(kind, target)
    if not p.exists():
        return None
    try:
        return json.loads(p.read_text())
    except (json.JSONDecodeError, OSError):
        return None


def write_marker(kind: str, target: str, resolved: dict[str, object], digest: str) -> None:
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    payload = {
        "kind": kind,
        "target": target,
        "inputs": resolved,
        "hash": digest,
        "fetched_at": _dt.datetime.now(tz=_dt.timezone.utc).isoformat(timespec="seconds"),
    }
    marker_path(kind, target).write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n")


def cache_status(kind: str, target: str, digest: str) -> str:
    """Return one of 'hit', 'stale', 'miss'."""
    marker = read_marker(kind, target)
    if marker is None:
        return "miss"
    if marker.get("hash") == digest:
        return "hit"
    return "stale"


# ---------------------------------------------------------------------------
# Shell helpers


def run(cmd: list[str], env: dict[str, str] | None = None, cwd: Path | str | None = None) -> None:
    print(f"+ {' '.join(cmd)}")
    full_env = {**os.environ, **(env or {})}
    subprocess.run(cmd, check=True, env=full_env, cwd=str(cwd) if cwd else None)


def download(url: str, dest: Path) -> None:
    """Download `url` to `dest` using urlretrieve. Caller owns the parent dir."""
    print(f"  fetching {url}")
    urlretrieve(url, str(dest))


def safe_extract_tar(archive: Path, dst: Path) -> None:
    """Extract a tar.gz, refusing any member whose resolved path escapes dst."""
    dst.mkdir(parents=True, exist_ok=True)
    dst_resolved = dst.resolve()
    with tarfile.open(archive) as tar:
        for member in tar.getmembers():
            target = (dst_resolved / member.name).resolve()
            if not str(target).startswith(str(dst_resolved)):
                raise ValueError(f"tar path traversal: {member.name}")
        tar.extractall(dst_resolved)


def safe_extract_zip(archive: Path, dst: Path) -> None:
    """Extract a zip, refusing any member whose resolved path escapes dst.

    Delegates the actual unpack to system `unzip` because Python's
    `zipfile.extractall()` does NOT preserve symlinks — it materializes
    them as regular files whose contents are the symlink target string.
    Apple .framework bundles depend on `Headers`, `Modules`, and
    `Versions/Current` being real symlinks; without them, clang can't
    resolve `<Whisper/whisper.h>`. system `unzip` honors the
    `external_attr` Unix mode bits and creates true symlinks.
    """
    dst.mkdir(parents=True, exist_ok=True)
    dst_resolved = dst.resolve()
    with zipfile.ZipFile(archive) as z:
        for info in z.infolist():
            target = (dst_resolved / info.filename).resolve()
            if not str(target).startswith(str(dst_resolved)):
                raise ValueError(f"zip path traversal: {info.filename}")
    subprocess.run(
        ["unzip", "-q", "-o", str(archive), "-d", str(dst_resolved)],
        check=True,
    )


# ---------------------------------------------------------------------------
# Per-target fetch implementations (inlined; no shell delegates)


def fetch_stack(inputs: dict[str, object]) -> None:
    """Download the ggml-stack release zip and lay out four xcframeworks
    in thirdparty/. Replaces fetch_combined_framework.sh."""
    version = str(inputs["version"])
    archive_name = f"ggml-cpp-stack-xcframework-arm64-{version}.zip"
    url = f"https://github.com/shakfu/cyllama/releases/download/{version}/{archive_name}"
    frameworks = ("Ggml.xcframework", "LlamaCpp.xcframework", "Whisper.xcframework", "StableDiffusion.xcframework")

    thirdparty = ROOT / "thirdparty"
    thirdparty.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        zip_path = tmp / archive_name
        download(url, zip_path)
        print(f"  extracting {zip_path.name}")
        safe_extract_zip(zip_path, tmp)

        # The archive's outer dir layout is not load-bearing — find by name
        # so a future wrapper directory (e.g. ggml-cpp-stack-...-X.Y.Z/)
        # doesn't break the script.
        for fw in frameworks:
            matches = [p for p in tmp.rglob(fw) if p.is_dir()]
            if not matches:
                raise SystemExit(f"{fw} not found in archive {url}")
            src = matches[0]
            dst = thirdparty / fw
            if dst.exists():
                shutil.rmtree(dst)
            print(f"  copying {fw} -> thirdparty/")
            shutil.copytree(src, dst, symlinks=True)


def fetch_sqlitevec(inputs: dict[str, object]) -> None:
    """Clone SQLiteVec at `tag`, apply the local patches under
    scripts/patches/sqlitevec/, install at thirdparty/SQLiteVec.
    Replaces fetch_sqlitevec.sh.

    Patches include:
      - Move sqlite3ext.h out of the public include dir (an in-line `mv`,
        not a unified diff, since the path layout itself is the bug).
      - Two unified diffs applied with `patch -p0`.
    """
    tag = str(inputs["tag"])
    repo_url = "https://github.com/jkrukowski/SQLiteVec.git"
    patch_dir = SCRIPTS / "patches" / "sqlitevec"
    thirdparty = ROOT / "thirdparty"
    dest = thirdparty / "SQLiteVec"

    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        clone_path = tmp / "SQLiteVec"
        run(["git", "clone", "-q", "--depth", "1", "--branch", tag, repo_url, str(clone_path)])
        shutil.rmtree(clone_path / ".git", ignore_errors=True)

        # Patch 1: move sqlite3ext.h out of public include/.
        # See docs/patches/sqlitevec.md for rationale.
        print("  patch 1: move sqlite3ext.h out of public include/")
        (clone_path / "Sources" / "CSQLiteVec" / "include" / "sqlite3ext.h").rename(
            clone_path / "Sources" / "CSQLiteVec" / "sqlite3ext.h"
        )

        # Patches 2..N: unified diffs applied in lexicographic order.
        # Numeric prefixes (02-, 03-) keep the order explicit.
        for patch_file in sorted(patch_dir.glob("*.patch")):
            print(f"  applying {patch_file.name}")
            with patch_file.open("rb") as f:
                subprocess.run(
                    ["patch", "-p0", "--quiet"],
                    check=True,
                    cwd=str(clone_path),
                    stdin=f,
                )

        thirdparty.mkdir(parents=True, exist_ok=True)
        if dest.exists():
            print(f"  removing existing {dest}")
            shutil.rmtree(dest)
        print(f"  copying SQLiteVec -> {dest}")
        shutil.copytree(clone_path, dest, symlinks=True)

    n = len(list(patch_dir.glob("*.patch"))) + 1  # +1 for the rename patch
    print(f"  installed SQLiteVec ({tag}, {n} patches applied)")


def fetch_tree_sitter_qmd(inputs: dict[str, object]) -> None:
    """Clone quarto-dev/quarto-markdown at `commit`, extract the
    `crates/tree-sitter-qmd/` SwiftPM package to thirdparty/tree-sitter-qmd.

    Upstream ships its Package.swift in a subdirectory of a multi-crate
    monorepo, so SPM can't reference it via URL — we vendor the
    subdirectory at a pinned commit. No patches today (the upstream
    Package.swift declares `swift-tools-version:5.3` which our 6.1 root
    package consumes fine).
    """
    commit = str(inputs["commit"])
    repo_url = "https://github.com/quarto-dev/quarto-markdown.git"
    thirdparty = ROOT / "thirdparty"
    dest = thirdparty / "tree-sitter-qmd"

    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        clone_path = tmp / "quarto-markdown"
        # The repo is large; fetch only the pinned commit shallowly. GitHub
        # supports `--depth 1` from a sha when uploadpack.allowReachableSHA1
        # is on (it is for github.com); fall back to a full shallow clone
        # of main + checkout if the direct fetch fails on older git.
        run(["git", "init", "-q", str(clone_path)])
        run(["git", "-C", str(clone_path), "remote", "add", "origin", repo_url])
        try:
            run(["git", "-C", str(clone_path), "fetch", "-q", "--depth", "1", "origin", commit])
            run(["git", "-C", str(clone_path), "checkout", "-q", "FETCH_HEAD"])
        except subprocess.CalledProcessError:
            shutil.rmtree(clone_path)
            run(["git", "clone", "-q", "--depth", "50", repo_url, str(clone_path)])
            run(["git", "-C", str(clone_path), "checkout", "-q", commit])

        crate = clone_path / "crates" / "tree-sitter-qmd"
        if not crate.is_dir():
            raise SystemExit(f"crates/tree-sitter-qmd missing in {commit}")

        thirdparty.mkdir(parents=True, exist_ok=True)
        if dest.exists():
            print(f"  removing existing {dest}")
            shutil.rmtree(dest)
        print(f"  copying tree-sitter-qmd -> {dest}")
        shutil.copytree(crate, dest, symlinks=True)

    print(f"  installed tree-sitter-qmd ({commit[:10]})")


def fetch_tree_sitter_python(inputs: dict[str, object]) -> None:
    """Clone tree-sitter/tree-sitter-python at `tag`, vendor the
    library bits to thirdparty/tree-sitter-python, and copy its
    highlights.scm into the Infer target's resources.

    Why we patch upstream's Package.swift: it pulls
    `tree-sitter/swift-tree-sitter` as a SwiftTreeSitter dep for its
    test target. Our project already pins ChimeHQ/SwiftTreeSitter; SPM
    can't reconcile two packages with the same product name. We strip
    upstream's test target + dep so the library target — which has no
    Swift deps — compiles cleanly alongside ours.
    """
    tag = str(inputs["tag"])
    repo_url = "https://github.com/tree-sitter/tree-sitter-python.git"
    thirdparty = ROOT / "thirdparty"
    dest = thirdparty / "tree-sitter-python"
    resource_dst = (
        ROOT / "projects" / "infer" / "Sources" / "Infer" / "Resources"
        / "python_highlights.scm"
    )

    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        clone_path = tmp / "tree-sitter-python"
        run([
            "git", "clone", "-q", "--depth", "1", "--branch", tag,
            repo_url, str(clone_path),
        ])
        shutil.rmtree(clone_path / ".git", ignore_errors=True)

        # Patch Package.swift: drop the test target and the
        # SwiftTreeSitter dep (the library target itself has no Swift
        # dependencies). Keep the library target unchanged.
        #
        # Hardcoded sources list because upstream's
        # `FileManager.default.fileExists(atPath: "src/scanner.c")`
        # check resolves against SPM's working directory, not the
        # package root — scanner.c sits at thirdparty/tree-sitter-python/
        # src/scanner.c and the check returns false from elsewhere,
        # silently dropping the external scanner and leaving its
        # symbols unresolved at link time.
        package_swift = clone_path / "Package.swift"
        patched = """// swift-tools-version:5.3

import Foundation
import PackageDescription

let package = Package(
    name: "TreeSitterPython",
    products: [
        .library(name: "TreeSitterPython", targets: ["TreeSitterPython"]),
    ],
    targets: [
        .target(
            name: "TreeSitterPython",
            path: ".",
            sources: ["src/parser.c", "src/scanner.c"],
            resources: [
                .copy("queries")
            ],
            publicHeadersPath: "bindings/swift",
            cSettings: [.headerSearchPath("src")]
        ),
    ],
    cLanguageStandard: .c11
)
"""
        package_swift.write_text(patched)

        thirdparty.mkdir(parents=True, exist_ok=True)
        if dest.exists():
            print(f"  removing existing {dest}")
            shutil.rmtree(dest)
        print(f"  copying tree-sitter-python -> {dest}")
        shutil.copytree(clone_path, dest, symlinks=True)

    # Copy highlights.scm into the Infer target's resources so the
    # wiki editor can load it via Bundle.module without crossing
    # target boundaries.
    src_scm = dest / "queries" / "highlights.scm"
    if not src_scm.is_file():
        raise SystemExit(f"highlights.scm missing in {tag}")
    resource_dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src_scm, resource_dst)
    print(f"  staged python_highlights.scm -> {resource_dst}")
    print(f"  installed tree-sitter-python ({tag})")


def fetch_webassets(inputs: dict[str, object]) -> None:
    """Download KaTeX + highlight.js into thirdparty/webassets/.
    Replaces fetch_webassets.sh."""
    katex_version = str(inputs["katex_version"])
    hljs_version = str(inputs["hljs_version"])
    dest = ROOT / "thirdparty" / "webassets"
    dest.mkdir(parents=True, exist_ok=True)

    with tempfile.TemporaryDirectory() as td:
        tmp = Path(td)
        # KaTeX
        katex_url = f"https://github.com/KaTeX/KaTeX/releases/download/v{katex_version}/katex.tar.gz"
        katex_tar = tmp / "katex.tar.gz"
        download(katex_url, katex_tar)
        katex_dst = dest / "katex"
        if katex_dst.exists():
            shutil.rmtree(katex_dst)
        safe_extract_tar(katex_tar, tmp)
        # The tarball's top-level is `katex/`; move its contents in.
        shutil.copytree(tmp / "katex", katex_dst, symlinks=True)
        print(f"  -> {katex_dst}")

    # highlight.js (two CDN files)
    hljs_base = f"https://cdnjs.cloudflare.com/ajax/libs/highlight.js/{hljs_version}"
    hljs_dst = dest / "highlight"
    if hljs_dst.exists():
        shutil.rmtree(hljs_dst)
    hljs_dst.mkdir(parents=True)
    download(f"{hljs_base}/highlight.min.js", hljs_dst / "highlight.min.js")
    download(f"{hljs_base}/styles/github.min.css", hljs_dst / "github.min.css")
    print(f"  -> {hljs_dst}")


def fetch_python(inputs: dict[str, object]) -> None:
    """Build a minimized Python.framework via scripts/buildpy.py and stage
    it at thirdparty/Python.framework. Replaces fetch_python_framework.sh.

    The skip-if-exists logic the bash script had is now handled one layer
    up by manage.py's cache: same py_version + py_pkgs hash → cache hit →
    fetch is never called. Use --force to override.
    """
    py_version = str(inputs["py_version"])
    py_pkgs = str(inputs["py_pkgs"])

    target = ROOT / "thirdparty" / "Python.framework"
    build_dir = ROOT / "build" / "python-framework"
    buildpy = SCRIPTS / "buildpy.py"

    print(f"  building Python {py_version} framework with packages: {py_pkgs!r}")
    print(f"  build scratch:  {build_dir}")
    print(f"  output target:  {target}")
    print("  (this takes a while — buildpy compiles CPython from source)")

    build_dir.mkdir(parents=True, exist_ok=True)
    staged_root = build_dir / "staged"

    cmd = [str(buildpy), "-c", "framework_max", "-v", py_version]
    if py_pkgs.strip():
        # buildpy's -i takes one arg per package; PY_PKGS is space-separated.
        cmd += ["-i", *py_pkgs.split()]
    cmd += ["--install-dir", str(staged_root)]
    run(cmd, cwd=build_dir)

    staged = staged_root / "Python.framework"
    if not staged.is_dir():
        raise SystemExit(f"buildpy did not produce {staged}")

    if target.exists():
        shutil.rmtree(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.move(str(staged), str(target))
    print(f"  installed Python.framework at {target}")


def build_stack(inputs: dict[str, object]) -> None:
    """Drive scripts/build_xcframeworks.py in-process, then promote
    dist/*.xcframework into thirdparty/ where the build consumes them.

    Promotion is intentional: build_xcframeworks writes to dist/ as its
    primary output (so a build doesn't clobber a prior fetch unless this
    code says so), and we copy here rather than letting the build script
    do it because the in-process call leaves us holding the result list.
    """
    import shutil as _shutil

    # Imported lazily so `manage.py list` / `manage.py fetch <X>` don't
    # pay the (small) import cost when the build path isn't exercised.
    sys.path.insert(0, str(SCRIPTS))
    try:
        import build_xcframeworks
    finally:
        sys.path.pop(0)

    built = build_xcframeworks.build_all(
        llama_version=str(inputs["llama_version"]),
        whisper_version=str(inputs["whisper_version"]),
        sd_version=str(inputs["sd_version"]),
        stack_version=str(inputs["stack_version"]),
        no_zip=True,
    )
    thirdparty = ROOT / "thirdparty"
    for xcf in built:
        dst = thirdparty / xcf.name
        if dst.exists():
            _shutil.rmtree(dst)
        _shutil.copytree(xcf, dst, symlinks=True)
        print(f"  installed {dst.name} -> thirdparty/")


# ---------------------------------------------------------------------------
# Target registries (separated by kind so the CLI can route correctly
# and so a fetch-target marker doesn't collide with a build-target marker
# when both share a name like 'stack')

FETCH_TARGETS: dict[str, Target] = {
    "stack": Target(
        name="stack",
        description="ggml-stack xcframeworks (Ggml + LlamaCpp + Whisper + StableDiffusion)",
        default_inputs={"version": "0.2.15"},
        fetch=fetch_stack,
    ),
    "sqlitevec": Target(
        name="sqlitevec",
        description="Vendored SQLiteVec + local patches",
        default_inputs={
            "tag": "0.0.14",
            # Patch contents are mixed into the hash so editing any patch
            # under scripts/patches/sqlitevec/ invalidates the cache. The
            # bash marker (Package.swift existence) silently ignored this.
            "patches": ["scripts/patches/sqlitevec/**/*"],
        },
        fetch=fetch_sqlitevec,
    ),
    "tree-sitter-qmd": Target(
        name="tree-sitter-qmd",
        description="Vendored tree-sitter-qmd grammar (Quarto/Markdown)",
        default_inputs={
            # No upstream tags yet; pin to a known-good commit on main.
            # Bump and rerun fetch to upgrade.
            "commit": "c925e444df03c1f7b7b4cccb5f0a2e72fc130885",
        },
        fetch=fetch_tree_sitter_qmd,
    ),
    "tree-sitter-python": Target(
        name="tree-sitter-python",
        description="Vendored tree-sitter-python grammar + queries",
        default_inputs={"tag": "v0.25.0"},
        fetch=fetch_tree_sitter_python,
    ),
    "webassets": Target(
        name="webassets",
        description="KaTeX + highlight.js bundle for the print pipeline",
        default_inputs={
            "katex_version": "0.16.22",
            "hljs_version": "11.11.1",
        },
        fetch=fetch_webassets,
    ),
    "python": Target(
        name="python",
        description="Embedded Python.framework via buildpy",
        default_inputs={
            "py_version": "3.13.13",
            "py_pkgs": "",
        },
        fetch=fetch_python,
    ),
}

BUILD_TARGETS: dict[str, Target] = {
    "stack": Target(
        name="stack",
        description="ggml-stack xcframeworks built locally from upstream sources",
        default_inputs={
            # Match build_xcframeworks.DEFAULT_* so a bare `manage.py build
            # stack` and a bare `build_xcframeworks.py` are equivalent.
            "llama_version": "b9010",
            "whisper_version": "v1.8.4",
            "sd_version": "master-593-3d6064b",
            "stack_version": "0.2.16",
        },
        fetch=build_stack,
    ),
}


def registry_for(kind: str) -> dict[str, Target]:
    if kind == "fetch":
        return FETCH_TARGETS
    if kind == "build":
        return BUILD_TARGETS
    raise SystemExit(f"unknown kind: {kind}")


# ---------------------------------------------------------------------------
# CLI


def merge_overrides(target: Target, overrides: dict[str, str]) -> dict[str, object]:
    """Apply CLI overrides to a target's default inputs.

    Only str-valued inputs are CLI-overridable; glob inputs (like sqlitevec
    patches) are derived from the filesystem and don't take overrides.
    """
    out: dict[str, object] = dict(target.default_inputs)
    for k, v in overrides.items():
        if k not in target.default_inputs:
            raise SystemExit(f"unknown input '{k}' for target '{target.name}'")
        if not isinstance(target.default_inputs[k], str):
            raise SystemExit(f"input '{k}' on target '{target.name}' is not CLI-overridable")
        out[k] = v
    return out


def _run_targets(kind: str, args: argparse.Namespace) -> int:
    registry = registry_for(kind)
    targets: list[str]
    if args.target == "all":
        if kind == "build":
            print("'all' is only supported for fetch", file=sys.stderr)
            return 2
        targets = list(registry.keys())
    else:
        if args.target not in registry:
            print(f"unknown {kind} target: {args.target}", file=sys.stderr)
            return 2
        targets = [args.target]

    overrides: dict[str, str] = {}
    for raw in args.set or []:
        if "=" not in raw:
            print(f"--set expects key=value, got: {raw!r}", file=sys.stderr)
            return 2
        k, v = raw.split("=", 1)
        overrides[k] = v

    rc = 0
    for name in targets:
        target = registry[name]
        inputs = merge_overrides(target, overrides if args.target != "all" else {})
        resolved = resolve_inputs(inputs)
        digest = hash_inputs(resolved)
        status = cache_status(kind, name, digest)

        print(f"[{kind}:{name}] {status} (hash={digest[:12]})")

        if args.check:
            rc = rc or (0 if status == "hit" else 1)
            continue

        if status == "hit" and not args.force:
            print(f"[{kind}:{name}] up-to-date, skipping")
            continue

        if kind == "fetch" and getattr(args, "offline", False):
            print(f"[{kind}:{name}] offline mode: cache miss is fatal", file=sys.stderr)
            rc = 1
            continue

        target.fetch(resolved)
        write_marker(kind, name, resolved, digest)
        print(f"[{kind}:{name}] cache marker updated")

    return rc


def cmd_fetch(args: argparse.Namespace) -> int:
    return _run_targets("fetch", args)


def cmd_build(args: argparse.Namespace) -> int:
    return _run_targets("build", args)


def cmd_list(_args: argparse.Namespace) -> int:
    print(f"{'KIND':<6} {'TARGET':<12} {'STATUS':<8} {'HASH':<14} DESCRIPTION")
    for kind, registry in (("fetch", FETCH_TARGETS), ("build", BUILD_TARGETS)):
        for name, target in registry.items():
            resolved = resolve_inputs(target.default_inputs)
            digest = hash_inputs(resolved)
            status = cache_status(kind, name, digest)
            print(f"{kind:<6} {name:<12} {status:<8} {digest[:12]:<14} {target.description}")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n", 1)[0])
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_fetch = sub.add_parser("fetch", help="fetch a target (or 'all')")
    p_fetch.add_argument("target", help="target name, or 'all'")
    p_fetch.add_argument(
        "--set",
        action="append",
        metavar="KEY=VAL",
        help="override an input (repeatable). Defaults are baked in; use this when the Makefile passes a non-default version through.",
    )
    p_fetch.add_argument("--check", action="store_true", help="report cache state, don't fetch (exit 0=hit, 1=miss)")
    p_fetch.add_argument("--offline", action="store_true", help="no network: succeed on hit, fail on miss")
    p_fetch.add_argument("--force", action="store_true", help="ignore cache, always fetch")
    p_fetch.set_defaults(func=cmd_fetch)

    p_build = sub.add_parser("build", help="build a target from source")
    p_build.add_argument("target", help="target name (currently: 'stack')")
    p_build.add_argument(
        "--set",
        action="append",
        metavar="KEY=VAL",
        help="override an input (repeatable), e.g. --set llama_version=bXXXX",
    )
    p_build.add_argument("--check", action="store_true", help="report cache state, don't build (exit 0=hit, 1=miss)")
    p_build.add_argument("--force", action="store_true", help="ignore cache, always build")
    p_build.set_defaults(func=cmd_build)

    p_list = sub.add_parser("list", help="list targets and cache status")
    p_list.set_defaults(func=cmd_list)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())

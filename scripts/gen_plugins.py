#!/usr/bin/env python3
"""Regenerate plugin glue from `projects/plugins/plugins.json`.

Two artefacts are kept in sync with the JSON:

1. `projects/infer/Package.swift` — two marker-bounded sections rewritten
   in place:
     - BEGIN_GENERATED_PLUGINS_PACKAGES / END_GENERATED_PLUGINS_PACKAGES
       holds one `.package(path: "../plugins/plugin_<id>")` entry per
       enabled plugin, inside the package-level `dependencies:` array.
     - BEGIN_GENERATED_PLUGINS_PRODUCTS / END_GENERATED_PLUGINS_PRODUCTS
       holds one `.product(name: "plugin_<id>", package: "plugin_<id>")`
       entry per enabled plugin, inside the `Infer` executable target's
       `dependencies:` array.

2. `projects/infer/Sources/Infer/GeneratedPlugins.swift` — declares
   `allPluginTypes: [any Plugin.Type]` (one entry per enabled plugin)
   plus `pluginConfigs: [String: PluginConfig]` carrying the `config`
   blob from `plugins.json` as JSON-encoded `Data`.

The script is idempotent: running it twice with no input change is a
no-op. CI runs it and asserts the working tree is clean afterwards.

Local overrides: if `projects/plugins/plugins.local.json` exists, its
entries shadow-merge over the tracked `plugins.json` by `id`. Used to
disable heavy plugins per-developer without touching tracked state.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any

REPO_ROOT = Path(__file__).resolve().parent.parent
PLUGINS_DIR = REPO_ROOT / "projects" / "plugins"
PLUGINS_JSON = PLUGINS_DIR / "plugins.json"
PLUGINS_LOCAL_JSON = PLUGINS_DIR / "plugins.local.json"
PACKAGE_SWIFT = REPO_ROOT / "projects" / "infer" / "Package.swift"
GENERATED_SWIFT = (
    REPO_ROOT / "projects" / "infer" / "Sources" / "Infer" / "GeneratedPlugins.swift"
)

PACKAGES_BEGIN = "// BEGIN_GENERATED_PLUGINS_PACKAGES"
PACKAGES_END = "// END_GENERATED_PLUGINS_PACKAGES"
PRODUCTS_BEGIN = "// BEGIN_GENERATED_PLUGINS_PRODUCTS"
PRODUCTS_END = "// END_GENERATED_PLUGINS_PRODUCTS"


def to_camel(snake: str) -> str:
    return "".join(part.capitalize() for part in snake.split("_"))


def load_plugins() -> list[dict[str, Any]]:
    with PLUGINS_JSON.open() as f:
        base = json.load(f).get("plugins", [])
    by_id: dict[str, dict[str, Any]] = {p["id"]: p for p in base}
    if PLUGINS_LOCAL_JSON.exists():
        with PLUGINS_LOCAL_JSON.open() as f:
            for entry in json.load(f).get("plugins", []):
                pid = entry["id"]
                if pid in by_id:
                    merged = dict(by_id[pid])
                    merged.update(entry)
                    by_id[pid] = merged
                else:
                    by_id[pid] = entry
    seen = set()
    ordered: list[dict[str, Any]] = []
    for entry in base:
        ordered.append(by_id[entry["id"]])
        seen.add(entry["id"])
    for pid, entry in by_id.items():
        if pid not in seen:
            ordered.append(entry)
    return [p for p in ordered if p.get("enabled", True)]


def render_packages_block(plugins: list[dict[str, Any]]) -> str:
    lines = [
        f"        {PACKAGES_BEGIN}",
        "        // Managed by `scripts/gen_plugins.py`. Do not hand-edit between",
        "        // the BEGIN/END markers; rerun `make plugins-gen` after editing",
        "        // `projects/plugins/plugins.json`.",
    ]
    for p in plugins:
        module = f"plugin_{p['id']}"
        lines.append(f'        .package(path: "../plugins/{module}"),')
    lines.append(f"        {PACKAGES_END}")
    return "\n".join(lines)


def render_products_block(plugins: list[dict[str, Any]]) -> str:
    lines = [
        f"                {PRODUCTS_BEGIN}",
        "                // Managed by `scripts/gen_plugins.py`. Do not hand-edit",
        "                // between the BEGIN/END markers; rerun `make plugins-gen`",
        "                // after editing `projects/plugins/plugins.json`.",
    ]
    for p in plugins:
        module = f"plugin_{p['id']}"
        lines.append(
            f'                .product(name: "{module}", package: "{module}"),'
        )
    lines.append(f"                {PRODUCTS_END}")
    return "\n".join(lines)


def replace_section(source: str, begin: str, end: str, replacement: str) -> str:
    pattern = re.compile(
        r"^[ \t]*" + re.escape(begin) + r".*?^[ \t]*" + re.escape(end),
        re.DOTALL | re.MULTILINE,
    )
    if not pattern.search(source):
        sys.exit(
            f"error: marker pair {begin!r} / {end!r} not found in Package.swift"
        )
    return pattern.sub(replacement, source, count=1)


def render_generated_swift(plugins: list[dict[str, Any]]) -> str:
    if plugins:
        imports = "\n".join(f"import plugin_{p['id']}" for p in plugins)
        type_lines = "\n".join(
            f"    {to_camel(p['id'])}Plugin.self," for p in plugins
        )
        config_lines = []
        for p in plugins:
            blob = json.dumps(p.get("config", {}), separators=(",", ":"))
            escaped = blob.replace("\\", "\\\\").replace('"', '\\"')
            config_lines.append(
                f'    "{p["id"]}": PluginConfig(json: Data("{escaped}".utf8)),'
            )
        configs = "\n".join(config_lines)
    else:
        imports = ""
        type_lines = ""
        configs = ""
    return f"""// GENERATED — do not hand-edit. Run `make plugins-gen` to regenerate
// from `projects/plugins/plugins.json`.
import Foundation
import PluginAPI
{imports}

/// Order matches `plugins.json`. The loader iterates this array and
/// looks up each plugin's `config` in `pluginConfigs` by `Plugin.id`.
public let allPluginTypes: [any Plugin.Type] = [
{type_lines}
]

/// JSON-encoded `config` blob per plugin id, mirroring the `config`
/// objects in `plugins.json`. Plugins decode via `PluginConfig.decode`.
public let pluginConfigs: [String: PluginConfig] = [
{configs}
]
"""


def main() -> None:
    plugins = load_plugins()

    pkg = PACKAGE_SWIFT.read_text()
    pkg = replace_section(pkg, PACKAGES_BEGIN, PACKAGES_END, render_packages_block(plugins))
    pkg = replace_section(pkg, PRODUCTS_BEGIN, PRODUCTS_END, render_products_block(plugins))
    if pkg != PACKAGE_SWIFT.read_text():
        PACKAGE_SWIFT.write_text(pkg)
        print(f"updated {PACKAGE_SWIFT.relative_to(REPO_ROOT)}")

    new_generated = render_generated_swift(plugins)
    if not GENERATED_SWIFT.exists() or GENERATED_SWIFT.read_text() != new_generated:
        GENERATED_SWIFT.write_text(new_generated)
        print(f"updated {GENERATED_SWIFT.relative_to(REPO_ROOT)}")


if __name__ == "__main__":
    main()

#!/usr/bin/env python3
"""Insert blank lines between adjacent markdown bullet items."""
import argparse
import re
import sys
from pathlib import Path

BULLET_RE = re.compile(r"^(\s*)[-*+]\s")


def is_bullet(line: str) -> bool:
    return bool(BULLET_RE.match(line))


def space_bullets(text: str) -> str:
    lines = text.splitlines()
    out: list[str] = []
    prev_in_list = False
    for line in lines:
        if is_bullet(line) and prev_in_list and out and out[-1] != "":
            out.append("")
        out.append(line)
        if line.strip() == "":
            prev_in_list = False
        elif is_bullet(line):
            prev_in_list = True
        else:
            # Indented continuation belongs to the previous bullet; anything
            # else breaks the list.
            prev_in_list = prev_in_list and line.startswith((" ", "\t"))
    result = "\n".join(out)
    if text.endswith("\n"):
        result += "\n"
    return result


def process_file(path: Path, in_place: bool) -> bool:
    """Return True if the file's content changed."""
    text = path.read_text(encoding="utf-8")
    result = space_bullets(text)
    changed = result != text
    if in_place and changed:
        path.write_text(result, encoding="utf-8")
    return changed


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Insert a blank line between adjacent markdown bullets "
                    "(`-`, `*`, `+`). Idempotent: already-separated bullets "
                    "are left alone.",
        epilog="Reads from stdin when no path is given.",
    )
    parser.add_argument(
        "path",
        nargs="?",
        type=Path,
        help="Markdown file, or directory when used with --recursive. "
             "Omit to read from stdin.",
    )
    parser.add_argument(
        "-i", "--in-place",
        action="store_true",
        help="Write result back to the file(s) instead of stdout. "
             "Required when --recursive is given without a dry-run intent.",
    )
    parser.add_argument(
        "-r", "--recursive",
        action="store_true",
        help="Treat PATH as a directory and process all matching files beneath it.",
    )
    parser.add_argument(
        "--glob",
        default="**/*.md",
        help="Glob pattern relative to PATH when --recursive (default: %(default)s).",
    )
    parser.add_argument(
        "--exclude",
        action="append",
        default=None,
        metavar="DIR",
        help="Directory name to skip while recursing. Repeatable. "
             "Defaults to: .git, .build, build, node_modules, .venv, venv.",
    )
    args = parser.parse_args(argv)

    if args.recursive and args.path is None:
        parser.error("--recursive requires a directory PATH")
    if args.recursive and not args.path.is_dir():
        parser.error(f"--recursive: {args.path} is not a directory")
    if args.path is not None and args.path.is_dir() and not args.recursive:
        parser.error(f"{args.path} is a directory; pass --recursive to process it")
    if args.in_place and args.path is None:
        parser.error("--in-place requires a PATH")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)

    if args.recursive:
        exclude = set(args.exclude) if args.exclude is not None else {
            ".git", ".build", "build", "node_modules", ".venv", "venv",
        }
        files = sorted(
            f for f in args.path.glob(args.glob)
            if not any(part in exclude for part in f.parts)
        )
        if not files:
            print(f"no files matched {args.glob!r} under {args.path}", file=sys.stderr)
            return 0
        changed_count = 0
        for f in files:
            if not f.is_file():
                continue
            changed = process_file(f, in_place=args.in_place)
            if changed:
                changed_count += 1
                verb = "rewrote" if args.in_place else "would rewrite"
                print(f"{verb}: {f}")
        if not args.in_place and changed_count:
            print(f"\n{changed_count} file(s) would change. Re-run with --in-place to apply.",
                  file=sys.stderr)
        return 0

    if args.path is not None:
        text = args.path.read_text(encoding="utf-8")
    else:
        text = sys.stdin.read()

    result = space_bullets(text)

    if args.in_place:
        args.path.write_text(result, encoding="utf-8")
    else:
        sys.stdout.write(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

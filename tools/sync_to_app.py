#!/usr/bin/env python3
"""Synchronize repository files to a Flutter build mirror without copying Git state."""

import argparse
import hashlib
import json
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import tempfile


STATE_FILE = ".toolbox-mirror-files.json"


def git_files(source):
    root = subprocess.check_output(
        ["git", "-C", str(source), "rev-parse", "--show-toplevel"], text=True
    ).strip()
    if Path(root).resolve() != source:
        raise ValueError("--source must be the Git repository root")
    output = subprocess.check_output(
        ["git", "-C", str(source), "ls-files", "-z", "--cached", "--others", "--exclude-standard"]
    )
    return sorted(set(path.decode("utf-8") for path in output.split(b"\0") if path))


def safe_file(root, relative):
    parts = PurePosixPath(relative).parts
    if not parts or PurePosixPath(relative).is_absolute() or any(
        part == ".." or part.rstrip(" .").casefold() == ".git" or ":" in part or "\\" in part
        for part in parts
    ):
        raise ValueError(f"Unsafe repository path: {relative}")
    path = root.joinpath(*parts)
    # Refuse links even when they currently resolve inside the mirror: build
    # folders and local development links belong to the mirror's owner.
    for parent in (path, *path.parents):
        if parent == root:
            break
        if parent.is_symlink() or parent.is_junction():
            raise ValueError(f"Refusing linked path: {path}")
        if parent != path and parent.exists() and not parent.is_dir():
            raise ValueError(f"Expected a directory: {parent}")
    if not path.resolve().is_relative_to(root):
        raise ValueError(f"Path escapes its root: {path}")
    if path.exists() and not path.is_file():
        raise ValueError(f"Expected a file: {path}")
    return path


def same_file(first, second):
    if first.stat().st_size != second.stat().st_size:
        return False
    with first.open("rb") as first_stream, second.open("rb") as second_stream:
        return hashlib.file_digest(first_stream, "sha256").digest() == hashlib.file_digest(
            second_stream, "sha256"
        ).digest()


def sync(source, destination, check=False):
    source = Path(source).resolve()
    destination = Path(destination).resolve()
    if source.is_relative_to(destination) or destination.is_relative_to(source):
        raise ValueError("Source and destination must be separate, non-overlapping directories")
    if destination.name.lower() == ".git":
        raise ValueError("Destination cannot be a Git metadata directory")
    if destination.exists() and not destination.is_dir():
        raise ValueError("Destination must be a directory")

    current_files = set(git_files(source))
    state = safe_file(destination, STATE_FILE)
    previous_files = set()
    if state.exists():
        inventory = json.loads(state.read_text(encoding="utf-8"))
        if not isinstance(inventory, dict) or inventory.get("version") != 1 or not isinstance(inventory.get("files"), list):
            raise ValueError(f"Invalid mirror inventory: {state}")
        if not all(isinstance(relative, str) for relative in inventory["files"]):
            raise ValueError(f"Invalid mirror file paths: {state}")
        previous_files = set(inventory["files"])
    changes = []
    # Validate the entire plan before touching any destination file.
    for relative in sorted(current_files | previous_files):
        src = safe_file(source, relative)
        dst = safe_file(destination, relative)
        if relative not in current_files or not src.exists():
            if dst.exists():
                changes.append(("remove", relative, src, dst))
        elif not dst.exists():
            changes.append(("add", relative, src, dst))
        elif not same_file(src, dst):
            changes.append(("update", relative, src, dst))

    backup = None
    if not check:
        for operation, relative, src, dst in changes:
            if dst.exists():
                if backup is None:
                    backup = Path(tempfile.mkdtemp(prefix="multi-toolbox-mirror-backup-"))
                saved = backup / relative
                saved.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(dst, saved)
            if operation == "remove":
                # Remove only files tracked by Git or a previous sync inventory.
                dst.unlink()
            else:
                dst.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(src, dst)
        managed = sorted(relative for relative in current_files if safe_file(source, relative).exists())
        inventory_text = json.dumps({"version": 1, "files": managed}, indent=2) + "\n"
        if not state.exists() or state.read_text(encoding="utf-8") != inventory_text:
            destination.mkdir(parents=True, exist_ok=True)
            state.write_text(inventory_text, encoding="utf-8")
    return changes, backup


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    default_source = Path(__file__).resolve().parents[1]
    parser.add_argument("--source", type=Path, default=default_source)
    parser.add_argument("--destination", type=Path)
    parser.add_argument("--check", action="store_true", help="Check byte-for-byte consistency without writing")
    args = parser.parse_args()
    destination = args.destination or args.source.resolve().parent / "app"
    try:
        changes, backup = sync(args.source, destination, args.check)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(2, f"Mirror sync failed: {error}\n")
    for operation, relative, _, _ in changes:
        print(f"{operation}: {relative}")
    print(f"{'Check' if args.check else 'Sync'}: {len(changes)} file(s) {'differ' if args.check else 'changed'}")
    if backup:
        print(f"Previous mirror files saved to: {backup}")
    return 1 if args.check and changes else 0


if __name__ == "__main__":
    raise SystemExit(main())

#!/usr/bin/env python3
"""Narrow privileged file operations for the local Flask dashboard."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile
import time


def signature(path: Path):
    if not path.exists() and not path.is_symlink():
        return None
    if path.is_symlink():
        return {"type": "link", "target": os.readlink(path)}
    st = path.stat()
    if path.is_file():
        digest = hashlib.sha256()
        with path.open("rb") as stream:
            for chunk in iter(lambda: stream.read(1024 * 1024), b""):
                digest.update(chunk)
        return {"type": "file", "hash": digest.hexdigest(), "mode": stat.S_IMODE(st.st_mode), "uid": st.st_uid, "gid": st.st_gid}
    if path.is_dir():
        entries = []
        for item in sorted(path.rglob("*")):
            if item.is_symlink():
                entries.append([str(item.relative_to(path)), "link", os.readlink(item)])
            elif item.is_file():
                entries.append([str(item.relative_to(path)), signature(item)])
            elif item.is_dir():
                sub = item.stat()
                entries.append([str(item.relative_to(path)), "dir", stat.S_IMODE(sub.st_mode), sub.st_uid, sub.st_gid])
        return {"type": "dir", "mode": stat.S_IMODE(st.st_mode), "uid": st.st_uid, "gid": st.st_gid,
                "hash": hashlib.sha256(json.dumps(entries, sort_keys=True).encode()).hexdigest()}
    raise ValueError(f"unsupported path type: {path}")


def safe_source(raw: str, backup_root: Path) -> Path:
    path = Path(raw)
    if not path.is_absolute() or path == Path("/") or ".." in path.parts:
        raise ValueError(f"unsafe configuration path: {raw}")
    if path == backup_root or backup_root in path.parents:
        raise ValueError(f"configuration path is inside backup storage: {raw}")
    if path.is_symlink():
        raise ValueError(f"symbolic-link configuration paths are not backed up: {raw}")
    if path.exists() and not (path.is_file() or path.is_dir()):
        raise ValueError(f"unsupported configuration path type: {raw}")
    return path


def metadata_tree(path: Path):
    items = [path, *path.rglob("*")] if path.is_dir() else [path]
    result = {}
    for item in items:
        if item.is_symlink(): continue
        st = item.stat()
        key = "." if item == path else str(item.relative_to(path))
        result[key] = {"mode": stat.S_IMODE(st.st_mode), "uid": st.st_uid, "gid": st.st_gid}
    return result


def catalog(backup_root: Path) -> Path:
    backup_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    os.chmod(backup_root, 0o700)
    return backup_root / "catalog.json"


def read_catalog(backup_root: Path):
    try:
        return json.loads(catalog(backup_root).read_text())
    except (OSError, ValueError):
        return {"backups": []}


def write_catalog(backup_root: Path, data, uid: int, gid: int):
    target = catalog(backup_root)
    fd, tmp = tempfile.mkstemp(dir=backup_root, prefix=".catalog-")
    with os.fdopen(fd, "w") as stream:
        json.dump(data, stream, indent=2)
    os.chmod(tmp, 0o600)
    os.replace(tmp, target)
    os.chown(target, uid, gid)
    os.chmod(target, 0o600)


def chown_tree(path: Path, uid: int, gid: int, *, readable: bool = False):
    for item in [path, *path.rglob("*")] if path.is_dir() else [path]:
        if not item.is_symlink():
            os.chown(item, uid, gid)
            if readable:
                mode = stat.S_IMODE(item.stat().st_mode)
                os.chmod(item, mode | (0o500 if item.is_dir() else 0o400))


def backup(args):
    root = Path(args.backup_root).resolve()
    entries = []
    for raw in args.paths:
        path = safe_source(raw, root)
        before = signature(path)
        entries.append({"path": str(path), "existed": before is not None, "signature": before,
                        "metadata": None if before is None else metadata_tree(path)})
    snapshot_id = f"{time.strftime('%Y%m%dT%H%M%SZ', time.gmtime())}-{args.run_id}-{os.urandom(3).hex()}"
    snapshot = root / snapshot_id
    snapshot.mkdir(mode=0o700)
    try:
        for entry in entries:
            if entry["existed"]:
                target = snapshot / "files" / entry["path"].lstrip("/")
                target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
                if Path(entry["path"]).is_dir():
                    shutil.copytree(entry["path"], target, copy_function=shutil.copy2, symlinks=True)
                else:
                    shutil.copy2(entry["path"], target, follow_symlinks=False)
                # Backups stay private, but the dashboard user can read snapshot contents.
                for item in [target, *target.rglob("*")] if target.is_dir() else [target]:
                    if not item.is_symlink():
                        os.chmod(item, stat.S_IMODE(item.stat().st_mode) | (0o500 if item.is_dir() else 0o400))
        record = {"id": snapshot_id, "script": args.script, "created_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "snapshot": str(snapshot), "entries": entries}
        with (root / ".catalog.lock").open("a+") as lock:
            fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
            data = read_catalog(root)
            data["backups"].append(record)
            write_catalog(root, data, args.uid, args.gid)
            fcntl.flock(lock.fileno(), fcntl.LOCK_UN)
        chown_tree(snapshot, args.uid, args.gid)
        return record
    except Exception:
        shutil.rmtree(snapshot, ignore_errors=True)
        raise


def inspect(args):
    root = Path(args.backup_root).resolve()
    record = next((r for r in read_catalog(root)["backups"] if r["id"] == args.id), None)
    if not record:
        raise ValueError("backup not found")
    results = []
    for entry in record["entries"]:
        current = signature(Path(entry["path"]))
        if entry["signature"] is None:
            status = "created" if current is not None else "unchanged"
        elif current is None:
            status = "deleted"
        elif current != entry["signature"]:
            status = "changed"
        else:
            status = "unchanged"
        results.append({**entry, "status": status})
    return results


def stage(args):
    root = Path(args.backup_root).resolve()
    record = next((r for r in read_catalog(root)["backups"] if r["id"] == args.id), None)
    if not record:
        raise ValueError("backup not found")
    entry = next((e for e in record["entries"] if e["path"] == args.path), None)
    if not entry or not entry["existed"]:
        raise ValueError("no original backup exists for this path")
    current = Path(entry["path"])
    staged = root / "reviews" / args.id / hashlib.sha256(args.path.encode()).hexdigest()[:16]
    staged.mkdir(mode=0o700, parents=True, exist_ok=True)
    backup_copy = staged / "before"
    current_copy = staged / "current"
    source = Path(record["snapshot"]) / "files" / entry["path"].lstrip("/")
    for target in (backup_copy, current_copy):
        if target.exists():
            shutil.rmtree(target) if target.is_dir() else target.unlink()
    if source.is_dir():
        shutil.copytree(source, backup_copy, symlinks=True)
    else:
        shutil.copy2(source, backup_copy, follow_symlinks=False)
    if current.exists():
        if current.is_dir(): shutil.copytree(current, current_copy, symlinks=True)
        else: shutil.copy2(current, current_copy, follow_symlinks=False)
    else:
        if source.is_dir(): current_copy.mkdir()
        else: current_copy.touch()
    chown_tree(staged, args.uid, args.gid, readable=True)
    chown_tree(root / "reviews", args.uid, args.gid, readable=True)
    return {"before": str(backup_copy), "current": str(current_copy), "directory": source.is_dir()}


def restore(args):
    root = Path(args.backup_root).resolve()
    record = next((r for r in read_catalog(root)["backups"] if r["id"] == args.id), None)
    if not record: raise ValueError("backup not found")
    entry = next((e for e in record["entries"] if e["path"] == args.path), None)
    if not entry or not entry["existed"]: raise ValueError("backup has no original file to restore")
    destination = safe_source(args.path, root)
    source = Path(record["snapshot"]) / "files" / args.path.lstrip("/")
    temp = destination.with_name(destination.name + f".cyberpatriot-restore-{os.urandom(4).hex()}")
    if source.is_dir(): shutil.copytree(source, temp, symlinks=True)
    else: shutil.copy2(source, temp, follow_symlinks=False)
    if destination.exists(): shutil.rmtree(destination) if destination.is_dir() else destination.unlink()
    os.replace(temp, destination)
    for relative, metadata in (entry.get("metadata") or {}).items():
        target = destination if relative == "." else destination / relative
        if target.exists() and not target.is_symlink():
            if hasattr(os, "chown"): os.chown(target, metadata["uid"], metadata["gid"])
            os.chmod(target, metadata["mode"])
    return {"restored": str(destination)}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--backup-root", required=True)
    parser.add_argument("--uid", type=int, default=os.getuid())
    parser.add_argument("--gid", type=int, default=os.getgid())
    sub = parser.add_subparsers(dest="command", required=True)
    p = sub.add_parser("backup"); p.add_argument("--run-id", required=True); p.add_argument("--script", required=True); p.add_argument("paths", nargs="*")
    p = sub.add_parser("inspect"); p.add_argument("--id", required=True)
    p = sub.add_parser("stage"); p.add_argument("--id", required=True); p.add_argument("--path", required=True)
    p = sub.add_parser("restore"); p.add_argument("--id", required=True); p.add_argument("--path", required=True)
    args = parser.parse_args()
    try:
        result = {"backup": backup(args)} if args.command == "backup" else inspect(args) if args.command == "inspect" else stage(args) if args.command == "stage" else restore(args)
        print(json.dumps(result))
    except (OSError, ValueError, shutil.Error) as exc:
        print(json.dumps({"error": str(exc)}))
        raise SystemExit(1)


if __name__ == "__main__":
    main()

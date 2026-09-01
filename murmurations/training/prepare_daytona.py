"""Create or replace the pinned Daytona snapshot used by shard-000."""

from __future__ import annotations

import argparse
from pathlib import Path
import time


DEFAULT_DOCKERFILE = Path("murmurations/training/corpus/daytona/Dockerfile")


def _delete_snapshot_and_wait(
    daytona,
    name: str,
    *,
    not_found_error,
    timeout_seconds: float = 60.0,
    poll_seconds: float = 0.5,
) -> bool:
    try:
        existing = daytona.snapshot.get(name)
    except not_found_error:
        return False

    print(
        f"Deleting existing Daytona snapshot: {name} "
        f"(id={getattr(existing, 'id', 'unknown')})",
        flush=True,
    )
    daytona.snapshot.delete(existing)

    deadline = time.monotonic() + timeout_seconds
    while True:
        try:
            daytona.snapshot.get(name)
        except not_found_error:
            print(f"Deleted Daytona snapshot: {name}", flush=True)
            return True
        if time.monotonic() >= deadline:
            raise RuntimeError(
                f"timed out waiting for Daytona snapshot deletion: {name}"
            )
        time.sleep(poll_seconds)


def _create_snapshot_with_name_release_grace(
    daytona,
    params,
    *,
    on_logs,
    conflict_error,
    allow_conflict_retry: bool,
    timeout_seconds: float = 60.0,
    poll_seconds: float = 0.5,
):
    deadline = time.monotonic() + timeout_seconds
    while True:
        try:
            return daytona.snapshot.create(
                params,
                on_logs=on_logs,
                timeout=0,
            )
        except conflict_error:
            if not allow_conflict_retry or time.monotonic() >= deadline:
                raise
            print(
                "Snapshot name is still being released by Daytona; retrying...",
                flush=True,
            )
            time.sleep(poll_seconds)


def prepare_snapshot(
    *,
    name: str,
    dockerfile: str | Path,
    replace: bool,
    cpu: int = 4,
    memory_gib: int = 8,
    disk_gib: int = 10,
) -> None:
    try:
        from daytona import (
            CreateSnapshotParams,
            Daytona,
            DaytonaConflictError,
            DaytonaNotFoundError,
            Image,
            Resources,
        )
    except ImportError as exc:
        raise RuntimeError(
            "Daytona SDK is required; install murmurations/requirements.txt"
        ) from exc

    daytona = Daytona()
    deleted_existing = False
    if replace:
        deleted_existing = _delete_snapshot_and_wait(
            daytona,
            name,
            not_found_error=DaytonaNotFoundError,
        )
    else:
        try:
            existing = daytona.snapshot.get(name)
        except DaytonaNotFoundError:
            existing = None
        if existing is not None:
            print(f"Daytona snapshot already exists: {name}")
            return

    image = Image.from_dockerfile(str(dockerfile))
    if cpu <= 0 or memory_gib <= 0 or disk_gib <= 0:
        raise ValueError("snapshot cpu, memory and disk must be positive")
    params = CreateSnapshotParams(
        name=name,
        image=image,
        resources=Resources(cpu=cpu, memory=memory_gib, disk=disk_gib),
    )
    snapshot = _create_snapshot_with_name_release_grace(
        daytona,
        params,
        on_logs=lambda chunk: print(chunk, end="", flush=True),
        conflict_error=DaytonaConflictError,
        allow_conflict_retry=deleted_existing,
    )
    print(
        f"Prepared Daytona snapshot: {snapshot.name} "
        f"(state={snapshot.state}, cpu={snapshot.cpu}, "
        f"memory={snapshot.mem}GiB, disk={snapshot.disk}GiB)"
    )


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--name", default="murmurations-corpus-v1")
    parser.add_argument("--dockerfile", default=str(DEFAULT_DOCKERFILE))
    parser.add_argument("--cpu", type=int, default=4)
    parser.add_argument("--memory-gib", type=int, default=8)
    parser.add_argument("--disk-gib", type=int, default=10)
    parser.add_argument(
        "--replace",
        action="store_true",
        help="Delete and rebuild an existing snapshot with the same name.",
    )
    args = parser.parse_args()
    prepare_snapshot(
        name=args.name,
        dockerfile=args.dockerfile,
        replace=args.replace,
        cpu=args.cpu,
        memory_gib=args.memory_gib,
        disk_gib=args.disk_gib,
    )


if __name__ == "__main__":
    main()

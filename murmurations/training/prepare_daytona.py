"""Create or replace the pinned Daytona snapshot used by shard-000."""

from __future__ import annotations

import argparse
from pathlib import Path


DEFAULT_DOCKERFILE = Path("murmurations/training/corpus/daytona/Dockerfile")


def prepare_snapshot(
    *,
    name: str,
    dockerfile: str | Path,
    replace: bool,
) -> None:
    try:
        from daytona import Daytona, CreateSnapshotParams, Image, Resources
    except ImportError as exc:
        raise RuntimeError(
            "Daytona SDK is required; install murmurations/requirements.txt"
        ) from exc

    daytona = Daytona()
    if replace:
        try:
            daytona.snapshot.get(name)
        except Exception:
            pass
        else:
            daytona.snapshot.delete(name)
    else:
        try:
            existing = daytona.snapshot.get(name)
        except Exception:
            existing = None
        if existing is not None:
            print(f"Daytona snapshot already exists: {name}")
            return

    image = Image.from_dockerfile(str(dockerfile))
    snapshot = daytona.snapshot.create(
        CreateSnapshotParams(
            name=name,
            image=image,
            resources=Resources(cpu=4, memory=8, disk=10),
        ),
        on_logs=lambda chunk: print(chunk, end=""),
        timeout=0,
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
    )


if __name__ == "__main__":
    main()

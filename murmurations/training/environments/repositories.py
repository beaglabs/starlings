"""Permissive repository catalog and deterministic checkout sampler."""

from __future__ import annotations

from dataclasses import dataclass
import json
from pathlib import Path
import random
import re
import subprocess

from murmurations.utils.canonical import canonical_id


PERMISSIVE_LICENSES = frozenset(
    {
        "0BSD",
        "Apache-2.0",
        "BSD-2-Clause",
        "BSD-3-Clause",
        "CC0-1.0",
        "ISC",
        "MIT",
        "Unlicense",
    }
)
_SAFE_NAME = re.compile(r"[^A-Za-z0-9_.-]+")


@dataclass(frozen=True)
class RepoRecord:
    name: str
    commit: str
    license: str
    path: str | None = None
    url: str | None = None
    language: str | None = None

    def __post_init__(self) -> None:
        if not self.name or not self.commit:
            raise ValueError("repository name and pinned commit are required")
        if self.path is None and self.url is None:
            raise ValueError("repository must provide path or url")
        if self.url is not None and re.fullmatch(r"[0-9a-fA-F]{40}", self.commit) is None:
            raise ValueError("remote repository commits must be pinned 40-hex SHAs")
        if self.license not in PERMISSIVE_LICENSES:
            raise ValueError(f"license is not in the permissive allowlist: {self.license}")

    @property
    def identity(self) -> str:
        return canonical_id(
            {
                "version": 1,
                "name": self.name,
                "commit": self.commit,
                "license": self.license,
                "url": self.url,
                "language": self.language,
            }
        )


class RepoCatalog:
    def __init__(self, records: list[RepoRecord]) -> None:
        if not records:
            raise ValueError("repository catalog is empty")
        names = [record.name for record in records]
        if len(names) != len(set(names)):
            raise ValueError("repository names must be unique")
        self.records = tuple(records)

    @classmethod
    def from_jsonl(cls, path: str | Path) -> "RepoCatalog":
        records: list[RepoRecord] = []
        with Path(path).open("r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if not line:
                    continue
                raw = json.loads(line)
                records.append(
                    RepoRecord(
                        name=str(raw["name"]),
                        commit=str(raw["commit"]),
                        license=str(raw["license"]),
                        path=raw.get("path"),
                        url=raw.get("url"),
                        language=raw.get("language"),
                    )
                )
        return cls(records)

    def sample(self, seed: int) -> RepoRecord:
        return random.Random(seed).choice(self.records)


def _run(argv: list[str], cwd: Path | None = None, timeout: int = 180) -> None:
    completed = subprocess.run(
        argv,
        cwd=cwd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=timeout,
        check=False,
    )
    if completed.returncode != 0:
        raise RuntimeError(f"command failed ({completed.returncode}): {' '.join(argv)}\n{completed.stdout[-4000:]}")


def checkout_repository(record: RepoRecord, cache_dir: str | Path) -> Path:
    """Return a pinned source directory without modifying the caller's repository."""

    if record.path is not None:
        path = Path(record.path).expanduser().resolve()
        if not path.is_dir():
            raise FileNotFoundError(path)
        return path

    assert record.url is not None
    cache = Path(cache_dir).expanduser().resolve()
    cache.mkdir(parents=True, exist_ok=True)
    safe = _SAFE_NAME.sub("_", record.name)
    destination = cache / f"{safe}-{record.commit[:12]}"
    if not destination.exists():
        _run(["git", "clone", "--filter=blob:none", "--no-checkout", record.url, str(destination)])
    _run(["git", "fetch", "--depth", "1", "origin", record.commit], cwd=destination)
    _run(["git", "checkout", "--detach", record.commit], cwd=destination)
    return destination

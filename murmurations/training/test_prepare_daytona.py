from __future__ import annotations

import unittest

from murmurations.training.prepare_daytona import (
    _create_snapshot_with_name_release_grace,
    _delete_snapshot_and_wait,
)


class _NotFound(Exception):
    pass


class _Conflict(Exception):
    pass


class _Snapshot:
    id = "snapshot-123"
    name = "murmurations-corpus-v1"


class _SnapshotService:
    def __init__(self) -> None:
        self.get_results = []
        self.deleted = []
        self.create_results = []
        self.create_calls = 0

    def get(self, _name: str):
        result = self.get_results.pop(0)
        if isinstance(result, Exception):
            raise result
        return result

    def delete(self, snapshot) -> None:
        self.deleted.append(snapshot)

    def create(self, _params, *, on_logs=None, timeout=0):
        self.create_calls += 1
        result = self.create_results.pop(0)
        if isinstance(result, Exception):
            raise result
        return result


class _Daytona:
    def __init__(self, service: _SnapshotService) -> None:
        self.snapshot = service


class PrepareDaytonaTests(unittest.TestCase):
    def test_delete_waits_until_snapshot_is_not_found(self) -> None:
        service = _SnapshotService()
        existing = _Snapshot()
        service.get_results = [existing, existing, _NotFound()]
        daytona = _Daytona(service)

        deleted = _delete_snapshot_and_wait(
            daytona,
            existing.name,
            not_found_error=_NotFound,
            timeout_seconds=1,
            poll_seconds=0,
        )

        self.assertTrue(deleted)
        self.assertEqual(service.deleted, [existing])

    def test_replace_retries_short_name_release_conflict(self) -> None:
        service = _SnapshotService()
        created = _Snapshot()
        service.create_results = [_Conflict(), created]
        daytona = _Daytona(service)

        result = _create_snapshot_with_name_release_grace(
            daytona,
            object(),
            on_logs=None,
            conflict_error=_Conflict,
            allow_conflict_retry=True,
            timeout_seconds=1,
            poll_seconds=0,
        )

        self.assertIs(result, created)
        self.assertEqual(service.create_calls, 2)

    def test_non_replace_does_not_retry_conflict(self) -> None:
        service = _SnapshotService()
        service.create_results = [_Conflict()]
        daytona = _Daytona(service)

        with self.assertRaises(_Conflict):
            _create_snapshot_with_name_release_grace(
                daytona,
                object(),
                on_logs=None,
                conflict_error=_Conflict,
                allow_conflict_retry=False,
                timeout_seconds=1,
                poll_seconds=0,
            )
        self.assertEqual(service.create_calls, 1)


if __name__ == "__main__":
    unittest.main()

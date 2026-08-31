from __future__ import annotations

import unittest

from murmurations.utils.canonical import canonical_id
from murmurations.utils.dag import MerkleDag
from murmurations.utils.population import PopulationContext
from murmurations.utils.protocol import ActionFrame, ArgumentKind, Operation


class ProtocolTests(unittest.TestCase):
    def test_canonical_identity_is_order_independent_for_maps(self) -> None:
        self.assertEqual(
            canonical_id({"b": 2, "a": 1}),
            canonical_id({"a": 1, "b": 2}),
        )

    def test_parent_closure_is_enforced(self) -> None:
        dag = MerkleDag()
        missing = "b3:" + "00" * 32
        with self.assertRaises(ValueError):
            dag.add(ActionFrame(Operation.CLAIM, parents=(missing,)))

    def test_dag_tracks_ancestry(self) -> None:
        dag = MerkleDag()
        evidence = dag.add(
            ActionFrame(Operation.EVIDENCE, ArgumentKind.TEXT, "compiler failed")
        )
        claim = dag.add(
            ActionFrame(
                Operation.CLAIM,
                ArgumentKind.TEXT,
                "bounds failure",
                parents=(evidence.id,),
            )
        )
        challenge = dag.add(
            ActionFrame(
                Operation.CHALLENGE,
                ArgumentKind.CLAIM,
                claim.id,
                parents=(claim.id,),
            )
        )
        dag.verify()
        self.assertEqual(dag.ancestors(challenge.id), {claim.id, evidence.id})

    def test_execute_frame_carries_retrieved_operator_reference(self) -> None:
        frame = ActionFrame(
            Operation.EXECUTE,
            ArgumentKind.SYMBOL,
            "src/root.zig",
            operator_ref="repo.tests",
        )
        self.assertEqual(frame.record()["version"], 2)
        self.assertEqual(frame.record()["operator_ref"], "repo.tests")

    def test_population_accepts_greek_aliases(self) -> None:
        population = PopulationContext.from_mapping(
            {"A": [], "G": {}, "X": {}, "M": {}, "F": {}, "Π": {}, "C": {}, "Φ": {}, "J": {}}
        )
        self.assertIn("<POPULATION>", population.render())


if __name__ == "__main__":
    unittest.main()

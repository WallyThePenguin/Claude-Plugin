import unittest
from validate_rubric import validate

GOOD = {
    "module": "locomotion", "version": "1", "system_module": "locomotion",
    "criteria": [{
        "id": "loco-good-blendtree", "order_index": 1, "tier": "good",
        "statement": "Locomotion warps by speed AND direction via a blend tree.",
        "above_generic_rationale": "Default Roblox plays one forward loop.",
        "grading": {"pass": "blend tree present", "partial": "speed only", "fail": "single loop"},
        "evidence_required": "strafing shows distinct side motion",
        "concrete_fix": "add a 2D blend space keyed to velocity"
    }]
}


class T(unittest.TestCase):
    def test_good_rubric_passes(self):
        ok, errors = validate(GOOD)
        self.assertTrue(ok, errors)

    def test_missing_criteria_fails(self):
        ok, errors = validate({"module": "x", "version": "1", "system_module": "x"})
        self.assertFalse(ok)

    def test_bad_tier_fails(self):
        bad = {**GOOD, "criteria": [{**GOOD["criteria"][0], "tier": "amazing"}]}
        ok, errors = validate(bad)
        self.assertFalse(ok)

    def test_missing_grading_field_fails(self):
        bad = {**GOOD, "criteria": [{**GOOD["criteria"][0], "grading": {"pass": "x"}}]}
        ok, errors = validate(bad)
        self.assertFalse(ok)


if __name__ == "__main__":
    unittest.main()

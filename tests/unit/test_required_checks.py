"""The required-checks guard reads job names from ci.yml; make sure that parse works."""

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))

import check_required_checks as crc


def test_ci_job_names_parses_real_workflow() -> None:
    names = crc.ci_job_names()
    assert len(names) >= 10
    assert ".env Parser Contract" in names

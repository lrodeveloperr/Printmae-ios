#!/usr/bin/env python3
"""Fail the release gate when Muter's reported score is below the contract."""

import re
import sys
from pathlib import Path


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: check_mutation_score.py REPORT MINIMUM_PERCENT", file=sys.stderr)
        return 2
    report = Path(sys.argv[1]).read_text(errors="replace")
    minimum = float(sys.argv[2])
    matches = re.findall(
        r"mutation score(?: of test suite)?\s*:?\s*(\d+(?:\.\d+)?)\s*%",
        report,
        re.IGNORECASE,
    )
    if not matches:
        print("could not find Muter's mutation score in the report", file=sys.stderr)
        return 1
    score = float(matches[-1])
    print(f"Mutation score: {score:g}% (required: {minimum:g}%)")
    return 0 if score >= minimum else 1


if __name__ == "__main__":
    raise SystemExit(main())

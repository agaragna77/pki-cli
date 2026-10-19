#!/usr/bin/env python3
# Authors:
#     Alessandro Garagnani <agaragna@redhat.com>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# Copyright (C) 2026 Alessandro Garagnani
#

"""Propose a catalogue entry (append draft to results.yaml).

Humans must classify rest-defect vs api-gap. Passing either of those statuses
without --confirm-classification leaves status unset and sets
classification_todo: true.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

import yaml

ALLOWED = frozenset({"pass", "rest-defect", "api-gap", "java-bound"})
NEEDS_HUMAN = frozenset({"rest-defect", "api-gap"})
ROOT = Path(__file__).resolve().parents[1]
YAML_PATH = ROOT / "catalogue" / "results.yaml"


def slug(command: str) -> str:
    s = re.sub(r"[^a-zA-Z0-9]+", "-", command.strip()).strip("-").lower()
    return s or "entry"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--command", required=True, help="Command string, e.g. 'pki-cli info'")
    parser.add_argument(
        "--status",
        required=True,
        choices=sorted(ALLOWED),
        help="Catalogue status (rest-defect/api-gap need --confirm-classification)",
    )
    parser.add_argument("--notes", default="", help="Free-form notes")
    parser.add_argument(
        "--id",
        default=None,
        help="Entry id (default: derived from command)",
    )
    parser.add_argument(
        "--confirm-classification",
        action="store_true",
        help="Required to finalize rest-defect or api-gap (human classification)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the draft entry; do not write YAML",
    )
    args = parser.parse_args()

    entry_id = args.id or slug(args.command)
    status = args.status
    classification_todo = False

    if status in NEEDS_HUMAN and not args.confirm_classification:
        # Do not invent final classification — leave for a human.
        status = None
        classification_todo = True
        proposed = args.status
        notes = args.notes
        if notes:
            notes = f"{notes} [proposed status: {proposed}; needs human confirm]"
        else:
            notes = f"[proposed status: {proposed}; needs human confirm]"
    else:
        notes = args.notes
        proposed = status

    entry = {
        "id": entry_id,
        "command": args.command,
        "status": status,
        "notes": notes,
        "classification_todo": classification_todo,
    }
    if classification_todo:
        entry["proposed_status"] = proposed

    print(yaml.safe_dump({"entry": entry}, sort_keys=False), end="")

    if args.dry_run:
        return 0

    data = yaml.safe_load(YAML_PATH.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        data = {"version": 1, "entries": []}
    entries = data.setdefault("entries", [])
    for existing in entries:
        if existing.get("id") == entry_id:
            print(f"ERROR: id {entry_id!r} already exists", file=sys.stderr)
            return 1
    # YAML null for unset status
    entries.append(entry)
    YAML_PATH.write_text(
        yaml.safe_dump(data, sort_keys=False, allow_unicode=True),
        encoding="utf-8",
    )
    print(f"Appended {entry_id!r} to {YAML_PATH.relative_to(ROOT)}", file=sys.stderr)
    print("Run: python scripts/catalogue_regen.py", file=sys.stderr)
    return 0


if __name__ == "__main__":
    sys.exit(main())

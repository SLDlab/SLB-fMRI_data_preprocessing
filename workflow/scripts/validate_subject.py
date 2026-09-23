#!/usr/bin/env python3

import csv
import json
import sys
from pathlib import Path


REQUIRED_COLUMNS = {
    "onset",
    "duration",
    "trial_type",
}


def load_json(path):
    with open(path) as f:
        return json.load(f)


def events_columns(path):
    with open(path, newline="") as f:
        return set(next(csv.reader(f, delimiter="\t")))


def relative(path, root):
    return str(path.relative_to(root))


def main():

    bids_root = Path(sys.argv[1])
    participant = sys.argv[2]

    output = Path(sys.argv[3])

    subject = bids_root / f"sub-{participant}"

    report = {
        "participant": participant,
        "summary": {},
        "errors": [],
        "warnings": [],
    }

    #########################################################
    # T1
    #########################################################

    t1 = list(subject.glob("anat/*_T1w.nii.gz"))

    report["anat"] = {
        "t1w": [relative(x, bids_root) for x in t1]
    }

    if len(t1) != 1:
        report["errors"].append(
            f"Expected exactly one T1w, found {len(t1)}"
        )

    #########################################################
    # Functional
    #########################################################

    bold = sorted(subject.glob("func/*_bold.nii.gz"))

    func = []

    for bold_file in bold:

        stem = bold_file.name.replace("_bold.nii.gz", "")

        json_file = bold_file.with_name(stem + "_bold.json")
        events_file = bold_file.with_name(stem + "_events.tsv")

        entry = {
            "run": stem,
            "bold": bold_file.exists(),
            "json": json_file.exists(),
            "events": events_file.exists(),
            "columns_ok": False,
        }

        if events_file.exists():

            cols = events_columns(events_file)

            missing = REQUIRED_COLUMNS - cols

            if missing:

                report["errors"].append(
                    f"{events_file.name} missing {sorted(missing)}"
                )

            else:
                entry["columns_ok"] = True

        if not json_file.exists():

            report["errors"].append(
                f"Missing {json_file.name}"
            )

        if not events_file.exists():

            report["errors"].append(
                f"Missing {events_file.name}"
            )

        func.append(entry)

    report["functional"] = func

    #########################################################
    # Fieldmaps
    #########################################################

    fmap = sorted(subject.glob("fmap/*_epi.json"))

    fmap_summary = []

    for fmap_json in fmap:

        data = load_json(fmap_json)

        intended = data.get("IntendedFor", [])

        if not intended:

            report["errors"].append(
                f"{fmap_json.name} missing IntendedFor"
            )

        missing = []

        for target in intended:

            target = target.replace(f"sub-{participant}/", "")

            if not (subject / target).exists():
                missing.append(target)

        if missing:

            report["errors"].append(
                f"{fmap_json.name}: missing targets {missing}"
            )

        fmap_summary.append(
            {
                "file": fmap_json.name,
                "targets": len(intended),
            }
        )

    report["fieldmaps"] = fmap_summary

    #########################################################
    # Summary
    #########################################################

    report["summary"] = {

        "ready": len(report["errors"]) == 0,

        "error_count": len(report["errors"]),

        "warning_count": len(report["warnings"]),
    }

    output.parent.mkdir(
        parents=True,
        exist_ok=True,
    )

    with open(output, "w") as f:
        json.dump(report, f, indent=4)


if __name__ == "__main__":
    main()

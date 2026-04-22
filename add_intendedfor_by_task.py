#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
from typing import Dict, List, Tuple, Optional

"""
Adds IntendedFor to fmap JSONs based on task→acq mapping.

UPDATED FOR RUN-STYLE NAMING:
  sub-XXX_task-tm_run-01_bold.nii.gz
  sub-XXX_task-tm_run-02_bold.nii.gz
  ... etc

Backward compatible with old names like:
  sub-XXX_task-tm1_bold.nii.gz
  sub-XXX_task-th2_bold.nii.gz
  sub-XXX_task-obslearn2_bold.nii.gz
  sub-XXX_task-risksocial1_bold.nii.gz
"""

# ----------------------------
# Config: base task → fmap acquisition label
# ----------------------------
# New task names (base):
#   obslearn, riskself, risksocial, th, tm
#
# Fieldmap acq labels remain:
#   acq-obslearn, acq-risk, acq-trust
TASK_TO_ACQ = {
    "obslearn": "obslearn",
    "riskself": "risk",
    "risksocial": "risk",
    "th": "trust",
    "tm": "trust",
}

# Any fmap JSONs that contain these tokens will be ignored
IGNORE_FMAP_TOKENS = ("phasediff", "magnitude", "fieldmap")  # not used in your current EPI-PE setup


def read_json(p: Path) -> Dict:
    with p.open("r") as f:
        return json.load(f)


def write_json(p: Path, obj: Dict) -> None:
    tmp = p.with_suffix(p.suffix + ".tmp")
    with tmp.open("w") as f:
        json.dump(obj, f, indent=2, sort_keys=False)
        f.write("\n")
    tmp.replace(p)


def rel_to_subject_dir(subject_dir: Path, target: Path) -> str:
    return str(target.relative_to(subject_dir)).replace("\\", "/")


def list_subjects(bids_root: Path, subjects: List[str]) -> List[str]:
    if subjects:
        return subjects
    return sorted([p.name for p in bids_root.glob("sub-*") if p.is_dir()])


def parse_task_run_from_bold_name(fname: str) -> Tuple[Optional[str], Optional[str]]:
    """
    Supports:
      - sub-XXX_task-tm_run-01_bold.nii.gz        -> ("tm", "01")
      - sub-XXX_task-tm_bold.nii.gz               -> ("tm", None)
      - sub-XXX_task-tm1_bold.nii.gz              -> ("tm", "01")   (old)
      - sub-XXX_task-obslearn2_bold.nii.gz        -> ("obslearn", "02") (old)
      - sub-XXX_task-risksocial1_bold.nii.gz      -> ("risksocial", "01") (old)
    """
    if "_task-" not in fname or "_bold" not in fname:
        return (None, None)

    # chunk like: "<taskstuff>_run-01_bold..." OR "<taskstuff>_bold..."
    taskstuff = fname.split("_task-")[1].split("_bold")[0]

    # New style: task-<base>_run-XX
    if "_run-" in taskstuff:
        base = taskstuff.split("_run-")[0]
        run = taskstuff.split("_run-")[1].split("_")[0]
        # normalize run to 2 digits if numeric
        if run.isdigit():
            run = f"{int(run):02d}"
        return (base, run)

    # Old style: task-<base><digit>  (e.g., tm1, th2, obslearn2, risksocial1)
    # Only treat a trailing single digit as run if present
    base = taskstuff
    run = None
    if len(base) >= 2 and base[-1].isdigit():
        run = f"{int(base[-1]):02d}"
        base = base[:-1]
    return (base, run)


def collect_bolds(subject_dir: Path) -> Dict[str, List[Path]]:
    """
    Returns: base_task -> list of bold file paths (absolute paths)
    """
    func_dir = subject_dir / "func"
    if not func_dir.exists():
        return {}

    bolds: Dict[str, List[Path]] = {}
    for bold in sorted(func_dir.glob("*_bold.nii.gz")):
        task, run = parse_task_run_from_bold_name(bold.name)
        if not task:
            continue
        bolds.setdefault(task, []).append(bold)

    return bolds


def collect_fmap_jsons(subject_dir: Path) -> List[Path]:
    fmap_dir = subject_dir / "fmap"
    if not fmap_dir.exists():
        return []
    jsons = []
    for j in sorted(fmap_dir.glob("*.json")):
        low = j.name.lower()
        if any(tok in low for tok in IGNORE_FMAP_TOKENS):
            continue
        if not low.endswith("_epi.json"):
            continue
        jsons.append(j)
    return jsons


def fmap_acq_label_from_name(fname: str) -> str:
    # Example: sub-000_acq-risk_dir-AP_epi.json -> "risk"
    if "_acq-" not in fname:
        return ""
    return fname.split("_acq-")[1].split("_")[0]


def build_mapping(subject_dir: Path) -> Tuple[Dict[Path, List[str]], List[str]]:
    warnings = []
    bolds_by_task = collect_bolds(subject_dir)
    fmap_jsons = collect_fmap_jsons(subject_dir)

    if not bolds_by_task:
        warnings.append("No BOLD files found in func/.")
    if not fmap_jsons:
        warnings.append("No fmap EPI JSON files found in fmap/.")

    # Build IntendedFor lists grouped by acq label
    intended_by_acq: Dict[str, List[str]] = {}
    for task, bolds in bolds_by_task.items():
        if task not in TASK_TO_ACQ:
            warnings.append(f"Task '{task}' not in TASK_TO_ACQ mapping; skipping for IntendedFor.")
            continue
        acq = TASK_TO_ACQ[task]
        for b in bolds:
            intended_by_acq.setdefault(acq, []).append(rel_to_subject_dir(subject_dir, b))

    # Map each fmap json to its IntendedFor list based on its acq label
    fmap_to_intended: Dict[Path, List[str]] = {}
    for fmap_json in fmap_jsons:
        acq = fmap_acq_label_from_name(fmap_json.name)
        if not acq:
            warnings.append(f"Fieldmap JSON has no acq- entity: {fmap_json.name} (skipping)")
            continue

        targets = intended_by_acq.get(acq, [])
        if not targets:
            warnings.append(
                f"Fieldmap {fmap_json.name} acq='{acq}' matched 0 BOLD runs (check task naming/mapping)."
            )

        targets = sorted(list(dict.fromkeys(targets)))
        fmap_to_intended[fmap_json] = targets

    return fmap_to_intended, warnings


def validate_mapping(subject_dir: Path, fmap_to_intended: Dict[Path, List[str]]) -> List[str]:
    problems = []

    fmap_dir = subject_dir / "fmap"
    func_dir = subject_dir / "func"

    # Check AP/PA pairing per acq
    by_acq: Dict[str, List[str]] = {}
    for fmap_json in fmap_to_intended.keys():
        acq = fmap_acq_label_from_name(fmap_json.name)
        by_acq.setdefault(acq, []).append(fmap_json.name)

    for acq, files in by_acq.items():
        has_ap = any("_dir-AP_" in f for f in files)
        has_pa = any("_dir-PA_" in f for f in files)
        if not (has_ap and has_pa):
            problems.append(f"[PAIR] acq='{acq}' missing AP or PA: {files}")

    # Check IntendedFor targets exist
    for fmap_json, targets in fmap_to_intended.items():
        for rel in targets:
            p = subject_dir / rel
            if not p.exists():
                problems.append(f"[MISSING] IntendedFor target does not exist for {fmap_json.name}: {rel}")
            if not rel.startswith("func/"):
                problems.append(f"[SANITY] IntendedFor not in func/ for {fmap_json.name}: {rel}")

    if not fmap_dir.exists():
        problems.append("[SANITY] fmap/ directory missing")
    if not func_dir.exists():
        problems.append("[SANITY] func/ directory missing")

    return problems


def update_subject(bids_root: Path, sub: str, dry_run: bool, report_dir: Path) -> int:
    subject_dir = bids_root / sub
    print(f"\n=== Processing {sub} ===")

    fmap_to_intended, warnings = build_mapping(subject_dir)

    # Print tasks found
    bolds_by_task = collect_bolds(subject_dir)
    if bolds_by_task:
        print("  Base tasks found:")
        for t in sorted(bolds_by_task.keys()):
            print(f"    {t}: {len(bolds_by_task[t])} file(s)")

    for w in warnings:
        print(f"  [WARN] {w}")

    problems = validate_mapping(subject_dir, fmap_to_intended)
    if problems:
        print("  [VALIDATION] Problems found:")
        for p in problems:
            print(f"    - {p}")

    report_dir.mkdir(parents=True, exist_ok=True)
    report_path = report_dir / f"{sub}_intendedfor_report.json"
    report_obj = {
        "subject": sub,
        "warnings": warnings,
        "validation_problems": problems,
        "mapping": {
            str(k.relative_to(subject_dir)).replace("\\", "/"): v
            for k, v in fmap_to_intended.items()
        },
    }
    if dry_run:
        print(f"  [DRY-RUN] Would write report: {report_path}")
    else:
        write_json(report_path, report_obj)
        print(f"  [OK] Wrote report: {report_path}")

    # Apply IntendedFor updates
    for fmap_json, targets in fmap_to_intended.items():
        obj = read_json(fmap_json)
        old = obj.get("IntendedFor", None)

        if old == targets:
            print(f"  [SKIP] {fmap_json.name} IntendedFor already up-to-date ({len(targets)} targets).")
            continue

        obj["IntendedFor"] = targets
        if dry_run:
            print(f"  [DRY-RUN] Would update {fmap_json.name}: IntendedFor={len(targets)} target(s)")
        else:
            write_json(fmap_json, obj)
            print(f"  [OK] Updated {fmap_json.name}: IntendedFor={len(targets)} target(s)")

    return 1 if problems else 0


def main():
    ap = argparse.ArgumentParser(description="Add IntendedFor to fmap JSONs based on task→acq mapping.")
    ap.add_argument("bids_root", type=str, help="Path to BIDS root")
    ap.add_argument("subjects", nargs="*", help="Optional list like sub-000 sub-001 ... (default: all)")
    ap.add_argument("--dry-run", action="store_true", help="Print actions but do not modify files")
    ap.add_argument(
        "--report-dir",
        type=str,
        default="code/intendedfor_reports",
        help="Where to write mapping reports (relative to BIDS root unless absolute)",
    )
    args = ap.parse_args()

    bids_root = Path(args.bids_root).resolve()
    if not bids_root.exists():
        raise SystemExit(f"BIDS root not found: {bids_root}")

    report_dir = Path(args.report_dir)
    if not report_dir.is_absolute():
        report_dir = (bids_root / report_dir).resolve()

    subs = list_subjects(bids_root, args.subjects)
    print(f"BIDS root: {bids_root}")
    print(f"Subjects: {subs}")
    print(f"Report dir: {report_dir}")
    print(f"Mode: {'DRY-RUN' if args.dry_run else 'WRITE'}")

    any_fail = 0
    for sub in subs:
        if not sub.startswith("sub-"):
            raise SystemExit(f"Subject must be like sub-000, got: {sub}")
        rc = update_subject(bids_root, sub, args.dry_run, report_dir)
        any_fail = max(any_fail, rc)

    if any_fail:
        print("\n[DONE] Completed with validation problems. Fix those before trusting SDC.")
    else:
        print("\n[DONE] Completed with no validation problems.")


if __name__ == "__main__":
    main()

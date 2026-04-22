#!/usr/bin/env python3
"""
combined_build_bids_events_from_behavioral_runs.py

Converts preprocessed behavioral CSVs into BIDS-compliant events.tsv files
for three tasks: OL (Observational Learning), SRA (Social Risk Aversion),
and Trust (TM/TH).

Usage:
    python build_bids_events_from_behavioral_runs.py [ol|sra|trust|all]

Defaults to 'all' if no argument is given.

================================================================================
OL (task-obslearn)
================================================================================
Logic is dictionary-driven (OL-DataDictionaryfMRI.csv):
  - "Pivot to onset" rows define onset columns
  - matching "Pivot to duration" rows define duration columns
  - "trial_type label in .tsv file" defines BIDS trial_type
  - "Separate column" rows are copied into every output event row

Event types:
  Observe trials (trType == 1):
    observe_start, observe_stimulus, observe_wait, observe_video, iti_fixation
  Play trials (trType == 2), responded == 1:
    play_start, play_choice, play_validation, play_wait, play_token, iti_fixation
  Play trials (trType == 2), responded == 0 (missed):
    play_start, play_choice, miss, iti_fixation
    (miss collapses validation + wait_token + token)

================================================================================
SRA (task-riskself / task-risksocial)
================================================================================
Logic is dictionary-driven (SRA-DataDictionaryfMRI.csv).

Self block (task-riskself):
  self_choice, self_choice_validation / self_missed, self_iti

Social block (task-risksocial):
  social_infoseek, social_infoseek_validation / social_infoseek_missed,
  social_fixation1, social_info, social_fixation2,
  social_choice, social_choice_validation / social_choice_missed, social_iti

================================================================================
Trust (task-tm / task-th)
================================================================================
Event types per trial:
  new_partner   - partner introduction (once per partner block)
  fixation      - inter-trial fixation cross
  choice_success / choice_miss  - decision screen
  wait_success  / wait_miss     - waiting screen
  feedback      - outcome screen
"""

import ast
import sys
from pathlib import Path

import pandas as pd


# ==============================================================================
# Shared paths
# ==============================================================================
BEHAV_ROOT = Path("/data/sld/homes/collab/slb/behav_data/fMRI/data")

# Each task writes to its own BIDS root; adjust as needed.
OL_BIDS_ROOT    = Path("/data/sld/homes/collab/bids_runs")
SRA_BIDS_ROOT   = Path("/data/sld/homes/collab/bids_runs")
TRUST_BIDS_ROOT = Path("/data/sld/homes/collab/bids_runs")

# Data dictionaries
OL_DICT    = Path("/data/sld/homes/collab/slb/behav_data/fMRI/data_dictionaries/OL-DataDictionaryfMRI.csv")
SRA_DICT   = Path("/data/sld/homes/collab/slb/behav_data/fMRI/data_dictionaries/SRA-DataDictionaryfMRI.csv")
TRUST_DICT = Path("/data/sld/homes/collab/slb/behav_data/fMRI/data_dictionaries/Trust-DataDictionaryfMRI.csv")

# ---------- Task run definitions ----------
OL_TASK_RUNS = [
    # (condition folder, run folder name, BIDS task label, BIDS run label)
    ("ol", "run-01", "obslearn", "01"),
    ("ol", "run-02", "obslearn", "02"),
]

SRA_TASK_RUNS = [
    # (cond_folder, run_folder, BIDS task label, BIDS run label or None, block)
    ("socialra", "run-self",      "riskself",   None, "self"),
    ("socialra", "run-social-01", "risksocial", "01", "social"),
    ("socialra", "run-social-02", "risksocial", "02", "social"),
]

TRUST_TASK_RUNS = [
    # (condition folder, run folder name, BIDS task label, BIDS run label)
    ("tm", "run-01", "tm", "01"),
    ("tm", "run-02", "tm", "02"),
    ("th", "run-01", "th", "01"),
    ("th", "run-02", "th", "02"),
]


# ==============================================================================
# Shared file-discovery utilities
# ==============================================================================

def discover_subjects_from_behav_root():
    subjects = []
    for p in sorted(BEHAV_ROOT.glob("SLB_*")):
        if p.is_dir():
            subj = p.name.replace("SLB_", "")
            if subj:
                subjects.append(subj)
    return sorted(subjects)


def _candidate_cond_dirs(subj, cond):
    subj_dir = BEHAV_ROOT / f"SLB_{subj}"
    dirs = [
        subj_dir / cond,
        subj_dir / cond.lower(),
        subj_dir / cond.upper(),
        subj_dir / cond.capitalize(),
    ]
    out, seen = [], set()
    for d in dirs:
        if d not in seen:
            out.append(d)
            seen.add(d)
    return out


def _pick_one_csv(hits, label):
    if len(hits) == 1:
        return hits[0]
    pref = [p for p in hits if "preprocessed" in p.name.lower()]
    if len(pref) == 1:
        return pref[0]
    if len(pref) > 1:
        hits = pref
    hits = sorted(hits, key=lambda p: p.stat().st_mtime, reverse=True)
    print(f"[WARN] {label}: multiple CSVs found; using newest: {hits[0].name}")
    return hits[0]


def find_csv(subj, cond, run_dir):
    """
    Preferred:  .../SLB_<subj>/<cond>/preprocessed/<run_dir>/*.csv
    Fallbacks:  .../SLB_<subj>/<cond>/preprocessed/*.csv
                .../SLB_<subj>/<cond>/*.csv
    """
    cond_path = None
    for d in _candidate_cond_dirs(subj, cond):
        if d.exists():
            cond_path = d
            break
    if cond_path is None:
        raise RuntimeError(f"Condition dir not found for sub={subj} cond={cond}")

    pre_dir = cond_path / "preprocessed"
    label   = f"sub-{subj} cond={cond} run={run_dir}"

    run_path = pre_dir / run_dir
    if run_path.exists():
        hits = sorted(run_path.glob("*.csv"))
        if hits:
            return _pick_one_csv(hits, label)

    if pre_dir.exists():
        hits = sorted(pre_dir.glob("*.csv"))
        if hits:
            return _pick_one_csv(hits, label)

    hits = sorted(cond_path.glob("*.csv"))
    if hits:
        return _pick_one_csv(hits, label)

    raise RuntimeError(
        f"No .csv found for {label} (checked {run_path}, {pre_dir}, {cond_path})"
    )


# ==============================================================================
# Shared DataFrame utilities
# ==============================================================================

def coerce_numeric(df, cols, label):
    for c in cols:
        if c not in df.columns:
            raise RuntimeError(f"{label}: missing required column: {c}")
        df[c] = pd.to_numeric(df[c], errors="coerce")
    return df


def finalize_events_df(out, label):
    first_cols = ["onset", "duration", "trial_type"]
    extra_cols = [c for c in out.columns if c not in first_cols]
    out = out.loc[:, first_cols + extra_cols]

    if not out["onset"].is_monotonic_increasing:
        raise RuntimeError(f"{label}: output onsets not monotonic increasing")
    if (out["duration"] < 0).any():
        bad = out.index[out["duration"] < 0].tolist()[:10]
        raise RuntimeError(f"{label}: negative durations at output rows {bad}")

    return out


def out_path(bids_root, subj, task, run_label):
    func_dir = bids_root / f"sub-{subj}" / "func"
    if run_label is None:
        fname = f"sub-{subj}_task-{task}_events.tsv"
    else:
        fname = f"sub-{subj}_task-{task}_run-{run_label}_events.tsv"
    return func_dir / fname


# ==============================================================================
# OL (Observational Learning)
# ==============================================================================

# Missed-trial constants
OL_MISS_SUPPRESSED = {"play_validation", "play_wait", "play_token"}
OL_MISS_ONSET_COL  = "scannerTimer_feedback_Start"
OL_MISS_DUR_COLS   = ["feedback_dur", "wait_token_dur", "token_dur"]


def _clean_scalar(x):
    """Convert list-like strings such as '[1.075]' into scalar 1.075."""
    if pd.isna(x):
        return x
    if isinstance(x, list):
        if len(x) == 0:
            return pd.NA
        return x[0] if len(x) == 1 else str(x)
    if isinstance(x, str):
        s = x.strip()
        if s.startswith("[") and s.endswith("]"):
            try:
                parsed = ast.literal_eval(s)
                if isinstance(parsed, list):
                    if len(parsed) == 0:
                        return pd.NA
                    return parsed[0] if len(parsed) == 1 else str(parsed)
            except Exception:
                return x
    return x


def _ol_clean_rt_columns(df):
    for col in df.columns:
        if col.endswith("_RT") or col == "choice_RT":
            df[col] = df[col].apply(_clean_scalar)
            df[col] = pd.to_numeric(df[col], errors="coerce")
    return df


def load_ol_dictionary(data_dict_path):
    """
    Returns:
      carry_cols : list[str]   – columns to pass through to output TSV
      event_specs: list[dict]  – {onset_col, duration_col, trial_type}
      pivot_cols : list[str]   – all internally-used pivot columns (excluded from TSV)
    """
    dd = pd.read_csv(data_dict_path)
    for c in ["Variable", "Keep in .tsv file", "trial_type label in .tsv file"]:
        if c not in dd.columns:
            raise RuntimeError(f"OL dictionary missing required column: {c}")

    var  = dd["Variable"].astype(str).str.strip()
    keep = dd["Keep in .tsv file"].astype(str).str.strip()

    carry_cols = var[keep == "Separate column"].tolist()

    onset_rows = dd.loc[keep == "Pivot to onset",    :].copy()
    dur_rows   = dd.loc[keep == "Pivot to duration", :].copy()

    if len(onset_rows) == 0:
        raise RuntimeError("No 'Pivot to onset' rows found in OL dictionary")
    if len(dur_rows) == 0:
        raise RuntimeError("No 'Pivot to duration' rows found in OL dictionary")

    dur_map = {}
    for _, row in dur_rows.iterrows():
        tt  = str(row["trial_type label in .tsv file"]).strip()
        col = str(row["Variable"]).strip()
        dur_map.setdefault(tt, []).append(col)

    event_specs   = []
    dur_use_count = {}
    for _, row in onset_rows.iterrows():
        onset_col  = str(row["Variable"]).strip()
        trial_type = str(row["trial_type label in .tsv file"]).strip()
        if not trial_type or trial_type.lower() == "nan":
            raise RuntimeError(f"OL onset column {onset_col} has no trial_type label")
        candidates = dur_map.get(trial_type, [])
        if not candidates:
            raise RuntimeError(
                f"No duration row for trial_type '{trial_type}' (onset: {onset_col})"
            )
        idx = dur_use_count.get(trial_type, 0)
        if idx >= len(candidates):
            raise RuntimeError(f"More onset rows than duration rows for '{trial_type}'")
        event_specs.append({
            "onset_col":    onset_col,
            "duration_col": candidates[idx],
            "trial_type":   trial_type,
        })
        dur_use_count[trial_type] = idx + 1

    pivot_cols = sorted(set(
        [s["onset_col"] for s in event_specs] +
        [s["duration_col"] for s in event_specs]
    ))
    carry_cols = [c for c in carry_cols if c not in pivot_cols]

    return carry_cols, event_specs, pivot_cols


def _ol_label_allowed(trial_type, tr_type):
    if trial_type.startswith("observe_"):
        return tr_type == 1
    if trial_type.startswith("play_"):
        return tr_type == 2
    if trial_type == "iti_fixation":
        return tr_type in (1, 2)
    return True


def build_ol_events(df, carry_cols, event_specs, label):
    df = _ol_clean_rt_columns(df)

    for forced in ["trialNb", "trType"]:
        if forced in df.columns and forced not in carry_cols:
            carry_cols.append(forced)

    needed_cols = sorted(set(
        [s["onset_col"] for s in event_specs] +
        [s["duration_col"] for s in event_specs] +
        ["trialNb", "trType", "responded"] +
        OL_MISS_DUR_COLS + [OL_MISS_ONSET_COL]
    ))
    df = coerce_numeric(df, needed_cols, label)

    onset_cols  = [s["onset_col"] for s in event_specs]
    trial_mask  = df[onset_cols].notna().any(axis=1)
    trials      = df.loc[trial_mask, :].copy()

    if len(trials) == 0:
        raise RuntimeError(f"{label}: found 0 trials (no non-null onset rows)")

    bad_trtype = trials.loc[~trials["trType"].isin([1, 2]), ["trialNb", "trType"]].head(10)
    if len(bad_trtype) > 0:
        raise RuntimeError(f"{label}: unexpected trType values:\n{bad_trtype}")

    play_trials = trials.loc[trials["trType"] == 2]
    bad_resp = play_trials.loc[
        ~play_trials["responded"].isin([0, 1]), ["trialNb", "responded"]
    ].head(10)
    if len(bad_resp) > 0:
        raise RuntimeError(f"{label}: unexpected 'responded' values on play trials:\n{bad_resp}")

    trials["_sort"] = trials[onset_cols].min(axis=1, skipna=True)
    trials = trials.sort_values("_sort", kind="mergesort").reset_index(drop=True)
    trials = trials.drop(columns=["_sort"])

    carry = [c for c in carry_cols if c in trials.columns]

    rows = []
    for i in range(len(trials)):
        t       = trials.iloc[i]
        tr_type = int(t["trType"])
        base    = {c: t[c] for c in carry}
        base["trialNb"] = int(t["trialNb"])
        base["trType"]  = tr_type
        is_miss = (tr_type == 2) and (int(t["responded"]) == 0)
        emitted = 0

        for spec in event_specs:
            tt = spec["trial_type"]
            if not _ol_label_allowed(tt, tr_type):
                continue
            if is_miss and tt in OL_MISS_SUPPRESSED:
                continue
            onset    = t[spec["onset_col"]]
            duration = t[spec["duration_col"]]
            if pd.isna(onset) or pd.isna(duration):
                continue
            if duration <= 0:
                raise RuntimeError(
                    f"{label}: non-positive duration for '{tt}' at row {i} "
                    f"({spec['duration_col']}={duration})"
                )
            rows.append(dict(base, onset=float(onset), duration=float(duration), trial_type=tt))
            emitted += 1

        if is_miss:
            miss_onset = t[OL_MISS_ONSET_COL]
            if pd.isna(miss_onset):
                raise RuntimeError(
                    f"{label}: missing {OL_MISS_ONSET_COL} on missed trial row {i} "
                    f"(trialNb={base['trialNb']})"
                )
            if any(pd.isna(t[c]) for c in OL_MISS_DUR_COLS):
                raise RuntimeError(
                    f"{label}: missing duration component for 'miss' at row {i} "
                    f"(trialNb={base['trialNb']})"
                )
            miss_dur = sum(float(t[c]) for c in OL_MISS_DUR_COLS)
            if miss_dur <= 0:
                raise RuntimeError(
                    f"{label}: non-positive 'miss' duration at row {i} "
                    f"(trialNb={base['trialNb']})"
                )
            rows.append(dict(base, onset=float(miss_onset), duration=miss_dur, trial_type="miss"))
            emitted += 1

        if emitted == 0:
            raise RuntimeError(
                f"{label}: no valid events emitted for row {i} "
                f"(trialNb={base['trialNb']}, trType={base['trType']})"
            )

    if not rows:
        raise RuntimeError(f"{label}: no event rows were produced")

    out = pd.DataFrame(rows).sort_values("onset", kind="mergesort").reset_index(drop=True)
    return finalize_events_df(out, label)


def run_ol():
    if not OL_DICT.exists():
        raise RuntimeError(f"OL data dictionary not found at {OL_DICT}")

    carry_cols, event_specs, pivot_cols = load_ol_dictionary(OL_DICT)

    print("[OL] Pivot columns (excluded from TSV): " + ", ".join(pivot_cols))
    print("[OL] Carry-through columns:             " + ", ".join(carry_cols))
    print("[OL] Event specs:")
    for s in event_specs:
        print(f"       {s['onset_col']} + {s['duration_col']} -> {s['trial_type']}")

    subjects = discover_subjects_from_behav_root()
    if not subjects:
        raise RuntimeError(f"No subjects found under {BEHAV_ROOT}")

    for subj in subjects:
        if not (BEHAV_ROOT / f"SLB_{subj}").exists():
            continue
        for cond, run_dir, task, run_label in OL_TASK_RUNS:
            try:
                csv_path = find_csv(subj, cond, run_dir)
            except RuntimeError as e:
                print("[SKIP]", e)
                continue

            df     = pd.read_csv(csv_path)
            label  = f"sub-{subj} task-{task} run-{run_label} ({csv_path.name})"
            events = build_ol_events(df, carry_cols.copy(), event_specs, label)

            tsv = out_path(OL_BIDS_ROOT, subj, task, run_label)
            tsv.parent.mkdir(parents=True, exist_ok=True)
            events.to_csv(tsv, sep="\t", index=False, float_format="%.3f")
            print("OK:", tsv)


# ==============================================================================
# SRA (Social Risk Aversion)
# ==============================================================================

# Missed-trial constants – self block
SRA_SELF_MISS_SUPPRESSED = {"self_choice_validation"}
SRA_SELF_MISS_ONSET_COL  = "scannerTimer_self_confirm_Start"
SRA_SELF_MISS_DUR_COLS   = ["selfConfirmationDur"]

# Missed-trial constants – social block, infoseek miss
SRA_INFOSEEK_MISS_SUPPRESSED = {
    "social_infoseek_validation",
    "social_fixation1",
    "social_info",
}
SRA_INFOSEEK_MISS_ONSET_COL = "scannerTimer_social_infoseek_confirm_Start"
SRA_INFOSEEK_MISS_DUR_COLS  = [
    "socialInfoConfirmDur",
    "socialJitter1Dur",
    "socialInfoDisplayDur",
]

# Missed-trial constants – social block, choice miss
SRA_SOCIAL_CHOICE_MISS_SUPPRESSED = {"social_choice_validation"}
SRA_SOCIAL_CHOICE_MISS_ONSET_COL  = "scannerTimer_social_choice_confirm_Start"
SRA_SOCIAL_CHOICE_MISS_DUR_COLS   = ["socialChoiceConfirmDur"]


def _sra_clean_rt_columns(df):
    for col in ["self_RT", "social_choice_RT"]:
        if col not in df.columns:
            continue
        def _extract(x):
            if pd.isna(x):
                return x
            s = str(x).strip().replace("[", "").replace("]", "")
            s = s.split(",")[0] if "," in s else s
            try:
                return float(s)
            except Exception:
                return pd.NA
        df[col] = df[col].apply(_extract)
    return df


def load_sra_dictionary(data_dict_path):
    """
    Returns:
      carry_specs : list[dict]  – {col, block_scope}
      event_specs : list[dict]  – {onset_col, duration_col, trial_type}
    """
    dd = pd.read_csv(data_dict_path)
    for c in ["Variable", "Keep in .tsv file", "trial_type label in .tsv file"]:
        if c not in dd.columns:
            raise RuntimeError(f"SRA dictionary missing required column: {c}")

    block_col = next(
        (c for c in dd.columns if str(c).strip().lower() == "in block (self/social)"),
        None,
    )

    keep = dd["Keep in .tsv file"].astype(str).str.strip()

    carry_specs = []
    for _, row in dd.loc[keep == "Separate column", :].iterrows():
        carry_specs.append({
            "col":         str(row["Variable"]).strip(),
            "block_scope": str(row[block_col]).strip() if block_col else "",
        })

    onset_rows = dd.loc[keep == "Pivot to onset",    :].copy()
    dur_rows   = dd.loc[keep == "Pivot to duration", :].copy()

    if len(onset_rows) == 0:
        raise RuntimeError("No 'Pivot to onset' rows found in SRA dictionary")
    if len(dur_rows) == 0:
        raise RuntimeError("No 'Pivot to duration' rows found in SRA dictionary")

    dur_map = {}
    for _, row in dur_rows.iterrows():
        tt  = str(row["trial_type label in .tsv file"]).strip()
        col = str(row["Variable"]).strip()
        dur_map.setdefault(tt, []).append(col)

    event_specs   = []
    dur_use_count = {}
    for _, row in onset_rows.iterrows():
        onset_col  = str(row["Variable"]).strip()
        trial_type = str(row["trial_type label in .tsv file"]).strip()
        if not trial_type or trial_type.lower() == "nan":
            raise RuntimeError(f"SRA onset column {onset_col} has no trial_type label")
        candidates = dur_map.get(trial_type, [])
        if not candidates:
            raise RuntimeError(
                f"No duration row for trial_type '{trial_type}' (onset: {onset_col})"
            )
        idx = dur_use_count.get(trial_type, 0)
        if idx >= len(candidates):
            raise RuntimeError(f"More onset rows than duration rows for '{trial_type}'")
        event_specs.append({
            "onset_col":    onset_col,
            "duration_col": candidates[idx],
            "trial_type":   trial_type,
        })
        dur_use_count[trial_type] = idx + 1

    return carry_specs, event_specs


def _sra_label_allowed(trial_type, block):
    if trial_type.startswith("self_"):
        return block == "self"
    if trial_type.startswith("social_"):
        return block == "social"
    return True


def _sra_col_allowed(block_scope, block):
    s = str(block_scope).strip().lower()
    if s in {"", "both", "self/social", "all", "nan"}:
        return True
    if s == "self":
        return block == "self"
    if s == "social":
        return block == "social"
    if "self" in s and "social" in s:
        return True
    if "self" in s:
        return block == "self"
    if "social" in s:
        return block == "social"
    return True


def build_sra_events(df, carry_specs, event_specs, block, label):
    block_specs = [s for s in event_specs if _sra_label_allowed(s["trial_type"], block)]
    if not block_specs:
        raise RuntimeError(f"{label}: no event specs found for block={block}")

    responded_cols = (
        ["self_responded"] if block == "self"
        else ["social_infoseek_responded", "social_choice_responded"]
    )

    needed_cols = sorted(set(
        [s["onset_col"] for s in block_specs] +
        [s["duration_col"] for s in block_specs] +
        responded_cols +
        ([SRA_SELF_MISS_ONSET_COL] + SRA_SELF_MISS_DUR_COLS if block == "self"
         else [SRA_INFOSEEK_MISS_ONSET_COL] + SRA_INFOSEEK_MISS_DUR_COLS +
              [SRA_SOCIAL_CHOICE_MISS_ONSET_COL] + SRA_SOCIAL_CHOICE_MISS_DUR_COLS)
    ))
    df = coerce_numeric(df, needed_cols, label)

    onset_cols        = [s["onset_col"] for s in block_specs]
    present_onset     = [c for c in onset_cols if c in df.columns]
    if not present_onset:
        raise RuntimeError(f"{label}: none of the expected onset columns found: {onset_cols}")

    trial_mask = df[present_onset].notna().any(axis=1)
    trials     = df.loc[trial_mask, :].copy()

    if len(trials) == 0:
        raise RuntimeError(f"{label}: found 0 trials (no non-null onset rows)")

    for col in responded_cols:
        bad = trials.loc[~trials[col].isin([0, 1]), [col]].head(10)
        if len(bad) > 0:
            raise RuntimeError(f"{label}: unexpected values in '{col}':\n{bad}")

    trials["_sort"] = trials[present_onset].min(axis=1, skipna=True)
    trials = trials.sort_values("_sort", kind="mergesort").reset_index(drop=True)
    trials = trials.drop(columns=["_sort"])

    carry = [
        s["col"] for s in carry_specs
        if _sra_col_allowed(s["block_scope"], block) and s["col"] in trials.columns
    ]

    rows = []
    for i in range(len(trials)):
        t    = trials.iloc[i]
        base = {c: t[c] for c in carry}

        if block == "self":
            is_self_miss          = int(t["self_responded"]) == 0
            is_infoseek_miss      = False
            is_social_choice_miss = False
        else:
            is_self_miss          = False
            is_infoseek_miss      = int(t["social_infoseek_responded"]) == 0
            is_social_choice_miss = int(t["social_choice_responded"]) == 0

        suppressed = set()
        if is_self_miss:
            suppressed |= SRA_SELF_MISS_SUPPRESSED
        if is_infoseek_miss:
            suppressed |= SRA_INFOSEEK_MISS_SUPPRESSED
        if is_social_choice_miss:
            suppressed |= SRA_SOCIAL_CHOICE_MISS_SUPPRESSED

        emitted = 0

        for spec in block_specs:
            tt = spec["trial_type"]
            if tt in suppressed:
                continue
            onset    = t[spec["onset_col"]]
            duration = t[spec["duration_col"]]
            if pd.isna(onset) or pd.isna(duration):
                continue
            if duration <= 0:
                raise RuntimeError(
                    f"{label}: non-positive duration for '{tt}' at row {i} "
                    f"({spec['duration_col']}={duration})"
                )
            rows.append(dict(base, onset=float(onset), duration=float(duration), trial_type=tt))
            emitted += 1

        def _emit_miss(miss_onset_col, miss_dur_cols, miss_tt):
            nonlocal emitted
            mo = t[miss_onset_col]
            if pd.isna(mo):
                raise RuntimeError(f"{label}: missing {miss_onset_col} on {miss_tt} row {i}")
            if any(pd.isna(t[c]) for c in miss_dur_cols):
                raise RuntimeError(
                    f"{label}: missing duration component for '{miss_tt}' at row {i}"
                )
            rows.append(dict(
                base,
                onset=float(mo),
                duration=float(sum(t[c] for c in miss_dur_cols)),
                trial_type=miss_tt,
            ))
            emitted += 1

        if is_self_miss:
            _emit_miss(SRA_SELF_MISS_ONSET_COL, SRA_SELF_MISS_DUR_COLS, "self_missed")
        if is_infoseek_miss:
            _emit_miss(SRA_INFOSEEK_MISS_ONSET_COL, SRA_INFOSEEK_MISS_DUR_COLS,
                       "social_infoseek_missed")
        if is_social_choice_miss:
            _emit_miss(SRA_SOCIAL_CHOICE_MISS_ONSET_COL, SRA_SOCIAL_CHOICE_MISS_DUR_COLS,
                       "social_choice_missed")

        if emitted == 0:
            raise RuntimeError(f"{label}: no valid events emitted for row {i} (block={block})")

    if not rows:
        raise RuntimeError(f"{label}: no event rows were produced")

    out = pd.DataFrame(rows).sort_values("onset", kind="mergesort").reset_index(drop=True)
    return finalize_events_df(out, label)


def run_sra():
    if not SRA_DICT.exists():
        raise RuntimeError(f"SRA data dictionary not found at {SRA_DICT}")

    carry_specs, event_specs = load_sra_dictionary(SRA_DICT)

    print("[SRA] Preserved columns: " + ", ".join(s["col"] for s in carry_specs))
    print("[SRA] Event specs:")
    for s in event_specs:
        print(f"       {s['onset_col']} + {s['duration_col']} -> {s['trial_type']}")

    subjects = discover_subjects_from_behav_root()
    if not subjects:
        raise RuntimeError(f"No subjects found under {BEHAV_ROOT}")

    for subj in subjects:
        if not (BEHAV_ROOT / f"SLB_{subj}").exists():
            continue
        for cond, run_dir, task, run_label, block in SRA_TASK_RUNS:
            try:
                csv_path = find_csv(subj, cond, run_dir)
            except RuntimeError as e:
                print("[SKIP]", e)
                continue

            df = pd.read_csv(csv_path)
            df.columns = df.columns.astype(str).str.strip()
            df = _sra_clean_rt_columns(df)
            label  = f"sub-{subj} task-{task} block-{block} ({csv_path.name})"
            events = build_sra_events(df, carry_specs.copy(), event_specs, block, label)

            tsv = out_path(SRA_BIDS_ROOT, subj, task, run_label)
            tsv.parent.mkdir(parents=True, exist_ok=True)
            events.to_csv(tsv, sep="\t", index=False, float_format="%.3f")
            print("OK:", tsv)


# ==============================================================================
# Trust (TM / TH)
# ==============================================================================

TR_COL_COND   = "scannerTimer_condition_Start"
TR_COL_FIX    = "scannerTimer_fixation1_Start"
TR_COL_CHOICE = "scannerTimer_choice_Start"
TR_COL_WAIT   = "scannerTimer_wait_Start"
TR_COL_FB     = "scannerTimer_feedback_Start"
TR_COL_END    = "scannerTimer_trial_End"

TR_TIMING_COLS = [TR_COL_COND, TR_COL_FIX, TR_COL_CHOICE, TR_COL_WAIT, TR_COL_FB, TR_COL_END]

TR_RESPONDED     = "responded"
TR_PARTNER_TRIAL = "partnerTrialNumber"


def load_trust_separate_cols(data_dict_path):
    dd   = pd.read_csv(data_dict_path)
    mask = dd["Keep in .tsv file"].astype(str).str.strip() == "Separate column"
    return [str(x) for x in dd.loc[mask, "Variable"].tolist()]


def build_trust_events(df, separate_cols, label):
    if TR_COL_FIX not in df.columns:
        raise RuntimeError(f"{label}: missing column {TR_COL_FIX}")

    trials = df.loc[~df[TR_COL_FIX].isna(), :].copy()
    if len(trials) == 0:
        raise RuntimeError(f"{label}: found 0 trials (no non-null rows in {TR_COL_FIX})")

    trials = coerce_numeric(trials, TR_TIMING_COLS, label)

    missing_mask = trials[TR_TIMING_COLS].isna().any(axis=1)
    if missing_mask.any():
        bad_idx = missing_mask[missing_mask].index.tolist()[:10]
        raise RuntimeError(
            f"{label}: missing timestamp(s) at row indices {bad_idx}.\n"
            f"{trials.loc[bad_idx, TR_TIMING_COLS]}"
        )

    for col in [TR_RESPONDED, TR_PARTNER_TRIAL]:
        if col not in trials.columns:
            raise RuntimeError(f"{label}: missing required column {col}")
    trials[TR_RESPONDED]     = pd.to_numeric(trials[TR_RESPONDED],     errors="coerce")
    trials[TR_PARTNER_TRIAL] = pd.to_numeric(trials[TR_PARTNER_TRIAL], errors="coerce")

    bad_responded = trials[~trials[TR_RESPONDED].isin([0, 1])]
    if len(bad_responded) > 0:
        raise RuntimeError(
            f"{label}: unexpected values in '{TR_RESPONDED}':\n"
            f"{bad_responded[[TR_PARTNER_TRIAL, TR_RESPONDED]].head(10)}"
        )

    trials = trials.sort_values(TR_COL_FIX, kind="mergesort").reset_index(drop=True)

    dur_new_partner = trials[TR_COL_FIX]    - trials[TR_COL_COND]
    dur_fix         = trials[TR_COL_CHOICE] - trials[TR_COL_FIX]
    dur_choice      = trials[TR_COL_WAIT]   - trials[TR_COL_CHOICE]
    dur_wait        = trials[TR_COL_FB]     - trials[TR_COL_WAIT]
    dur_fb          = trials[TR_COL_END]    - trials[TR_COL_FB]

    intro_mask = trials[TR_PARTNER_TRIAL] == 1
    for name, dur, mask in [
        ("fixation",    dur_fix,         None),
        ("choice",      dur_choice,      None),
        ("wait",        dur_wait,        None),
        ("feedback",    dur_fb,          None),
        ("new_partner", dur_new_partner, intro_mask),
    ]:
        check = dur if mask is None else dur[mask]
        if (check <= 0).any():
            bad = check[check <= 0].index.tolist()[:10]
            raise RuntimeError(
                f"{label}: non-positive {name} duration(s) at trial indices: {bad}"
            )

    carry = [c for c in separate_cols if c in trials.columns]

    rows = []
    for i in range(len(trials)):
        t         = trials.iloc[i]
        base      = {c: t[c] for c in carry}
        responded = int(t[TR_RESPONDED])

        if t[TR_PARTNER_TRIAL] == 1:
            rows.append(dict(base,
                onset=float(t[TR_COL_COND]),
                duration=float(dur_new_partner.iloc[i]),
                trial_type="new_partner",
            ))

        rows.append(dict(base,
            onset=float(t[TR_COL_FIX]),
            duration=float(dur_fix.iloc[i]),
            trial_type="fixation",
        ))
        rows.append(dict(base,
            onset=float(t[TR_COL_CHOICE]),
            duration=float(dur_choice.iloc[i]),
            trial_type="choice_success" if responded == 1 else "choice_miss",
        ))
        rows.append(dict(base,
            onset=float(t[TR_COL_WAIT]),
            duration=float(dur_wait.iloc[i]),
            trial_type="wait_success" if responded == 1 else "wait_miss",
        ))
        rows.append(dict(base,
            onset=float(t[TR_COL_FB]),
            duration=float(dur_fb.iloc[i]),
            trial_type="feedback",
        ))

    out = pd.DataFrame(rows).sort_values("onset", kind="mergesort").reset_index(drop=True)
    out = finalize_events_df(out, label)

    n_intros      = int(intro_mask.sum())
    expected_rows = len(trials) * 4 + n_intros
    if len(out) != expected_rows:
        raise RuntimeError(
            f"{label}: row count mismatch (expected {expected_rows} = "
            f"{len(trials)} trials x 4 + {n_intros} new_partner rows, got {len(out)})"
        )

    return out


def run_trust():
    if not TRUST_DICT.exists():
        raise RuntimeError(f"Trust data dictionary not found at {TRUST_DICT}")

    separate_cols = load_trust_separate_cols(TRUST_DICT)

    subjects = discover_subjects_from_behav_root()
    if not subjects:
        raise RuntimeError(f"No subjects found under {BEHAV_ROOT}")

    for subj in subjects:
        if not (BEHAV_ROOT / f"SLB_{subj}").exists():
            continue
        for cond, run_dir, task, run_label in TRUST_TASK_RUNS:
            try:
                csv_path = find_csv(subj, cond, run_dir)
            except RuntimeError as e:
                print("[SKIP]", e)
                continue

            df     = pd.read_csv(csv_path)
            label  = f"sub-{subj} task-{task} run-{run_label} ({csv_path.name})"
            events = build_trust_events(df, separate_cols, label)

            tsv = out_path(TRUST_BIDS_ROOT, subj, task, run_label)
            tsv.parent.mkdir(parents=True, exist_ok=True)
            events.to_csv(tsv, sep="\t", index=False, float_format="%.3f")
            print("OK:", tsv)


# ==============================================================================
# Entry point
# ==============================================================================

def main():
    task_arg = sys.argv[1].lower() if len(sys.argv) > 1 else "all"

    runners = {
        "ol":    run_ol,
        "sra":   run_sra,
        "trust": run_trust,
    }

    if task_arg == "all":
        for name, fn in runners.items():
            print(f"\n{'='*60}")
            print(f"  Running: {name.upper()}")
            print(f"{'='*60}")
            fn()
    elif task_arg in runners:
        runners[task_arg]()
    else:
        print(f"Unknown task '{task_arg}'. Valid options: ol, sra, trust, all")
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
#!/usr/bin/env bash
set -euo pipefail

# =========================
# Config
# =========================
SLB_ROOT="${SLB_ROOT:-/data/sld/homes/collab/slb}"
BIDS_DIR="${BIDS_DIR:-$SLB_ROOT/bids_runs}"

# Parallel outputs (DO NOT overwrite your main pipeline)
DERIV_DIR="${DERIV_DIR:-$SLB_ROOT/derivatives/fmriprep_mni6_runs}"
WORK_DIR="${WORK_DIR:-$SLB_ROOT/work/fmriprep_mni6_runs}"

LOG_DIR="${LOG_DIR:-$SLB_ROOT/logs}"
CACHE_DIR="${CACHE_DIR:-$SLB_ROOT/cache}"

# fMRIPrep container (use your existing SIF)
FMRIPREP_SIF="${FMRIPREP_SIF:-$SLB_ROOT/fmriprep_23.2.1.sif}"

# FreeSurfer license
FS_LICENSE="${FS_LICENSE:-$SLB_ROOT/license.txt}"

# Resources
NPROCS="${NPROCS:-16}"
MEM_GB="${MEM_GB:-64}"

usage () {
  cat <<EOF
Usage:
  $(basename "$0") <SUBJECT_ID>

Example:
  $(basename "$0") 000
EOF
  exit 2
}

[[ $# -eq 1 ]] || usage
SUBJ="$1"
[[ "$SUBJ" =~ ^[0-9]{3}$ ]] || { echo "ERROR: subject must be 3 digits like 000"; exit 2; }

# =========================
# Checks
# =========================
[[ -d "$BIDS_DIR/sub-$SUBJ" ]] || { echo "ERROR: Missing $BIDS_DIR/sub-$SUBJ"; exit 1; }
[[ -f "$FMRIPREP_SIF" ]] || { echo "ERROR: Missing fMRIPrep SIF: $FMRIPREP_SIF"; exit 1; }
[[ -f "$FS_LICENSE" ]] || { echo "ERROR: Missing FreeSurfer license: $FS_LICENSE"; exit 1; }

mkdir -p "$DERIV_DIR" "$WORK_DIR" "$LOG_DIR"
mkdir -p "$CACHE_DIR/templateflow" "$CACHE_DIR/matplotlib"

STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$LOG_DIR/fmriprep_mni6_runs_sub-${SUBJ}_${STAMP}.log"

echo "[INFO] Subject: sub-$SUBJ" | tee -a "$LOG"
echo "[INFO] BIDS:    $BIDS_DIR" | tee -a "$LOG"
echo "[INFO] OUT:     $DERIV_DIR" | tee -a "$LOG"
echo "[INFO] WORK:    $WORK_DIR" | tee -a "$LOG"

# =========================
# Container env to avoid /afs writes
# =========================
export APPTAINERENV_TEMPLATEFLOW_HOME="/data/cache/templateflow"
export APPTAINERENV_XDG_CACHE_HOME="/data/cache"
export APPTAINERENV_MPLCONFIGDIR="/data/cache/matplotlib"

# Optional but often helpful:
# export APPTAINERENV_FS_LICENSE="/data/license.txt"

# =========================
# Run fMRIPrep
# =========================
apptainer run --cleanenv --no-home \
  -B "$SLB_ROOT:/data" \
  "$FMRIPREP_SIF" \
  /data/bids_runs /data/derivatives/fmriprep_mni6_runs participant \
  -w /data/work/fmriprep_mni6_runs \
  --participant-label "$SUBJ" \
  --fs-license-file /data/license.txt \
  --output-spaces MNI152NLin6Asym:res-2 \
  --nprocs "$NPROCS" \
  --mem-mb "$((MEM_GB*1024))" \
  --skip-bids-validation \
  2>&1 | tee -a "$LOG"

echo "[DONE] fMRIPrep MNI6 run complete for sub-$SUBJ" | tee -a "$LOG"

#!/usr/bin/env bash
set -euo pipefail

# =========================
# Config
# =========================
SLB_ROOT="${SLB_ROOT:-/data/sld/homes/collab/slb}"

# Input must be the *fMRIPrep MNI6* derivatives you produced above
FMRIPREP_MNI6_DIR_RUNS="${FMRIPREP_MNI6_DIR_RUNS:-$SLB_ROOT/derivatives/fmriprep_mni6_runs}"

# Output (new!)
OUT_DIR="${OUT_DIR:-$SLB_ROOT/derivatives/fmripost_aroma_runs}"
WORK_DIR="${WORK_DIR:-$SLB_ROOT/work/fmripost_aroma_runs}"

LOG_DIR="${LOG_DIR:-$SLB_ROOT/logs}"
CACHE_DIR="${CACHE_DIR:-$SLB_ROOT/cache}"

# fMRIPost-AROMA container (you will need to pull it once)
# Pick a version your lab wants; example:
POSTAROMA_VERSION="${POSTAROMA_VERSION:-main}"  # replace once you choose
SIF="${SIF:-$SLB_ROOT/fmripost_aroma_${POSTAROMA_VERSION}.sif}"
IMG_URI="${IMG_URI:-docker://nipreps/fmripost-aroma:${POSTAROMA_VERSION}}"

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
[[ -d "$FMRIPREP_MNI6_DIR_RUNS/sub-$SUBJ" ]] || { echo "ERROR: Missing $FMRIPREP_MNI6_DIR_RUNS/sub-$SUBJ"; exit 1; }

mkdir -p "$OUT_DIR" "$WORK_DIR" "$LOG_DIR"
mkdir -p "$CACHE_DIR/templateflow" "$CACHE_DIR/matplotlib"

STAMP="$(date +%Y%m%d-%H%M%S)"
LOG="$LOG_DIR/fmripost_aroma_runs_sub-${SUBJ}_${STAMP}.log"

echo "[INFO] Subject: sub-$SUBJ" | tee -a "$LOG"
echo "[INFO] fMRIPrep input: $FMRIPREP_MNI6_DIR_RUNS" | tee -a "$LOG"
echo "[INFO] OUT: $OUT_DIR" | tee -a "$LOG"
echo "[INFO] WORK: $WORK_DIR" | tee -a "$LOG"

# =========================
# Pull container if missing
# =========================
if [[ ! -f "$SIF" ]]; then
  echo "[INFO] Pulling fMRIPost-AROMA image -> $SIF" | tee -a "$LOG"
  apptainer pull "$SIF" "$IMG_URI" 2>&1 | tee -a "$LOG"
fi

# =========================
# Avoid /afs writes inside container
# =========================
export APPTAINERENV_TEMPLATEFLOW_HOME="/data/cache/templateflow"
export APPTAINERENV_XDG_CACHE_HOME="/data/cache"
export APPTAINERENV_MPLCONFIGDIR="/data/cache/matplotlib"

# =========================
# Run fMRIPost-AROMA
# =========================
# NOTE: CLI args may vary slightly by version. If this errors on syntax,
# paste the help output: apptainer run ... --help
apptainer run --cleanenv --no-home \
  -B "$SLB_ROOT:/data" \
  "$SIF" \
  /data/derivatives/fmriprep_mni6_runs /data/derivatives/fmripost_aroma_runs participant \
  --participant-label "$SUBJ" \
  -w /data/work/fmripost_aroma \
  2>&1 | tee -a "$LOG"

echo "[DONE] fMRIPost-AROMA complete for sub-$SUBJ" | tee -a "$LOG"

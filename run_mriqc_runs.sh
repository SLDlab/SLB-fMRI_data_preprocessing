#!/usr/bin/env bash
# scripts/run_mriqc.sh
# Run MRIQC (participant + optional group) on SLD using Apptainer.
#
# Examples:
#   ./scripts/run_mriqc.sh 000
#   ./scripts/run_mriqc.sh 000 001 002 003
#   ./scripts/run_mriqc.sh --range 000 003
#   ./scripts/run_mriqc.sh --all
#   ./scripts/run_mriqc.sh --range 000 003 --group
#
# Notes:
# - Expects BIDS subjects as sub-<ID> under $BIDS_DIR (e.g., sub-000)
# - Writes outputs to $OUT_DIR and work files to $WORK_DIR
# - Does NOT modify BIDS input dataset

set -euo pipefail

# -----------------------
# Config (edit if needed)
# -----------------------
SLB_ROOT="${SLB_ROOT:-/data/sld/homes/collab/slb}"
BIDS_DIR="${BIDS_DIR:-$SLB_ROOT/bids_runs}"
DERIV_DIR="${DERIV_DIR:-$SLB_ROOT/derivatives}"
OUT_DIR="${OUT_DIR:-$DERIV_DIR/mriqc_runs}"
WORK_DIR="${WORK_DIR:-$SLB_ROOT/work/mriqc_runs}"
CACHE_DIR="${CACHE_DIR:-$SLB_ROOT/cache}"
LOG_DIR="${LOG_DIR:-$SLB_ROOT/logs}"

# Container image
MRIQC_VERSION="${MRIQC_VERSION:-23.0.1}"
SIF="${SIF:-$SLB_ROOT/mriqc_${MRIQC_VERSION}.sif}"
IMG_URI="${IMG_URI:-docker://nipreps/mriqc:${MRIQC_VERSION}}"

# Behavior
NPROCS="${NPROCS:-16}"
MEM_GB="${MEM_GB:-64}"
NO_SUB=1
RUN_GROUP=0
DRYRUN=0

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [options] <SUBJECT_ID ...>

Options:
  --range <START> <END>   Run inclusive numeric range, e.g. --range 000 003
  --all                   Run all subjects found in BIDS_DIR (sub-*)
  --group                 After participant runs, run MRIQC group
  -n, --dry-run            Print commands only
  --nprocs <N>            Override CPU count (default: $NPROCS)
  --mem-gb <GB>           Override memory limit (default: $MEM_GB)
  -h, --help              Show help

Examples:
  ./scripts/run_mriqc_runs.sh 000
  ./scripts/run_mriqc_runs.sh 000 001 002 003
  ./scripts/run_mriqc_runs.sh --range 000 003
  ./scripts/run_mriqc_runs.sh --all --group
EOF
}

# -----------------------
# Parse args
# -----------------------
SUBJECTS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --range)
      [[ $# -ge 3 ]] || { echo "ERROR: --range needs START END"; exit 2; }
      START="$2"; END="$3"
      shift 3
      s=$((10#$START))
      e=$((10#$END))
      if (( s > e )); then
        echo "ERROR: range start > end"
        exit 2
      fi
      for i in $(seq "$s" "$e"); do
        printf -v id "%03d" "$i"
        SUBJECTS+=("$id")
      done
      ;;
    --all)
      shift
      mapfile -t found < <(find "$BIDS_DIR" -maxdepth 1 -type d -name 'sub-*' -printf '%f\n' | sed 's/^sub-//' | sort)
      SUBJECTS+=("${found[@]}")
      ;;
    --group)
      RUN_GROUP=1
      shift
      ;;
    -n|--dry-run)
      DRYRUN=1
      shift
      ;;
    --nprocs)
      NPROCS="$2"; shift 2
      ;;
    --mem-gb)
      MEM_GB="$2"; shift 2
      ;;
    -h|--help)
      usage; exit 0
      ;;
    -*)
      echo "ERROR: Unknown option: $1"
      usage
      exit 2
      ;;
    *)
      SUBJECTS+=("$1")
      shift
      ;;
  esac
done

if [[ ${#SUBJECTS[@]} -eq 0 ]]; then
  echo "ERROR: No subjects provided."
  usage
  exit 2
fi

# De-dup while preserving order
dedup_subjects=()
seen=""
for s in "${SUBJECTS[@]}"; do
  if [[ " $seen " != *" $s "* ]]; then
    dedup_subjects+=("$s")
    seen+=" $s"
  fi
done
SUBJECTS=("${dedup_subjects[@]}")

# Validate BIDS presence
missing=0
for s in "${SUBJECTS[@]}"; do
  if [[ ! -d "$BIDS_DIR/sub-$s" ]]; then
    echo "WARN: Missing BIDS subject folder: $BIDS_DIR/sub-$s"
    missing=1
  fi
done
if [[ $missing -eq 1 ]]; then
  echo "ERROR: One or more subjects missing in BIDS_DIR. Fix BIDSify first."
  exit 1
fi

mkdir -p "$OUT_DIR" "$WORK_DIR" "$LOG_DIR"
mkdir -p "$CACHE_DIR/templateflow" "$CACHE_DIR/mriqc" "$CACHE_DIR/matplotlib"

STAMP="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="$LOG_DIR/mriqc_${STAMP}.log"

echo "============================================================" | tee -a "$LOG_FILE"
echo "[INFO] MRIQC $MRIQC_VERSION" | tee -a "$LOG_FILE"
echo "BIDS_DIR  = $BIDS_DIR" | tee -a "$LOG_FILE"
echo "OUT_DIR   = $OUT_DIR" | tee -a "$LOG_FILE"
echo "WORK_DIR  = $WORK_DIR" | tee -a "$LOG_FILE"
echo "CACHE_DIR = $CACHE_DIR" | tee -a "$LOG_FILE"
echo "NPROCS    = $NPROCS" | tee -a "$LOG_FILE"
echo "MEM_GB    = $MEM_GB" | tee -a "$LOG_FILE"
echo "SUBJECTS  = ${SUBJECTS[*]}" | tee -a "$LOG_FILE"
echo "GROUP     = $RUN_GROUP" | tee -a "$LOG_FILE"
echo "DRYRUN    = $DRYRUN" | tee -a "$LOG_FILE"
echo "============================================================" | tee -a "$LOG_FILE"

# Pull container if missing
if [[ ! -f "$SIF" ]]; then
  echo "[INFO] Pulling MRIQC image -> $SIF" | tee -a "$LOG_FILE"
  if [[ $DRYRUN -eq 1 ]]; then
    echo "apptainer pull \"$SIF\" \"$IMG_URI\"" | tee -a "$LOG_FILE"
  else
    apptainer pull "$SIF" "$IMG_URI" 2>&1 | tee -a "$LOG_FILE"
  fi
fi

# --------- IMPORTANT: cache env INSIDE container ----------
export APPTAINERENV_XDG_CACHE_HOME="/cache"
export APPTAINERENV_TEMPLATEFLOW_HOME="/cache/templateflow"
export APPTAINERENV_MPLCONFIGDIR="/cache/matplotlib"
# ---------------------------------------------------------

# Bind dirs into container at stable mount points
APPTAINER_BASE=(
  apptainer run --cleanenv --no-home
  -B "$BIDS_DIR:/bids"
  -B "$OUT_DIR:/out"
  -B "$WORK_DIR:/work"
  -B "$CACHE_DIR:/cache"
  "$SIF"
)

# MRIQC participant args
MRIQC_PART=( /bids /out participant
  --participant-label "${SUBJECTS[@]}"
  --work-dir /work
  --nprocs "$NPROCS"
  --mem_gb "$MEM_GB"
)
if [[ $NO_SUB -eq 1 ]]; then
  MRIQC_PART+=( --no-sub )
fi

echo "[INFO] Running MRIQC (participant)..." | tee -a "$LOG_FILE"
if [[ $DRYRUN -eq 1 ]]; then
  printf '%q ' "${APPTAINER_BASE[@]}" "${MRIQC_PART[@]}" | tee -a "$LOG_FILE"
  echo | tee -a "$LOG_FILE"
else
  "${APPTAINER_BASE[@]}" "${MRIQC_PART[@]}" 2>&1 | tee -a "$LOG_FILE"
fi

# Optional group run
if [[ $RUN_GROUP -eq 1 ]]; then
  MRIQC_GROUP=( /bids /out group )
  if [[ $NO_SUB -eq 1 ]]; then
    MRIQC_GROUP+=( --no-sub )
  fi

  echo "[INFO] Running MRIQC (group)..." | tee -a "$LOG_FILE"
  if [[ $DRYRUN -eq 1 ]]; then
    printf '%q ' "${APPTAINER_BASE[@]}" "${MRIQC_GROUP[@]}" | tee -a "$LOG_FILE"
    echo | tee -a "$LOG_FILE"
  else
    "${APPTAINER_BASE[@]}" "${MRIQC_GROUP[@]}" 2>&1 | tee -a "$LOG_FILE"
  fi
fi

echo "[DONE] MRIQC complete." | tee -a "$LOG_FILE"
echo "[DONE] Reports live in: $OUT_DIR" | tee -a "$LOG_FILE"
echo "[DONE] Log file: $LOG_FILE" | tee -a "$LOG_FILE"


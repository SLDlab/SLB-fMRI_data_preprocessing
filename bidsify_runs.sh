#!/usr/bin/env bash
set -euo pipefail

SLB_ROOT="/data/sld/homes/collab/slb"
RAW_DIR="$SLB_ROOT/raw_data"
BIDS_DIR="$SLB_ROOT/bids_runs"
HEUR="$SLB_ROOT/scripts/heuristic_runs.py"

HDC_IMG="docker://nipy/heudiconv:1.3.3"
SIF="$SLB_ROOT/heudiconv_1.3.3.sif"

mkdir -p "$BIDS_DIR"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [SUBJECT_ID] [--force]

Examples:
  $(basename "$0")              # process all new subjects (skip existing)
  $(basename "$0") 011          # only subject 011
  $(basename "$0") 011 --force  # redo subject 011 and reset .heudiconv state
  $(basename "$0") --force      # redo all subjects and reset .heudiconv state
EOF
  exit 1
}

FORCE=0
SUBJECT=""

# ---------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE=1
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      if [[ -z "$SUBJECT" ]]; then
        SUBJECT="$1"
        shift
      else
        echo "Unknown extra argument: $1"
        usage
      fi
      ;;
  esac
done

# ---------------------------------------------------------
# Pull HeuDiConv container if needed
# ---------------------------------------------------------
if [[ ! -f "$SIF" ]]; then
  echo "Pulling HeuDiConv image ($HDC_IMG) ..."
  apptainer pull "$SIF" "$HDC_IMG"
fi

echo "RAW_DIR   = $RAW_DIR"
echo "BIDS_DIR  = $BIDS_DIR"
echo "HEUR      = $HEUR"
echo "FORCE     = $FORCE"

[[ -n "$SUBJECT" ]] && echo "SUBJECT   = $SUBJECT"

if [[ ! -f "$HEUR" ]]; then
  echo "ERROR: heuristic not found: $HEUR"
  exit 2
fi

# ---------------------------------------------------------
# Find candidate subject folders
# ---------------------------------------------------------
mapfile -t SUB_DIRS < <(
  find "$RAW_DIR" \
    -maxdepth 1 \
    -mindepth 1 \
    -type d \
    \( \
      -name 'SLB_[0-9][0-9][0-9]' \
      -o -name 'SLB[0-9][0-9][0-9]' \
      -o -name '[0-9][0-9][0-9]' \
    \) \
    -printf '%f\n' \
    | sort
)

if [[ ${#SUB_DIRS[@]} -eq 0 ]]; then
  echo "ERROR: No subject folders found under $RAW_DIR"
  exit 1
fi

# ---------------------------------------------------------
# Optional subject filter
# ---------------------------------------------------------
if [[ -n "$SUBJECT" ]]; then

  if [[ "$SUBJECT" =~ ^[0-9]{1,3}$ ]]; then
    SUBJECT="$(printf "%03d" "$((10#$SUBJECT))")"
  else
    echo "ERROR: SUBJECT_ID must be numeric like 011"
    exit 1
  fi

  filtered=()

  for d in "${SUB_DIRS[@]}"; do
    id="$d"
    id="${id#SLB_}"
    id="${id#SLB}"

    if [[ "$id" == "$SUBJECT" ]]; then
      filtered+=("$d")
    fi
  done

  if [[ ${#filtered[@]} -eq 0 ]]; then
    echo "ERROR: Could not find raw folder for subject $SUBJECT under $RAW_DIR"
    echo "Found: ${SUB_DIRS[*]}"
    exit 1
  fi

  SUB_DIRS=("${filtered[@]}")
fi

echo "Found candidate subjects: ${SUB_DIRS[*]}"

# =========================================================
# Process subjects
# =========================================================
for subj_dir in "${SUB_DIRS[@]}"; do

  [[ "$subj_dir" =~ ^SLB_p ]] && continue

  subj_id="$subj_dir"
  subj_id="${subj_id#SLB_}"
  subj_id="${subj_id#SLB}"

  # -------------------------------------------------------
  # Skip existing BIDS subject unless forcing
  # -------------------------------------------------------
  if [[ $FORCE -eq 0 && -d "$BIDS_DIR/sub-$subj_id" ]]; then
    echo "→ Skipping sub-$subj_id (already exists: $BIDS_DIR/sub-$subj_id)"
    continue
  fi

  raw_subj="$RAW_DIR/$subj_dir"

  echo
  echo "============================================================"
  echo "→ Subject sub-$subj_id"
  echo "  Raw directory: $raw_subj"
  echo "============================================================"

  # -------------------------------------------------------
  # Reset HeuDiConv state when forcing
  # -------------------------------------------------------
  if [[ $FORCE -eq 1 ]]; then
    echo "  --force: removing cached HeuDiConv state:"
    echo "           $BIDS_DIR/.heudiconv/$subj_id"

    rm -rf "$BIDS_DIR/.heudiconv/$subj_id"
  fi

  # -------------------------------------------------------
  # Find timestamped study folders
  #
  # Folder names follow a timestamp format such as:
  #
  #   20261019-162331.600000
  #   20261021-182304.400000
  #
  # Lexical sorting therefore also sorts chronologically.
  # -------------------------------------------------------
  mapfile -t STUDIES < <(
    find "$raw_subj" \
      -maxdepth 1 \
      -mindepth 1 \
      -type d \
      -name '20*' \
      -printf '%f\n' \
      | sort
  )

  if [[ ${#STUDIES[@]} -eq 0 ]]; then
    echo "ERROR: No timestamped study folders (20*) under $raw_subj"
    exit 3
  fi

  echo "  Found studies:"

  for found_study in "${STUDIES[@]}"; do
    echo "    $found_study"
  done

  # -------------------------------------------------------
  # Select latest study
  #
  # If a scan was aborted and later repeated, the newest
  # timestamped study is treated as the authoritative scan.
  # Older study folders are ignored by BIDS conversion.
  # -------------------------------------------------------
  latest_index=$((${#STUDIES[@]} - 1))
  study="${STUDIES[$latest_index]}"

  if [[ ${#STUDIES[@]} -gt 1 ]]; then
    echo
    echo "  Multiple studies detected."
    echo "  → Selecting latest study: $study"
  else
    echo
    echo "  → Using study: $study"
  fi

  # -------------------------------------------------------
  # Count DICOMs for logging only
  #
  # The DICOM count is NOT used to decide which study is
  # valid because valid acquisitions can contain different
  # numbers of DICOM files.
  # -------------------------------------------------------
  dcm_count=$(
    find "$raw_subj/$study" \
      -type f \
      -name '*.dcm' \
      | wc -l
  )

  if [[ "$dcm_count" -eq 0 ]]; then
    echo "ERROR: No DICOM files found in selected study:"
    echo "       $raw_subj/$study"
    exit 3
  fi

  echo "  DICOM count (informational): $dcm_count"

  # -------------------------------------------------------
  # Construct HeuDiConv DICOM template
  #
  # HeuDiConv requires the literal {subject} placeholder.
  # -------------------------------------------------------
  d_template="$RAW_DIR/SLB_{subject}/$study/*/*.dcm"

  # Fallback for deeper nesting:
  # /study/series/files/*.dcm
  if ! compgen -G "${d_template/\{subject\}/$subj_id}" > /dev/null; then

    d_template="$RAW_DIR/SLB_{subject}/$study/*/*/*.dcm"

    if ! compgen -G "${d_template/\{subject\}/$subj_id}" > /dev/null; then
      echo "ERROR: No DICOM files matched expected directory structure."
      echo "       Selected study: $study"
      exit 3
    fi
  fi

  echo "  → BIDSifying sub-$subj_id from latest study:"
  echo "    $study"
  echo "    using -d: $d_template"

  # -------------------------------------------------------
  # Run HeuDiConv
  # -------------------------------------------------------
  apptainer run \
    --cleanenv \
    --no-home \
    -B "$RAW_DIR":"$RAW_DIR" \
    -B "$BIDS_DIR":"$BIDS_DIR" \
    -B "$HEUR":"$HEUR" \
    "$SIF" \
    -d "$d_template" \
    -o "$BIDS_DIR" \
    -f "$HEUR" \
    -s "$subj_id" \
    -c dcm2niix \
    -b \
    --overwrite

done

echo
echo "DONE. BIDS → $BIDS_DIR"

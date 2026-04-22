#!/usr/bin/env bash
# scripts/extract_mnc.sh
# Extract from fmri2 → SLD, preserving structure.
# Now targets SLB_### and SLB### (typo), and skips SLB_p### (incl. SLB_p000 phantom).

set -euo pipefail

# --- CONFIG (edit if needed) ---
SRC_HOST="${SRC_HOST:-gdmahaja@fmri2.umd.edu}"
REMOTE_BASE=${SRC_HOST}:'/'"export/software/fmri/massstorage/Caroline Charpentier/SLB Social Learning/"'/'

# session folders look like 20251105-093832.100000
SESSION_GLOB="${SESSION_GLOB:-20*}"

SLB_ROOT="${SLB_ROOT:-/data/sld/homes/collab/slb}"
DST_ROOT="${DST_ROOT:-$SLB_ROOT/raw_data}"
LOG_DIR="${LOG_DIR:-$SLB_ROOT/logs}"
LOCKFILE="${LOCKFILE:-$SLB_ROOT/.extract.lock}"
# --------------------------------

DRYRUN=0 ; DELETE=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [-n] [-m] [-S SESSION_GLOB]

  -n   Dry run (no changes)
  -m   Mirror deletions (adds --delete-after) [USE WITH CARE]
  -S   Session glob (default: $SESSION_GLOB), e.g. '202511*'
EOF
  exit 1
}

while getopts ":nmS:h" opt; do
  case "$opt" in
    n) DRYRUN=1 ;;
    m) DELETE=1 ;;
    S) SESSION_GLOB="$OPTARG" ;;
    h|*) usage ;;
  esac
done

mkdir -p "$DST_ROOT" "$LOG_DIR"

# simple lock
exec 9>"$LOCKFILE"
if ! flock -n 9; then
  echo "[$(date -Is)] extractor already running; exiting." | tee -a "$LOG_DIR/extract.log"
  exit 0
fi

command -v rsync >/dev/null || { echo "rsync not found" | tee -a "$LOG_DIR/extract.log"; exit 1; }

echo "[$(date -Is)] === START EXTRACT ===" | tee -a "$LOG_DIR/extract.log"
echo "REMOTE_BASE=$REMOTE_BASE" | tee -a "$LOG_DIR/extract.log"
echo "SESSION_GLOB=$SESSION_GLOB" | tee -a "$LOG_DIR/extract.log"
echo "DST_ROOT=$DST_ROOT" | tee -a "$LOG_DIR/extract.log"

# rsync flags
RSYNC_FLAGS=( -rlt --partial --append-verify --checksum --prune-empty-dirs --omit-dir-times --no-perms --no-owner --no-group --info=stats1,progress2 )
[[ $DRYRUN -eq 1 ]] && RSYNC_FLAGS+=( -n )
[[ $DELETE -eq 1 ]] && RSYNC_FLAGS+=( --delete-after )

# Build include/exclude filters:
#   Include participants matching SLB_### and SLB### (typo)
#   Include their sessions (20*) and contents
#   Exclude everything else
#   Explicitly exclude legacy SLB_p### (and phantom SLB_p000)
INCLUDES=(
  --include="*/"
  --include="SLB_[0-9][0-9][0-9]/"
  --include="SLB_[0-9][0-9][0-9]/${SESSION_GLOB}/"
  --include="SLB_[0-9][0-9][0-9]/${SESSION_GLOB}/**"
  --include="SLB[0-9][0-9][0-9]/"
  --include="SLB[0-9][0-9][0-9]/${SESSION_GLOB}/"
  --include="SLB[0-9][0-9][0-9]/${SESSION_GLOB}/**"
 # NEW: numeric-only subjects like 003/
  --include="[0-9][0-9][0-9]/"
  --include="[0-9][0-9][0-9]/${SESSION_GLOB}/"
  --include="[0-9][0-9][0-9]/${SESSION_GLOB}/**"
  --exclude="SLB_p000/**"
  --exclude="SLB_p[0-9][0-9][0-9]/**"
  --exclude="*"
)

echo "[$(date -Is)] rsync -> $DST_ROOT/" | tee -a "$LOG_DIR/extract.log"

# Use a dedicated SSH key outside AFS for cron/root
SSH_CMD="ssh -i /data/sld/homes/collab/slb/.ssh/id_ed25519 -o IdentitiesOnly=yes"

rsync -e "$SSH_CMD" "${RSYNC_FLAGS[@]}" "${INCLUDES[@]}" "$REMOTE_BASE" "$DST_ROOT/" \
  | tee -a "$LOG_DIR/extract.log" || {
    echo "[$(date -Is)] rsync failed." | tee -a "$LOG_DIR/extract.log"
    exit 1
  }
# ---- Normalize participant IDs (003 -> SLB_003) ----
for d in "$DST_ROOT"/[0-9][0-9][0-9]; do
  base=$(basename "$d")
  target="$DST_ROOT/SLB_$base"

  if [[ ! -e "$target" ]]; then
    echo "[$(date -Is)] Renaming $base -> SLB_$base (scanner ID correction)" \
      | tee -a "$LOG_DIR/extract.log"
    mv "$d" "$target"
  fi
done

echo "[$(date -Is)] === END EXTRACT ===" | tee -a "$LOG_DIR/extract.log"



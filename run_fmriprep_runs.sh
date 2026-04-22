#!/usr/bin/env bash
set -euo pipefail

# -------------------------
# Config (edit if needed)
# -------------------------
VER="23.2.1"

BIDS_DIR="/data/sld/homes/collab/slb/bids_runs"
OUT_DIR="/data/sld/homes/collab/slb/derivatives/fmriprep_runs"
WORK_BASE="/data/sld/homes/collab/slb/work/fmriprep_runs"
FS_LIC="/data/sld/homes/collab/slb/license.txt"   # <-- change if needed

# Threads & memory (override with env vars if needed)
NTHREADS="${NTHREADS:-8}"
OMP="${OMP:-4}"
MEM_MB="${MEM_MB:-32000}"

# -------------------------
# Usage
# -------------------------
if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then
  echo "Usage: ./run_fmriprep_runs.sh <SUBJECT_ID> [obslearn|risk|trust]"
  echo "Example:"
  echo "  ./run_fmriprep_runs.sh 000"
  echo "  ./run_fmriprep_runs.sh 000 obslearn"
  exit 1
fi

SUB="$1"
SUB_LABEL="sub-${SUB}"
BLOCK="${2:-all}"

# -------------------------
# Paths
# -------------------------
mkdir -p "${BIDS_DIR}" "${OUT_DIR}" "${WORK_BASE}"

BIDS_DIR="$(readlink -f "${BIDS_DIR}")"
OUT_DIR="$(readlink -f "${OUT_DIR}")"
WORK_DIR="$(readlink -f "${WORK_BASE}/${SUB_LABEL}")"
FS_LIC="$(readlink -f "${FS_LIC}")"

mkdir -p "${WORK_DIR}" "${WORK_DIR}/templateflow"

echo "============================================================"
echo "[INFO] Running fMRIPrep ${VER} for ${SUB_LABEL}"
echo "BIDS    = ${BIDS_DIR}"
echo "OUT     = ${OUT_DIR}"
echo "WORK    = ${WORK_DIR}"
echo "FS_LIC  = ${FS_LIC}"
echo "============================================================"

# Avoid pulling in AFS $HOME
unset APPTAINER_BINDPATH APPTAINER_BIND

run_block () {
  local LABEL="$1"

  echo "------------------------------------------------------------"
  echo "[INFO] Block: ${LABEL}"
  echo "------------------------------------------------------------"

  apptainer run \
    --cleanenv --no-home --containall \
    -H /tmp --pwd /work \
    --env TEMPLATEFLOW_HOME=/work/templateflow \
    -B "${BIDS_DIR}:/data:ro" \
    -B "${OUT_DIR}:/out" \
    -B "${WORK_DIR}:/work" \
    -B "${FS_LIC}:/opt/freesurfer/license.txt:ro" \
    docker://nipreps/fmriprep:"${VER}" \
    /data /out participant \
    --participant-label "${SUB}" \
    --fs-license-file /opt/freesurfer/license.txt \
    --nthreads "${NTHREADS}" \
    --omp-nthreads "${OMP}" \
    --mem-mb "${MEM_MB}" \
    --output-spaces MNI152NLin2009cAsym
}

# ------------------------------
# Run blocks (labels only now)
# NOTE: Without BIDS filters, these "blocks" do NOT restrict which
# runs are processed — they are just separate invocations.
# ------------------------------
case "${BLOCK}" in
  all)
    run_block "obslearn (obslearn1, obslearn2)"
    run_block "risk (riskself, risksocial1, risksocial2)"
    run_block "trust (tm1, tm2, th1, th2)"
    ;;
  obslearn)
    run_block "obslearn (obslearn1, obslearn2)"
    ;;
  risk)
    run_block "risk (riskself, risksocial1, risksocial2)"
    ;;
  trust)
    run_block "trust (tm1, tm2, th1, th2)"
    ;;
  *)
    echo "[ERROR] Unknown block '${BLOCK}'. Use: all | obslearn | risk | trust"
    exit 2
    ;;
esac

echo "============================================================"
echo "[INFO] Done with ${SUB_LABEL}"
echo "============================================================"

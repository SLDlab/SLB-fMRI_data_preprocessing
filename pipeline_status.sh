#!/usr/bin/env bash
set -euo pipefail

ROOT="/data/sld/homes/collab/slb"
cd "$ROOT"

echo
echo "SLB SNAKEMAKE PIPELINE STATUS"
echo "=============================="
echo

raw=$(find -L raw_data -mindepth 1 -maxdepth 1 -type d \
    -name 'SLB_[0-9][0-9][0-9]' 2>/dev/null | wc -l)

bids=$(find bids_runs -mindepth 1 -maxdepth 1 -type d \
    -name 'sub-[0-9][0-9][0-9]' 2>/dev/null | wc -l)

ready=$(find state/ready -maxdepth 1 \
    -name 'sub-*.ready' 2>/dev/null | wc -l)

fmriprep=$(find derivatives/fmriprep_runs -maxdepth 1 \
    -name 'sub-*.html' 2>/dev/null | wc -l)

echo "Raw participants:        $raw"
echo "BIDS participants:       $bids"
echo "Ready for fMRIPrep:      $ready"
echo "Completed fMRIPrep:      $fmriprep"

echo
echo "Ready participants:"
find state/ready -maxdepth 1 \
    -name 'sub-*.ready' \
    -printf '  %f\n' 2>/dev/null \
    | sed 's/\.ready$//' \
    | sort

echo
echo "Current SLURM jobs:"
squeue -u "$USER" \
    -o "%.10i %.10P %.30j %.2t %.10M %R" \
    2>/dev/null || true

echo

#!/usr/bin/env bash
set -euo pipefail

ROOT="/data/sld/homes/collab/slb"
CONFIG_FILE="${CONFIG_FILE:-config/snakemake.yaml}"

cd "$ROOT"

export HOME="$ROOT"
export XDG_CACHE_HOME="$ROOT/.cache"
export XDG_CONFIG_HOME="$ROOT/.config"
export XDG_DATA_HOME="$ROOT/.local/share"

mkdir -p \
    "$XDG_CACHE_HOME" \
    "$XDG_CONFIG_HOME" \
    "$XDG_DATA_HOME" \
    "$ROOT/.locks"

source "$ROOT/envs/snakemake/bin/activate"

exec flock -n "$ROOT/.locks/fmriprep.lock" \
    snakemake \
        weekend_fmriprep \
        --configfile "$CONFIG_FILE" \
        --profile profiles/slurm \
        --jobs 3 \
        --cores 48 \
        --resources fmriprep_slot=3 \
        --printshellcmds \
        --rerun-incomplete \
        --rerun-triggers mtime \
        "$@"

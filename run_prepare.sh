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

exec 9>"$ROOT/.locks/prepare.lock"

if ! flock -n 9; then
    echo "Another preparation workflow is already running."
    exit 1
fi

echo
echo "=== Refreshing participant discovery ==="

snakemake \
    state/discovered/raw_participants.txt \
    state/discovered/behavioral_inputs.tsv \
    --configfile "$CONFIG_FILE" \
    --cores 1 \
    --forcerun \
        discover_raw_participants \
        discover_behavioral_inputs \
    --printshellcmds

echo
echo "=== Building preparation workflow ==="

snakemake \
    prepare_all \
    --configfile "$CONFIG_FILE" \
    --cores 1 \
    --printshellcmds \
    --rerun-incomplete \
    --rerun-triggers mtime \
    "$@"

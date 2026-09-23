#!/usr/bin/env bash
set -euo pipefail

ROOT="/data/sld/homes/collab/slb"
cd "$ROOT"

RAW_MANIFEST="state/discovered/raw_participants.txt"

if [ ! -s "$RAW_MANIFEST" ]; then
    echo "ERROR: $RAW_MANIFEST is missing."
    echo "Run discovery first."
    exit 1
fi

mkdir -p \
    state/bidsified \
    state/intendedfor \
    state/prepared \
    state/ready \
    state/events/ol \
    state/events/sra \
    state/events/trust

echo "Bootstrapping existing production state..."
echo

total=0
bids_ok=0
intendedfor_ok=0

while read -r id; do
    [ -n "$id" ] || continue

    total=$((total + 1))
    subject_dir="bids_runs/sub-${id}"

    has_t1=0
    has_bold=0
    has_fmap=0

    compgen -G "$subject_dir/anat/*_T1w.nii*" >/dev/null && has_t1=1 || true
    compgen -G "$subject_dir/func/*_bold.nii*" >/dev/null && has_bold=1 || true
    compgen -G "$subject_dir/fmap/*_epi.json" >/dev/null && has_fmap=1 || true

    if [ "$has_t1" -eq 1 ] && \
       [ "$has_bold" -eq 1 ] && \
       [ "$has_fmap" -eq 1 ]; then

        touch "state/bidsified/sub-${id}.done"
        bids_ok=$((bids_ok + 1))
        echo "BIDS OK:       sub-${id}"
    else
        echo "BIDS MISSING:  sub-${id}"
    fi

    report="bids_runs/code/intendedfor_reports/sub-${id}_intendedfor_report.json"

    if [ -s "$report" ]; then
        if python - "$report" <<'PY'
import json
import sys

with open(sys.argv[1]) as f:
    report = json.load(f)

problems = report.get("validation_problems", [])
raise SystemExit(0 if not problems else 1)
PY
        then
            touch "state/intendedfor/sub-${id}.done"
            intendedfor_ok=$((intendedfor_ok + 1))
            echo "IntendedFor:  sub-${id}"
        else
            echo "IntendedFor problems: sub-${id}"
        fi
    else
        echo "IntendedFor report missing: sub-${id}"
    fi

done < "$RAW_MANIFEST"

echo
echo "Checking event coverage for existing BOLD runs..."

python - "$RAW_MANIFEST" <<'PY'
from pathlib import Path
import sys

ids = [
    line.strip()
    for line in Path(sys.argv[1]).read_text().splitlines()
    if line.strip()
]

missing = []

for ident in ids:
    sub = f"sub-{ident}"
    func = Path("bids_runs") / sub / "func"

    for bold in sorted(func.glob("*_bold.nii.gz")):
        event = func / bold.name.replace("_bold.nii.gz", "_events.tsv")

        if not event.is_file():
            missing.append((bold, event))

if missing:
    print("Missing events for existing BOLD runs:", file=sys.stderr)

    for bold, event in missing:
        print(f" BOLD:  {bold}", file=sys.stderr)
        print(f" EVENT: {event}", file=sys.stderr)

    raise SystemExit(1)

print("Every existing BOLD run has a matching events.tsv.")
PY

touch state/events/ol/all.done
touch state/events/sra/all.done
touch state/events/trust/all.done

echo
echo "OL events:      adopted"
echo "SRA events:     adopted"
echo "Trust events:   adopted"

echo
echo "Bootstrap summary"
echo "-----------------"
echo "Discovered participants: $total"
echo "BIDS adopted:            $bids_ok"
echo "IntendedFor adopted:     $intendedfor_ok"

if [ "$bids_ok" -eq "$total" ]; then
    touch state/bidsified/all.done
    echo "BIDS aggregate:          adopted"
else
    rm -f state/bidsified/all.done
    echo "BIDS aggregate:          NOT created"
fi

echo
echo "Prepared and ready markers were intentionally NOT bootstrapped."
echo "They will be created by the normal Snakemake preparation workflow."
echo
echo "Bootstrap complete."

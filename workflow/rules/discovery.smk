rule discover_raw_participants:
    output:
        participants="state/discovered/raw_participants.txt"

    params:
        raw_dir=config["paths"]["raw"]

    log:
        "logs/snakemake/discover_raw_participants.log"

    shell:
        r"""
        set -euo pipefail

        mkdir -p state/discovered logs/snakemake

        tmp="$(mktemp)"

        find -L "{params.raw_dir}" \
            -mindepth 1 \
            -maxdepth 1 \
            -type d \
            \( \
                -name 'SLB_[0-9][0-9][0-9]' \
                -o -name 'SLB[0-9][0-9][0-9]' \
                -o -name '[0-9][0-9][0-9]' \
            \) \
            -printf '%f\n' \
        | sed -E 's/^SLB_?//' \
        | sort -u \
        > "$tmp"

        if [ ! -f "{output.participants}" ] || \
           ! cmp -s "$tmp" "{output.participants}"; then
            mv "$tmp" "{output.participants}"
        else
            rm -f "$tmp"
        fi

        echo "Discovered $(wc -l < "{output.participants}") raw participants." \
            > "{log}"
        """


rule discover_behavioral_inputs:
    output:
        manifest="state/discovered/behavioral_inputs.tsv"

    params:
        behav_dir=config["paths"]["behav"]

    log:
        "logs/snakemake/discover_behavioral_inputs.log"

    shell:
        r"""
        set -euo pipefail

        mkdir -p state/discovered logs/snakemake

        tmp="$(mktemp)"

        python - "{params.behav_dir}" "$tmp" <<'PY'
from pathlib import Path
import hashlib
import sys

root = Path(sys.argv[1])
output = Path(sys.argv[2])

rows = []

for participant_dir in sorted(root.glob("SLB_[0-9][0-9][0-9]")):
    if not participant_dir.is_dir():
        continue

    participant = participant_dir.name.removeprefix("SLB_")

    csv_files = sorted(
        path
        for path in participant_dir.rglob("*.csv")
        if path.is_file()
    )

    combined = hashlib.sha256()

    for csv_file in csv_files:
        relative = csv_file.relative_to(participant_dir)

        combined.update(str(relative).encode("utf-8"))
        combined.update(b"\0")

        with csv_file.open("rb") as handle:
            while True:
                chunk = handle.read(1024 * 1024)
                if not chunk:
                    break
                combined.update(chunk)

        combined.update(b"\0")

    rows.append(
        "%s\t%s\n" % (participant, combined.hexdigest())
    )

output.write_text("".join(rows))
PY

        if [ ! -f "{output.manifest}" ] || \
           ! cmp -s "$tmp" "{output.manifest}"; then
            mv "$tmp" "{output.manifest}"
        else
            rm -f "$tmp"
        fi

        echo "Tracked $(wc -l < "{output.manifest}") behavioral participants." \
            > "{log}"
        """

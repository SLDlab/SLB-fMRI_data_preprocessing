rule validate_subject:
    input:
        prepared="state/prepared/sub-{participant}.done",
        intendedfor_report=(
            "bids_runs/code/intendedfor_reports/"
            "sub-{participant}_intendedfor_report.json"
        )

    output:
        report="state/ready/sub-{participant}.validation.json",
        ready="state/ready/sub-{participant}.ready"

    log:
        "logs/snakemake/validation/sub-{participant}.log"

    shell:
        r"""
        set -euo pipefail

        mkdir -p state/ready logs/snakemake/validation

        test -d "bids_runs/sub-{wildcards.participant}"

        python -c '
import json
import sys

report = json.load(open(sys.argv[1]))
problems = report.get("validation_problems", [])

if problems:
    print("IntendedFor validation failed:", file=sys.stderr)
    for problem in problems:
        print(" -", problem, file=sys.stderr)
    raise SystemExit(1)
' "{input.intendedfor_report}"

        python workflow/scripts/validate_subject.py \
            bids_runs \
            "{wildcards.participant}" \
            "{output.report}" \
            > "{log}" 2>&1

        python -c '
import json
import sys

report = json.load(open(sys.argv[1]))

if not report["summary"]["ready"]:
    print("Participant is not ready:", file=sys.stderr)
    for error in report["errors"]:
        print(" -", error, file=sys.stderr)
    raise SystemExit(1)
' "{output.report}"

        touch "{output.ready}"
        """

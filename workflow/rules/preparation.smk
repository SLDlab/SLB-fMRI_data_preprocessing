rule bidsify_participant:
    input:
        raw_dir=lambda wc: (
            f"{config['paths']['raw']}/SLB_{wc.participant}"
        )

    output:
        marker="state/bidsified/sub-{participant}.done"

    params:
        enabled=config["execution"]["allow_bids_conversion"],
        script=config["scripts"]["bidsify"],
        project_root=config["project_root"],
        production_root=config["production_root"],
        bids_root=config["paths"]["bids"]

    log:
        "logs/snakemake/bidsify/sub-{participant}.log"

    shell:
        r"""
        set -euo pipefail

        mkdir -p state/bidsified logs/snakemake/bidsify

        if [ "{params.enabled}" != "True" ]; then
            echo "BIDS conversion is disabled in config." >&2
            exit 2
        fi

        if [ "{params.project_root}" != "{params.production_root}" ]; then
            echo "Refusing BIDS conversion outside configured project root." >&2
            exit 2
        fi

        subject_dir="{params.bids_root}/sub-{wildcards.participant}"

        has_t1=0
        has_bold=0
        has_fmap=0

        compgen -G "$subject_dir/anat/*_T1w.nii*" >/dev/null && has_t1=1 || true
        compgen -G "$subject_dir/func/*_bold.nii*" >/dev/null && has_bold=1 || true
        compgen -G "$subject_dir/fmap/*_epi.json" >/dev/null && has_fmap=1 || true

        if [ "$has_t1" -eq 1 ] && \
           [ "$has_bold" -eq 1 ] && \
           [ "$has_fmap" -eq 1 ]; then

            echo "sub-{wildcards.participant}: imaging BIDS already complete; skipping conversion." \
                > "{log}"

        else
            echo "sub-{wildcards.participant}: incomplete imaging BIDS; running conversion." \
                > "{log}"

            "{params.script}" "{wildcards.participant}" --force \
                >> "{log}" 2>&1
        fi

        test -d "$subject_dir"
        compgen -G "$subject_dir/anat/*_T1w.nii*" >/dev/null
        compgen -G "$subject_dir/func/*_bold.nii*" >/dev/null
        compgen -G "$subject_dir/fmap/*_epi.json" >/dev/null

        touch "{output.marker}"
        """


rule bidsify_all_selected:
    input:
        selected_bids_markers

    output:
        marker="state/bidsified/all.done"

    shell:
        r"""
        set -euo pipefail

        mkdir -p state/bidsified
        touch "{output.marker}"
        """


rule intendedfor_participant:
    input:
        bidsified=ancient("state/bidsified/sub-{participant}.done")

    output:
        report=(
            "bids_runs/code/intendedfor_reports/"
            "sub-{participant}_intendedfor_report.json"
        ),
        marker="state/intendedfor/sub-{participant}.done"

    params:
        enabled=config["execution"]["allow_intendedfor_write"],
        script=config["scripts"]["intendedfor"],
        project_root=config["project_root"],
        production_root=config["production_root"],
        bids_root=config["paths"]["bids"]

    log:
        "logs/snakemake/intendedfor/sub-{participant}.log"

    shell:
        r"""
        set -euo pipefail

        mkdir -p state/intendedfor logs/snakemake/intendedfor
        mkdir -p "{params.bids_root}/code/intendedfor_reports"

        if [ "{params.enabled}" != "True" ]; then
            echo "IntendedFor writing is disabled in config." >&2
            exit 2
        fi

        if [ "{params.project_root}" != "{params.production_root}" ]; then
            echo "Refusing IntendedFor writes outside production root." >&2
            exit 2
        fi

        python "{params.script}" \
            "{params.bids_root}" \
            "sub-{wildcards.participant}" \
            > "{log}" 2>&1

        test -s "{output.report}"

        python -c '
import json
import sys

report = json.load(open(sys.argv[1]))
problems = report.get("validation_problems", [])

if problems:
    print("IntendedFor validation problems:", file=sys.stderr)
    for problem in problems:
        print(" -", problem, file=sys.stderr)
    raise SystemExit(1)
' "{output.report}"

        touch "{output.marker}"
        """


rule build_ol_events:
    input:
        bidsified="state/bidsified/all.done",
        behavioral="state/discovered/behavioral_inputs.tsv"

    output:
        marker="state/events/ol/all.done"

    params:
        enabled=config["execution"]["allow_event_generation"],
        script=config["scripts"]["events_ol"],
        project_root=config["project_root"],
        production_root=config["production_root"]

    log:
        "logs/snakemake/events/ol.log"

    shell:
        r"""
        set -euo pipefail

        mkdir -p state/events/ol logs/snakemake/events

        if [ "{params.enabled}" != "True" ]; then
            echo "OL event generation is disabled in config." >&2
            exit 2
        fi

        if [ "{params.project_root}" != "{params.production_root}" ]; then
            echo "Refusing OL event generation outside production root." >&2
            exit 2
        fi

        python "{params.script}" > "{log}" 2>&1

        touch "{output.marker}"
        """


rule build_sra_events:
    input:
        bidsified="state/bidsified/all.done",
        behavioral="state/discovered/behavioral_inputs.tsv"

    output:
        marker="state/events/sra/all.done"

    params:
        enabled=config["execution"]["allow_event_generation"],
        script=config["scripts"]["events_sra"],
        project_root=config["project_root"],
        production_root=config["production_root"]

    log:
        "logs/snakemake/events/sra.log"

    shell:
        r"""
        set -euo pipefail

        mkdir -p state/events/sra logs/snakemake/events

        if [ "{params.enabled}" != "True" ]; then
            echo "SRA event generation is disabled in config." >&2
            exit 2
        fi

        if [ "{params.project_root}" != "{params.production_root}" ]; then
            echo "Refusing SRA event generation outside production root." >&2
            exit 2
        fi

        python "{params.script}" > "{log}" 2>&1

        touch "{output.marker}"
        """


rule build_trust_events:
    input:
        bidsified="state/bidsified/all.done",
        behavioral="state/discovered/behavioral_inputs.tsv"

    output:
        marker="state/events/trust/all.done"

    params:
        enabled=config["execution"]["allow_event_generation"],
        script=config["scripts"]["events_trust"],
        project_root=config["project_root"],
        production_root=config["production_root"]

    log:
        "logs/snakemake/events/trust.log"

    shell:
        r"""
        set -euo pipefail

        mkdir -p state/events/trust logs/snakemake/events

        if [ "{params.enabled}" != "True" ]; then
            echo "Trust event generation is disabled in config." >&2
            exit 2
        fi

        if [ "{params.project_root}" != "{params.production_root}" ]; then
            echo "Refusing Trust event generation outside production root." >&2
            exit 2
        fi

        python "{params.script}" > "{log}" 2>&1

        touch "{output.marker}"
        """


rule participant_prepared:
    input:
        intendedfor="state/intendedfor/sub-{participant}.done",
        ol_events="state/events/ol/all.done",
        sra_events="state/events/sra/all.done",
        trust_events="state/events/trust/all.done"

    output:
        marker="state/prepared/sub-{participant}.done"

    shell:
        r"""
        set -euo pipefail

        mkdir -p state/prepared
        touch "{output.marker}"
        """

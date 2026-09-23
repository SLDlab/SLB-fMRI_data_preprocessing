from pathlib import Path

configfile: "config/snakemake.yaml"


def selected_participants(wildcards=None):
    if config["mode"] == "sandbox":
        return [
            str(participant).zfill(3)
            for participant in config["testing"]["participants"]
        ]

    manifest = Path("state/discovered/raw_participants.txt")

    if not manifest.exists():
        raise ValueError(
            "Raw participant manifest is missing. "
            "Run discovery before building the production DAG."
        )

    return [
        line.strip()
        for line in manifest.read_text().splitlines()
        if line.strip()
    ]


def selected_bids_markers(wildcards):
    return expand(
        "state/bidsified/sub-{participant}.done",
        participant=selected_participants(wildcards)
    )


def selected_ready_targets(wildcards):
    return expand(
        "state/ready/sub-{participant}.ready",
        participant=selected_participants(wildcards)
    )


def ready_fmriprep_targets(wildcards):
    ready_dir = Path("state/ready")

    participants = sorted(
        path.name
            .removeprefix("sub-")
            .removesuffix(".ready")
        for path in ready_dir.glob("sub-*.ready")
    )

    return expand(
        "derivatives/fmriprep_runs/sub-{participant}.html",
        participant=participants
    )


include: "workflow/rules/discovery.smk"
include: "workflow/rules/preparation.smk"
include: "workflow/rules/validation.smk"
include: "workflow/rules/fmriprep.smk"


rule all:
    input:
        selected_ready_targets


rule prepare_all:
    input:
        selected_ready_targets


rule weekend_fmriprep:
    input:
        ready_fmriprep_targets

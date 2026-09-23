rule fmriprep:
    input:
        ready=ancient("state/ready/sub-{participant}.ready")

    output:
        report="derivatives/fmriprep_runs/sub-{participant}.html"

    params:
        enabled=config["execution"]["permit_fmriprep_submission"],
        script=config["scripts"]["fmriprep"],
        project_root=config["project_root"],
        production_root=config["production_root"],
        weekend_days=" ".join(
            str(day)
            for day in config["fmriprep"]["weekend_days"]
        )

    threads: 8

    resources:
        mem_mb=32000,
        runtime=2880,
        fmriprep_slot=1

    log:
        "logs/snakemake/fmriprep/sub-{participant}.log"

    shell:
        r"""
        set -euo pipefail

        mkdir -p logs/snakemake/fmriprep

        if [ "{params.enabled}" != "True" ]; then
            echo "fMRIPrep submission is disabled in config." >&2
            exit 2
        fi

        if [ "{params.project_root}" != "{params.production_root}" ]; then
            echo "Refusing fMRIPrep outside production root." >&2
            exit 2
        fi

        current_day="$(date +%u)"

        case " {params.weekend_days} " in
            *" ${{current_day}} "*)
                ;;
            *)
                echo "fMRIPrep can only start on configured weekend days." >&2
                exit 2
                ;;
        esac

        NTHREADS="{threads}" \
        OMP="4" \
        MEM_MB="{resources.mem_mb}" \
        "{params.script}" "{wildcards.participant}" obslearn \
            > "{log}" 2>&1

        test -s "{output.report}"
        """

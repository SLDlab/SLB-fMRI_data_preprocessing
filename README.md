# SLB-fMRI_data_preprocessing

# SLB fMRI Data Preprocessing Pipeline

End-to-end preprocessing pipeline for the **SLB Social Learning** fMRI project.

This pipeline converts raw scanner exports into a structured, BIDS-compliant dataset and runs the core preprocessing steps needed for downstream QA/QC, denoising, and analysis. It is designed to be reproducible, rerunnable, and safe for shared lab use.

---

## Overview

This pipeline implements a full fMRI preprocessing workflow, starting from raw scanner extraction and ending with validated derivatives for downstream analysis.

The workflow covers:

- Raw scanner data extraction from the remote archive
- DICOM to BIDS conversion using HeuDiConv
- Automatic fieldmap wiring via `IntendedFor`
- Behavioral-to-BIDS event file generation
- Standard fMRIPrep preprocessing
- Optional MRIQC
- Optional MNI6 preprocessing for ICA-AROMA
- Optional fMRIPost-AROMA denoising

The pipeline enforces strict separation between:

- **Raw data** — original scanner exports, never modified
- **BIDS data** — structured analysis input dataset
- **Derivatives** — outputs from fMRIPrep, MRIQC, and AROMA
- **Work directories** — scratch/intermediate files, safe to regenerate
- **Logs** — execution history for debugging and auditing

## Automated Production Pipeline

The SLB preprocessing workflow is automated using Snakemake for workflow orchestration and SLURM for computationally intensive preprocessing.

The automation builds on the existing scientific scripts documented below. Snakemake determines which participants require processing, tracks completed steps, validates preprocessing inputs, and submits eligible participants for fMRIPrep.

The production pipeline runs on the UMD SLD server:

```text
/data/sld/homes/collab/slb/
```

### Automated Workflow

```text
fMRI2
  |
  | Daily, 2:00 AM
  v
Raw-data transfer
  |
  v
raw_data/
  |
  | Daily, 6:00 AM
  v
Snakemake preparation
  |
  v
Participant discovery
  |
  v
BIDS conversion
  |
  v
IntendedFor assignment
  |
  v
BIDS events generation
  |
  v
Participant validation
  |
  v
state/ready/sub-XXX.ready
  |
  | Saturday, 5:00 AM
  v
Snakemake + SLURM
  |
  v
fMRIPrep
  |
  v
derivatives/fmriprep_runs/sub-XXX.html
  |
  | Monday, 9:00 AM
  v
Weekly Slack summary
```

### Automated Schedule

| Schedule | Operation | Script |
|---|---|---|
| Daily, 2:00 AM | Transfer raw scanner data | `/usr/local/sbin/sync-slb.sh` |
| Daily, 6:00 AM | Prepare and validate participants | `run_prepare.sh` |
| Daily, 8:00 AM | Report raw-data transfer changes | `scripts/nightly_extract_and_notify.sh` |
| Saturday, 5:00 AM | Run pending fMRIPrep jobs | `run_weekend_fmriprep.sh` |
| Monday, 9:00 AM | Send weekly preprocessing summary | `scripts/slack_notify.sh` |

The scheduled jobs are managed through cron on the SLD server.

### Snakemake Workflow

The automation is organized into the following components:

```text
Snakefile

workflow/
├── rules/
│   ├── discovery.smk
│   ├── preparation.smk
│   ├── validation.smk
│   └── fmriprep.smk
│
└── scripts/
    └── validate_subject.py

config/
├── snakemake.yaml.example
└── snakemake-requirements-lock.txt

profiles/
└── slurm/
    └── config.yaml

run_prepare.sh
run_weekend_fmriprep.sh
pipeline_status.sh
bootstrap_existing_state.sh
```

The workflow is designed to be idempotent: completed processing is not repeated unless the relevant inputs or required outputs change.

### Participant Readiness

Each participant progresses through BIDS conversion, IntendedFor assignment, behavioral event generation, and validation.

Successful validation creates:

```text
state/ready/sub-XXX.ready
```

This marker indicates that the participant is eligible for the weekend fMRIPrep workflow.

Validation checks the functional runs that actually exist, allowing for legitimately missing acquisitions.

### Weekend fMRIPrep

The weekend workflow automatically identifies participants that are ready for preprocessing but do not yet have a completed fMRIPrep report.

Each fMRIPrep job currently requests:

- 16 CPUs
- 48 GB RAM
- The SLURM compute partition

The workflow allows a maximum of three concurrent fMRIPrep jobs.

This is a concurrency limit, not a weekly participant limit. When a job finishes, Snakemake can submit another eligible participant.

A participant's automated fMRIPrep stage is considered complete when the corresponding non-empty report exists:

```text
derivatives/fmriprep_runs/sub-XXX.html
```

This is a processing-completion checkpoint, not a substitute for reviewing the participant's quality-control results.

### SLURM Compatibility

The SLD cluster does not provide completed-job accounting through `sacct`.

The Snakemake SLURM profile therefore explicitly uses:

```yaml
slurm-status-command: squeue
```

This allows Snakemake to track submitted jobs and recognize their completion.

### Weekly Slack Summary

Every Monday at 9:00 AM, the pipeline posts a summary to the lab's Slack channel.

The summary includes:

- Participants newly completed since the previous successful report
- Total participants with completed fMRIPrep reports
- Participants ready for fMRIPrep but still pending

The Slack notifier is implemented in:

```text
scripts/slack_notify.sh
```

The notification sends operational status information. Raw imaging data, behavioral datasets, and preprocessing derivatives are not uploaded to Slack.

### Checking Pipeline Status

Run these commands from the production SLB directory on SLD.

Check daily preparation:

```bash
./run_prepare.sh --dry-run
```

Check pending fMRIPrep work:

```bash
./run_weekend_fmriprep.sh --dry-run
```

Check overall pipeline status:

```bash
./pipeline_status.sh
```

Count completed fMRIPrep reports:

```bash
find derivatives/fmriprep_runs \
    -maxdepth 1 \
    -type f \
    -name 'sub-*.html' \
    -size +0c \
    | wc -l
```

### Data Privacy

Snakemake runs locally on SLD and submits computational jobs to the UMD SLURM cluster.

The workflow does not upload research data to a Snakemake-hosted service.

Raw data, BIDS data, behavioral datasets, derivatives, credentials, and operational secrets must remain outside the repository.

The production Slack webhook is stored locally and must never be committed to version control.

## Pipeline Architecture

| Stage | Script | Responsibility |
|---|---|---|
| 1 | `sync-slb.sh` (production), `extract_mnc.sh` (manual) | Transfer raw scanner data from fMRI2 to SLD |
| 2 | `bidsify_runs.sh` | Convert DICOMs to BIDS with HeuDiConv |
| 3 | `add_intendedfor_by_task.py` | Add correct `IntendedFor` mappings to fieldmaps |
| 4 | `build_*_bids_events_from_behavioral_runs.py` | Build BIDS `events.tsv` from behavioral outputs |
| 5 | `run_fmriprep_runs.sh` | Run standard fMRIPrep preprocessing |
| 6 | `run_mriqc.sh` | Run MRIQC for image quality assessment |
| 7 | `run_fmriprep_mni6_runs.sh` | Run MNI6-only preprocessing for AROMA compatibility |
| 8 | `run_fmripost_aroma_runs.sh` | Run ICA-AROMA denoising on MNI6 outputs |

Each stage:

- has clearly defined inputs and outputs
- performs one logical operation
- can be rerun independently
- preserves upstream raw inputs unchanged

Prerequisites

Before running the pipeline, make sure the following are available:

- access to the SLD server
- access to /data/sld/homes/collab/slb
- UMD network or GlobalProtect VPN if off campus
- required Linux group permissions for shared directories
- Apptainer/Singularity available on the server
- FreeSurfer license file present
- required containers available locally or pullable at runtime


## Stage 1. Raw Data Transfer (fMRI2 → SLD)

### Production Script

`/usr/local/sbin/sync-slb.sh`

### Purpose

Automatically transfers raw SLB scanner data from the fMRI2 server to the SLD server for downstream preprocessing.

The production transfer is managed by a system-level script and runs automatically every day at 2:00 AM.

### What it does

- Connects to fMRI2 using SSH with Kerberos/GSSAPI authentication.
- Uses a dedicated service account rather than personal UMD credentials.
- Transfers new or updated files using `rsync`.
- Preserves the raw-data directory structure.
- Performs incremental synchronization without unnecessarily copying existing files.
- Does not automatically delete destination files that are removed from the source.
- Records transfer activity and statistics in the production log.

### Source

```text
fmri2.umd.edu

/export/software/fmri/massstorage/Caroline Charpentier/SLB Social Learning/
```

### Destination

```text
/data/sld/homes/collab/slb/raw_data/
```

### Automated Schedule

The production transfer runs daily at 2:00 AM through cron:

```cron
0 2 * * * /usr/local/sbin/sync-slb.sh >> /var/log/sld-slb-sync.log 2>&1
```

Under normal operation, no manual transfer is required.

### Checking Transfer Status

To inspect the production transfer log:

```bash
tail -n 100 /var/log/sld-slb-sync.log
```

To view recent successful transfers:

```bash
grep "Completed SLD raw data pull" \
    /var/log/sld-slb-sync.log | tail
```

To check transferred participant data:

```bash
ls -lah /data/sld/homes/collab/slb/raw_data/
```

A successful transfer means the raw scanner data has reached SLD. It does not mean BIDS conversion or fMRIPrep has completed.

### Manual Extraction Utility

The repository also contains:

```text
extract_mnc.sh
```

This is the original extraction utility and remains available for manual transfers and troubleshooting.

It is not responsible for the scheduled production transfer.

From the SLB project directory on SLD:

```bash
cd /data/sld/homes/collab/slb
```

Manual extraction:

```bash
./scripts/extract_mnc.sh
```

Dry run:

```bash
./scripts/extract_mnc.sh -n
```

Restrict extraction to specific sessions:

```bash
./scripts/extract_mnc.sh -S 202512*
```

For normal automated operations, use the production `sync-slb.sh` workflow instead.

### Transfer Notifications

The transfer notification script is:

```text
scripts/nightly_extract_and_notify.sh
```

It runs daily at 8:00 AM, after the scheduled raw-data transfer.

The notifier reads the production rsync log:

```text
/var/log/sld-slb-sync.log
```

It also compares raw-data file counts and storage totals against the previous snapshot.

Slack notifications are sent when new raw data is detected or a transfer error is identified.

The notification script does not initiate the production transfer or run `extract_mnc.sh`.
 ## Stage 2. BIDS Conversion

### Script
`bidsify_runs.sh`

### Purpose
Converts raw DICOMs into a BIDS-compliant dataset using HeuDiConv and the custom SLB heuristic.

### What it does

- detects candidate subject folders in `raw_data/`
- runs HeuDiConv in a container
- applies `heuristic_runs.py` to map scanner sequences into BIDS outputs
- creates subject-level `anat/`, `func/`, and `fmap/` folders
- supports reruns and forced reconversion
- resets cached `.heudiconv` state when forcing reconversion

### Input

- raw scanner folders in `raw_data/`
- `heuristic_runs.py`
- HeuDiConv container

### Output

```text
bids_runs/
├── sub-XXX/
│   ├── anat/
│   ├── func/
│   ├── fmap/
│   └── sub-XXX_scans.tsv
├── dataset_description.json
├── participants.tsv
└── task-*_bold.json
```

### Commands

```bash
./bidsify_runs.sh
./bidsify_runs.sh XXX
./bidsify_runs.sh --force
./bidsify_runs.sh XXX --force
```

## Stage 3. Fieldmap Wiring

### Script
`add_intendedfor_by_task.py`

### Purpose
Automatically adds correct `IntendedFor` entries to fieldmap JSONs so each fieldmap pair is linked to the right functional runs.

### Task-to-acquisition mapping

- `obslearn` → `acq-obslearn`
- `riskself`, `risksocial` → `acq-risk`
- `th`, `tm` → `acq-trust`

### What it does

- scans `func/` for task runs
- identifies matching fieldmaps by `acq-` label
- writes correct relative `IntendedFor` paths into `fmap/*.json`
- supports both current and legacy naming styles
- validates AP/PA pairing and missing targets
- writes a per-subject validation report

### Output

- updated fieldmap JSON files
- report JSONs in:

```text
bids_runs/code/intendedfor_reports/
```
### Commands

```
python3 add_intendedfor_by_task.py /data/sld/homes/collab/slb/bids_runs --dry-run
python3 add_intendedfor_by_task.py /data/sld/homes/collab/slb/bids_runs
python3 add_intendedfor_by_task.py /data/sld/homes/collab/slb/bids_runs sub-XXX sub-001
```

## Stage 4. BIDS Events Generation

### Scripts

- `build_ol_bids_events_from_behavioral_runs.py`
- `build_sra_bids_events_from_behavioral_runs.py`
- `build_trust_bids_events_from_behavioral_runs.py`
- `combined_build_bids_events_from_behavioral_runs.py`

### Purpose
Converts behavioral outputs into BIDS-compliant `events.tsv` files aligned to each functional run.

### What it does

- reads task-specific behavioral data
- uses task dictionaries to define onset, duration, and trial labels
- writes clean run-aligned `events.tsv` files into `bids_runs/sub-*/func/`
- preserves task-specific variables needed for downstream modeling

### Output

```text
bids_runs/sub-XXX/func/
├── sub-XXX_task-*_run-01_events.tsv
├── sub-XXX_task-*_run-02_events.tsv
```

### Commands
```
python3 build_ol_bids_events_from_behavioral_runs.py
python3 build_sra_bids_events_from_behavioral_runs.py
python3 build_trust_bids_events_from_behavioral_runs.py
python3 combined_build_bids_events_from_behavioral_runs.py
```

## Stage 5. Standard Preprocessing

### Script
`run_fmriprep_runs.sh`

### Purpose
Runs the standard fMRIPrep preprocessing stream for a subject.

### What it does

- checks that the subject exists in the BIDS dataset
- runs fMRIPrep in participant mode
- applies distortion correction using wired fieldmaps
- performs standard preprocessing and confound estimation
- writes subject derivatives, reports, work files, and logs

### Output

```text
derivatives/fmriprep_runs/
├── sub-XXX/
├── logs/
└── sourcedata/
`
derivatives/fmriprep_runs/sub-XXX.html
work/fmriprep_runs/sub-XXX/
```

### Command
```
./run_fmriprep_runs.sh XXX
```

## Stage 6. MRIQC

### Script
`run_mriqc_runs.sh`

### Purpose
Runs MRIQC to assess the quality of anatomical and functional MRI data and generate quantitative metrics and visual reports.

MRIQC is an optional quality-control step. It does not modify the input BIDS dataset.

### What it does

- Validates that the requested subjects exist in the BIDS dataset.
- Runs MRIQC in participant mode using an Apptainer container.
- Computes image-quality metrics for anatomical and functional scans.
- Generates subject-level quality-control reports.
- Supports individual subjects, multiple subjects, subject ranges, and all available subjects.
- Optionally runs group-level quality-control aggregation.

### Input

- BIDS dataset in `bids_runs/`
- MRIQC Apptainer container (`mriqc_23.0.1.sif`)

### Output

```text
derivatives/mriqc_runs/
work/mriqc_runs/
logs/mriqc_<timestamp>.log
```

### Commands

Run MRIQC for a single subject:

```bash
./scripts/run_mriqc_runs.sh 000
```

Run for multiple subjects:

```bash
./scripts/run_mriqc_runs.sh 000 001 002
```

Run for a range of subjects:

```bash
./scripts/run_mriqc_runs.sh --range 000 003
```

Run for all available subjects and generate group-level reports:

```bash
./scripts/run_mriqc_runs.sh --all --group
```

Preview the commands without running MRIQC:

```bash
./scripts/run_mriqc_runs.sh 000 --dry-run
```

**Note:** These commands use the SLD production layout, where the script is inside `scripts/`. In the GitHub repository, the existing script is currently at the root.

## Stage 7. MNI6 Preprocessing for AROMA

### Script
`run_fmriprep_mni6_runs.sh`

### Purpose
Runs a separate fMRIPrep stream restricted to `MNI152NLin6Asym`, which is required for downstream ICA-AROMA.

### What it does

- runs fMRIPrep on the requested subject
- writes outputs to a separate derivatives stream
- keeps the AROMA-compatible preprocessing branch isolated from the standard branch

### Output

```text
derivatives/fmriprep_mni6_runs/
work/fmriprep_mni6_runs/
```

### Command
```
./run_fmriprep_mni6_runs.sh XXX
```

## Stage 8. ICA-AROMA Denoising

### Script
`run_fmripost_aroma_runs.sh`

### Purpose
Runs fMRIPost-AROMA on the MNI6 derivatives to identify and remove structured motion-related noise.

### What it does

- takes MNI6 fMRIPrep derivatives as input
- runs fMRIPost-AROMA in participant mode
- writes denoised outputs and subject-level reports
- preserves a separate AROMA derivatives branch

### Output

```text
derivatives/fmripost_aroma_runs/
├── sub-XXX/
├── logs/
└── dataset_description.json

derivatives/fmripost_aroma_runs/sub-XXX.html
work/fmripost_aroma_runs/
```

### Command
```
./run_fmripost_aroma_runs.sh XXX
```



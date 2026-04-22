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

## Pipeline Architecture

| Stage | Script | Responsibility |
|---|---|---|
| 1 | `extract_mnc.sh` | Extract raw scanner data from remote archive |
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


## Stage 1. Raw Extraction

### Script
`extract_mnc.sh`

### Purpose
Copies raw scanner data from the remote `fmri2` archive into local `raw_data/` while preserving the session structure.

### What it does

- connects to the remote scanner archive using `rsync` over SSH
- copies only valid SLB participant folders
- skips phantom and legacy folders such as `SLB_p###`
- supports dry runs and mirrored deletion
- uses a lockfile to prevent concurrent extraction
- normalizes subject IDs such as `003/` into `SLB_003/`
- appends activity to the extraction log

### Input
Remote scanner archive under the SLB Social Learning directory on `fmri2`.

### Output

```
raw_data/SLB_###/<session>/
logs/extract.log
```
### Commands

Manual extraction: 
```bash
./scripts/extract_mnc.sh
```
Dry run: 
```bash
./scripts/extract_mnc.sh -n
```

Restricted to specific sessions: 
```bash
./scripts/extract_mnc.sh -S 202512*
```

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



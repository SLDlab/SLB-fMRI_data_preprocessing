"""
SLB heuristic (run-01/run-02)
- task names: obslearn, risksocial, th, tm (+ run-01/run-02)
- riskself: single run (no run entity)
- fieldmaps: keep your current mapping approach (obslearn / risk / trust) based on order
- no session entity
"""

def create_key(template, outtype=("nii.gz",), annotation_classes=None):
    return (template, outtype, annotation_classes)

# --- ANAT ---
t1w = create_key("sub-{subject}/anat/sub-{subject}_T1w")
t2w = create_key("sub-{subject}/anat/sub-{subject}_T2w")

# --- FUNC (BIDS-compliant runs) ---
bold_obslearn_run1   = create_key("sub-{subject}/func/sub-{subject}_task-obslearn_run-01_bold")
bold_obslearn_run2   = create_key("sub-{subject}/func/sub-{subject}_task-obslearn_run-02_bold")

bold_risksocial_run1 = create_key("sub-{subject}/func/sub-{subject}_task-risksocial_run-01_bold")
bold_risksocial_run2 = create_key("sub-{subject}/func/sub-{subject}_task-risksocial_run-02_bold")

bold_th_run1         = create_key("sub-{subject}/func/sub-{subject}_task-th_run-01_bold")
bold_th_run2         = create_key("sub-{subject}/func/sub-{subject}_task-th_run-02_bold")

bold_tm_run1         = create_key("sub-{subject}/func/sub-{subject}_task-tm_run-01_bold")
bold_tm_run2         = create_key("sub-{subject}/func/sub-{subject}_task-tm_run-02_bold")

bold_riskself        = create_key("sub-{subject}/func/sub-{subject}_task-riskself_bold")

# --- FIELDMAPS ---
fmap_1_ap = create_key("sub-{subject}/fmap/sub-{subject}_acq-obslearn_dir-AP_epi")
fmap_1_pa = create_key("sub-{subject}/fmap/sub-{subject}_acq-obslearn_dir-PA_epi")
fmap_2_ap = create_key("sub-{subject}/fmap/sub-{subject}_acq-risk_dir-AP_epi")
fmap_2_pa = create_key("sub-{subject}/fmap/sub-{subject}_acq-risk_dir-PA_epi")
fmap_3_ap = create_key("sub-{subject}/fmap/sub-{subject}_acq-trust_dir-AP_epi")
fmap_3_pa = create_key("sub-{subject}/fmap/sub-{subject}_acq-trust_dir-PA_epi")


def infotodict(seqinfo):
    info = {
        t1w: [], t2w: [],
        bold_obslearn_run1: [], bold_obslearn_run2: [],
        bold_risksocial_run1: [], bold_risksocial_run2: [],
        bold_th_run1: [], bold_th_run2: [],
        bold_tm_run1: [], bold_tm_run2: [],
        bold_riskself: [],
        fmap_1_ap: [], fmap_1_pa: [],
        fmap_2_ap: [], fmap_2_pa: [],
        fmap_3_ap: [], fmap_3_pa: [],
    }

    ap_count = 0
    pa_count = 0

    def norm(s):
        return (s or "").lower().replace(" ", "_")

    def has(sd, *tokens):
        return all(tok in sd for tok in tokens)

    # helper: assign run based on whether description explicitly contains "obslearn1" vs "obslearn2", etc.
    # This avoids brittle checks like "1" in sd.
    for s in seqinfo:
        sd = norm(s.series_description)
        sid = s.series_id

        # --- ANAT ---
        if ("t1w" in sd) or ("mpr" in sd):
            info[t1w].append(sid); continue
        if ("t2w" in sd) or ("spc" in sd):
            info[t2w].append(sid); continue

        # --- FIELDMAPS ---
        if "fm_dwi0_matched-ap" in sd:
            ap_count += 1
            if ap_count == 1: info[fmap_1_ap].append(sid)
            elif ap_count == 2: info[fmap_2_ap].append(sid)
            elif ap_count == 3: info[fmap_3_ap].append(sid)
            continue

        if "fm_dwi0_matched-pa" in sd:
            pa_count += 1
            if pa_count == 1: info[fmap_1_pa].append(sid)
            elif pa_count == 2: info[fmap_2_pa].append(sid)
            elif pa_count == 3: info[fmap_3_pa].append(sid)
            continue

        # --- FUNC ---
        if "bold" in sd:
            # obslearn (explicit 1/2)
            if "obslearn1" in sd:
                info[bold_obslearn_run1].append(sid); continue
            if "obslearn2" in sd:
                info[bold_obslearn_run2].append(sid); continue

            # risksocial (explicit 1/2)
            if "risksocial1" in sd:
                info[bold_risksocial_run1].append(sid); continue
            if "risksocial2" in sd:
                info[bold_risksocial_run2].append(sid); continue

            # th (explicit 1/2) – allow either "th1" or "v304_th1"
            if ("_th1" in sd) or ("th1" in sd):
                info[bold_th_run1].append(sid); continue
            if ("_th2" in sd) or ("th2" in sd):
                info[bold_th_run2].append(sid); continue

            # tm (explicit 1/2)
            if ("_tm1" in sd) or ("tm1" in sd):
                info[bold_tm_run1].append(sid); continue
            if ("_tm2" in sd) or ("tm2" in sd):
                info[bold_tm_run2].append(sid); continue

            # riskself (single)
            if "riskself" in sd:
                info[bold_riskself].append(sid); continue

    return info


def infotofile(t):
    return t

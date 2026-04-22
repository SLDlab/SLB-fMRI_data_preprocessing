#!/usr/bin/env bash
set -euo pipefail
source /data/sld/homes/collab/slb/.slb_env
# ----------------------------------------
# Config
# ----------------------------------------
ROOT_DIR="/data/sld/homes/collab/slb"
RAW_ROOT="${ROOT_DIR}/raw_data"
LOG_DIR="${ROOT_DIR}/logs"
SCRIPTS_DIR="${ROOT_DIR}/scripts"
EXTRACT_SCRIPT="${SCRIPTS_DIR}/extract_mnc.sh"

# Daily log for this job
LOG_FILE="${LOG_DIR}/nightly_extract_$(date +%Y%m%d).log"

# Slack webhook must be exported in your shell or sourced from an env file
SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

mkdir -p "${LOG_DIR}"

timestamp_start="$(date -Iseconds)"

echo "=============================================" >> "${LOG_FILE}"
echo "Nightly extraction run started at ${timestamp_start}" >> "${LOG_FILE}"
echo "RAW_ROOT = ${RAW_ROOT}" >> "${LOG_FILE}"
echo "LOG_FILE = ${LOG_FILE}" >> "${LOG_FILE}"

# ----------------------------------------
# Helper: human-readable bytes
# ----------------------------------------
human_readable() {
  local bytes=$1
  local unit="B"
  local value=$bytes

  if (( bytes > 1024 )); then
    value=$(awk "BEGIN {printf \"%.2f\", ${bytes}/1024}")
    unit="KB"
  fi
  if (( bytes > 1024*1024 )); then
    value=$(awk "BEGIN {printf \"%.2f\", ${bytes}/(1024*1024)}")
    unit="MB"
  fi
  if (( bytes > 1024*1024*1024 )); then
    value=$(awk "BEGIN {printf \"%.2f\", ${bytes}/(1024*1024*1024)}")
    unit="GB"
  fi

  echo "${value} ${unit}"
}

# ----------------------------------------
# Snapshot BEFORE extraction
# ----------------------------------------
before_files=$(find "${RAW_ROOT}" -type f 2>/dev/null | wc -l || echo 0)
before_bytes=$(du -sb "${RAW_ROOT}" 2>/dev/null | awk '{print $1}' || echo 0)

echo "[${timestamp_start}] BEFORE: ${before_files} files, ${before_bytes} bytes" >> "${LOG_FILE}"

# ----------------------------------------
# Run extraction
# ----------------------------------------
echo "[${timestamp_start}] Running extract_fmri.sh ..." >> "${LOG_FILE}"

set +e
"${EXTRACT_SCRIPT}" >> "${LOG_FILE}" 2>&1
exit_code=$?
set -e

timestamp_end="$(date -Iseconds)"
echo "[${timestamp_end}] extract_fmri.sh finished with exit code ${exit_code}" >> "${LOG_FILE}"

# ----------------------------------------
# Snapshot AFTER extraction
# ----------------------------------------
after_files=$(find "${RAW_ROOT}" -type f 2>/dev/null | wc -l || echo 0)
after_bytes=$(du -sb "${RAW_ROOT}" 2>/dev/null | awk '{print $1}' || echo 0)

new_files=$(( after_files - before_files ))
new_bytes=$(( after_bytes - before_bytes ))

new_bytes_hr="$(human_readable "${new_bytes#-0}")"  # handle 0 / negative gracefully
total_bytes_hr="$(human_readable "${after_bytes}")"

echo "[${timestamp_end}] AFTER:  ${after_files} files, ${after_bytes} bytes" >> "${LOG_FILE}"
echo "[${timestamp_end}] DELTA:  ${new_files} files, ${new_bytes} bytes (${new_bytes_hr})" >> "${LOG_FILE}"

# ----------------------------------------
# Decide whether to notify Slack
#   - If extract failed: send ERROR message.
#   - If success but no new files/size: NOTIFY NOTHING (your option B1).
#   - If success and new files/size: send SUCCESS message with metrics.
# ----------------------------------------

if (( exit_code != 0 )); then
  status="ERROR"
  color="#dc3545"   # red
elif (( new_files <= 0 && new_bytes <= 0 )); then
  # Option B1: no notification on "no new data"
  echo "[${timestamp_end}] No new files extracted. Skipping Slack notification." >> "${LOG_FILE}"
  exit 0
else
  status="SUCCESS"
  color="#36a64f"   # green
fi

# If Slack is not configured, just log and bail
if [[ -z "${SLACK_WEBHOOK}" ]]; then
  echo "[${timestamp_end}] SLACK_WEBHOOK not set. Skipping Slack notification." >> "${LOG_FILE}"
  exit 0
fi

# ----------------------------------------
# Build Slack text with metrics
# (use \n literals to keep JSON valid)
# ----------------------------------------
slack_text="*Nightly fMRI extraction – ${status}*"
slack_text+="\\nWindow: ${timestamp_start} → ${timestamp_end}"
slack_text+="\\nRaw root: \`${RAW_ROOT}\`"
slack_text+="\\nExtract script: \`${EXTRACT_SCRIPT}\`"
slack_text+="\\nBefore: ${before_files} files, $(human_readable "${before_bytes}")"
slack_text+="\\nAfter:  ${after_files} files, $(human_readable "${after_bytes}")"
slack_text+="\\nNew:    ${new_files} files, ${new_bytes_hr}"

if (( exit_code != 0 )); then
  slack_text+="\\n\\n:warning: *extract_fmri.sh exited with code ${exit_code}* – check \`${LOG_FILE}\` on the server."
fi

# ----------------------------------------
# Build JSON payload
# ----------------------------------------
payload=$(
  cat <<EOF
{
  "attachments": [
    {
      "color": "${color}",
      "mrkdwn_in": ["text"],
      "text": "${slack_text}"
    }
  ]
}
EOF
)

# ----------------------------------------
# Send to Slack
# ----------------------------------------
curl -sS -X POST \
  -H 'Content-type: application/json' \
  --data "${payload}" \
  "${SLACK_WEBHOOK}" >> "${LOG_FILE}" 2>&1 || {
    echo "[${timestamp_end}] Failed to send Slack notification." >> "${LOG_FILE}"
    # Don't fail the whole job just because Slack failed
    exit 0
  }

echo "[${timestamp_end}] Slack notification sent." >> "${LOG_FILE}"


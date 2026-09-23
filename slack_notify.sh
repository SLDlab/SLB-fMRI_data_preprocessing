#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="/data/sld/homes/collab/slb"
ENV_FILE="${ROOT_DIR}/.slb_env"

# ----------------------------------------
# Load Slack webhook
# ----------------------------------------
if [[ -f "${ENV_FILE}" ]]; then
    source "${ENV_FILE}"
fi

SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

if [[ -z "${SLACK_WEBHOOK}" ]]; then
    echo "ERROR: SLACK_WEBHOOK is not set." >&2
    exit 1
fi

# ----------------------------------------
# Arguments
#
# Usage:
#   slack_notify.sh success "Title" "Message"
#
# Status:
#   success
#   error
#   warning
#   info
# ----------------------------------------
STATUS="${1:-info}"
TITLE="${2:-SLB Pipeline}"
MESSAGE="${3:-}"

case "${STATUS}" in
    success)
        COLOR="#36a64f"
        ICON=":white_check_mark:"
        ;;
    error)
        COLOR="#dc3545"
        ICON=":x:"
        ;;
    warning)
        COLOR="#ffcc00"
        ICON=":warning:"
        ;;
    info)
        COLOR="#439FE0"
        ICON=":information_source:"
        ;;
    *)
        COLOR="#808080"
        ICON=":large_blue_circle:"
        ;;
esac

TIMESTAMP="$(date '+%Y-%m-%d %H:%M:%S %Z')"

TEXT="${ICON} *${TITLE}*

${MESSAGE}

_Time: ${TIMESTAMP}_"

# ----------------------------------------
# Send message
# ----------------------------------------
python3 - "${SLACK_WEBHOOK}" "${COLOR}" "${TEXT}" <<'PY'
import json
import sys
import urllib.request

url, color, text = sys.argv[1:4]

payload = {
    "attachments": [
        {
            "color": color,
            "mrkdwn_in": ["text"],
            "text": text,
        }
    ]
}

req = urllib.request.Request(
    url,
    data=json.dumps(payload).encode("utf-8"),
    headers={"Content-Type": "application/json"},
)

try:
    with urllib.request.urlopen(req, timeout=10) as response:
        if response.status < 200 or response.status >= 300:
            raise RuntimeError(
                f"Slack returned HTTP status {response.status}"
            )

        print(f"Slack notification sent successfully ({response.status}).")

except Exception as exc:
    print(f"ERROR: Slack notification failed: {exc}", file=sys.stderr)
    sys.exit(1)
PY

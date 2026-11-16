#!/usr/bin/env bash

# Do not use `set -e` here.
# Every important failure is handled explicitly so cron cannot exit silently.
set -u
set -o pipefail

ROOT_DIR="/data/sld/homes/collab/slb"
ENV_FILE="${ROOT_DIR}/.slb_env"

# ============================================================
# Load Slack webhook
# ============================================================

if [[ ! -r "${ENV_FILE}" ]]; then
    echo "ERROR: Cannot read ${ENV_FILE}" >&2
    exit 1
fi

if ! source "${ENV_FILE}"; then
    echo "ERROR: Failed to load ${ENV_FILE}" >&2
    exit 1
fi

SLACK_WEBHOOK="${SLACK_WEBHOOK:-}"

if [[ -z "${SLACK_WEBHOOK}" ]]; then
    echo "ERROR: SLACK_WEBHOOK is not set." >&2
    exit 1
fi

# Make webhook available to Python without placing it on the command line.
export SLACK_WEBHOOK


# ============================================================
# Generic Slack sender
# ============================================================

send_slack() {
    local color="$1"
    local text="$2"

    python3 - "${color}" "${text}" <<'PY'
import json
import os
import sys
import time
import urllib.request

color, text = sys.argv[1:3]
url = os.environ["SLACK_WEBHOOK"]

payload = {
    "attachments": [
        {
            "color": color,
            "mrkdwn_in": ["text"],
            "text": text,
        }
    ]
}

data = json.dumps(payload).encode("utf-8")

last_error = None

for attempt in range(1, 4):
    req = urllib.request.Request(
        url,
        data=data,
        headers={"Content-Type": "application/json"},
    )

    try:
        with urllib.request.urlopen(req, timeout=15) as response:
            status = response.status

            if 200 <= status < 300:
                print(
                    f"Slack notification sent successfully "
                    f"(HTTP {status}, attempt {attempt})."
                )
                sys.exit(0)

            last_error = RuntimeError(
                f"Slack returned HTTP status {status}"
            )

    except Exception as exc:
        last_error = exc
        print(
            f"WARNING: Slack attempt {attempt}/3 failed: {exc}",
            file=sys.stderr,
        )

    if attempt < 3:
        time.sleep(10)

print(
    f"ERROR: Slack notification failed after 3 attempts: {last_error}",
    file=sys.stderr,
)
sys.exit(1)
PY
}


# ============================================================
# Weekly fMRIPrep summary
# ============================================================

if [[ "${1:-}" == "weekly_fmriprep" ]]; then

    echo "===== weekly_fmriprep started: $(date) ====="

    python3 <<'PY'
import json
import os
import sys
import time
import urllib.request
from datetime import datetime
from pathlib import Path


ROOT = Path("/data/sld/homes/collab/slb")

FMRIPREP_DIR = ROOT / "derivatives" / "fmriprep_runs"
READY_DIR = ROOT / "state" / "ready"

STATE_DIR = ROOT / "state" / "notifications"
STATE_FILE = STATE_DIR / "weekly_fmriprep_completed.txt"

WEBHOOK = os.environ.get("SLACK_WEBHOOK", "")


def fail(message):
    print(f"ERROR: {message}", file=sys.stderr)
    sys.exit(1)


# ------------------------------------------------------------
# Validate required paths/environment
# ------------------------------------------------------------

if not WEBHOOK:
    fail("SLACK_WEBHOOK is not available to weekly notifier.")

if not FMRIPREP_DIR.is_dir():
    fail(f"fMRIPrep directory does not exist: {FMRIPREP_DIR}")

if not READY_DIR.is_dir():
    fail(f"Ready directory does not exist: {READY_DIR}")

try:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
except Exception as exc:
    fail(f"Cannot create/access state directory {STATE_DIR}: {exc}")


# ------------------------------------------------------------
# Current completed participants
#
# Completion checkpoint:
# non-empty derivatives/fmriprep_runs/sub-XXX.html
# ------------------------------------------------------------

try:
    current_completed = sorted(
        {
            path.stem
            for path in FMRIPREP_DIR.glob("sub-*.html")
            if path.is_file() and path.stat().st_size > 0
        }
    )
except Exception as exc:
    fail(f"Could not scan completed fMRIPrep reports: {exc}")

print(f"Completed fMRIPrep reports found: {len(current_completed)}")


# ------------------------------------------------------------
# Previous successful weekly baseline
# ------------------------------------------------------------

if STATE_FILE.exists():
    try:
        previous_completed = sorted(
            {
                line.strip()
                for line in STATE_FILE.read_text().splitlines()
                if line.strip()
            }
        )
    except Exception as exc:
        fail(f"Could not read baseline {STATE_FILE}: {exc}")

    print(
        f"Previous weekly baseline contains: "
        f"{len(previous_completed)} participants"
    )
else:
    previous_completed = []
    print("No previous weekly baseline exists.")


# ------------------------------------------------------------
# Newly completed participants
# ------------------------------------------------------------

current_set = set(current_completed)
previous_set = set(previous_completed)

new_completed = sorted(current_set - previous_set)


# ------------------------------------------------------------
# Ready participants
# ------------------------------------------------------------

try:
    ready_subjects = sorted(
        {
            path.stem
            for path in READY_DIR.glob("sub-*.ready")
            if path.is_file()
        }
    )
except Exception as exc:
    fail(f"Could not scan ready markers: {exc}")

ready_set = set(ready_subjects)

pending_subjects = sorted(ready_set - current_set)


# ------------------------------------------------------------
# Format Slack message
# ------------------------------------------------------------

if new_completed:
    new_text = "\n".join(f"• {subject}" for subject in new_completed)
else:
    new_text = "• None"

if pending_subjects:
    pending_text = "\n".join(
        f"• {subject}" for subject in pending_subjects
    )
else:
    pending_text = "• None"

timestamp = datetime.now().astimezone().strftime(
    "%Y-%m-%d %H:%M:%S %Z"
)

text = f""":white_check_mark: *SLB Weekly fMRI Pipeline Summary*

*New fMRIPrep completions: {len(new_completed)}*
{new_text}

*Total fMRIPrep completed: {len(current_completed)}*

*Ready but still pending: {len(pending_subjects)}*
{pending_text}

_Time: {timestamp}_"""


# ------------------------------------------------------------
# Send Slack with retries
# ------------------------------------------------------------

payload = {
    "attachments": [
        {
            "color": "#36a64f",
            "mrkdwn_in": ["text"],
            "text": text,
        }
    ]
}

data = json.dumps(payload).encode("utf-8")

last_error = None
sent = False

for attempt in range(1, 4):
    request = urllib.request.Request(
        WEBHOOK,
        data=data,
        headers={"Content-Type": "application/json"},
    )

    try:
        with urllib.request.urlopen(
            request,
            timeout=15,
        ) as response:

            status = response.status

            if 200 <= status < 300:
                print(
                    f"Slack notification sent successfully "
                    f"(HTTP {status}, attempt {attempt})."
                )
                sent = True
                break

            last_error = RuntimeError(
                f"Slack returned HTTP status {status}"
            )

    except Exception as exc:
        last_error = exc

        print(
            f"WARNING: Slack attempt {attempt}/3 failed: {exc}",
            file=sys.stderr,
        )

    if attempt < 3:
        time.sleep(10)

if not sent:
    fail(
        f"Slack notification failed after 3 attempts: "
        f"{last_error}"
    )


# ------------------------------------------------------------
# Update baseline ONLY after successful Slack delivery
#
# Write to temporary file first, then atomically replace.
# ------------------------------------------------------------

temp_state = STATE_DIR / (
    f".weekly_fmriprep_completed.{os.getpid()}.tmp"
)

try:
    content = "\n".join(current_completed)

    if content:
        content += "\n"

    temp_state.write_text(content)

    # Preserve collaborative write permissions.
    temp_state.chmod(0o664)

    os.replace(temp_state, STATE_FILE)

except Exception as exc:
    try:
        if temp_state.exists():
            temp_state.unlink()
    except Exception:
        pass

    fail(
        "Slack was sent, but baseline could not be updated: "
        f"{exc}"
    )

print(
    f"Weekly baseline updated successfully: "
    f"{len(current_completed)} participants"
)

print(
    f"New completions reported: {len(new_completed)}"
)

print(
    f"Ready but pending: {len(pending_subjects)}"
)

sys.exit(0)
PY

    rc=$?

    echo "weekly_fmriprep exit_status=${rc}"
    echo "===== weekly_fmriprep finished: $(date) ====="

    exit "${rc}"
fi


# ============================================================
# Generic notifications
#
# Usage:
#   slack_notify.sh success "Title" "Message"
#
# Status:
#   success
#   error
#   warning
#   info
# ============================================================

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

send_slack "${COLOR}" "${TEXT}"

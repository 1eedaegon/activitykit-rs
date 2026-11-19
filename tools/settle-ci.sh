#!/usr/bin/env bash
# Waits for a CI run and runs again the jobs that no runner took.
#
# GitHub's hosted macOS runners are short at times. A job that none of them takes within 15 minutes ends as cancelled,
# with the annotation "The job was not acquired by Runner of type hosted even after multiple attempts", and its run as
# a failure, though nothing of the repository failed. A release then stopped until somebody ran the job again.
#
#   settle-ci.sh verdict       reads a run's jobs on stdin, [{name, conclusion, annotations: [text]}], and prints
#                              `passed`, `starved` (every job that did not pass is such a job) or `failed`
#   settle-ci.sh jobs <run>    prints that document for a run
#   settle-ci.sh settle <run>  waits for the run and, while it is starved, runs its failed jobs again, at most RERUNS
#                              times (3); exits 0 once the run passed and 1 otherwise
#
# `jobs` and `settle` need `gh` with a token that may read and rerun the runs (GH_TOKEN) and GITHUB_REPOSITORY.
set -euo pipefail

reruns=${RERUNS:-3}
# Seconds between two looks at a run.
pause=${SETTLE_PAUSE:-15}
no_runner='was not acquired by Runner'

verdict() {
  python3 -I -c '
import json, sys

no_runner = sys.argv[1]
jobs = json.load(sys.stdin)
left = [job for job in jobs if job.get("conclusion") not in ("success", "skipped")]

def starved(job):
    return job.get("conclusion") == "cancelled" and any(no_runner in note for note in job.get("annotations", []))

if not jobs:
    print("failed")
elif not left:
    print("passed")
else:
    print("starved" if all(starved(job) for job in left) else "failed")
' "$no_runner"
}

jobs() {
  python3 -I -c '
import json, subprocess, sys

repository, run = sys.argv[1:3]

def api(path):
    return json.loads(subprocess.run(["gh", "api", path], check=True, capture_output=True, text=True).stdout)

document = []
for job in api(f"repos/{repository}/actions/runs/{run}/jobs?filter=latest&per_page=100")["jobs"]:
    notes = []
    if job.get("conclusion") not in ("success", "skipped"):
        check = job["id"]
        notes = [note.get("message") or "" for note in api(f"repos/{repository}/check-runs/{check}/annotations")]
    document.append({"name": job["name"], "conclusion": job.get("conclusion"), "annotations": notes})
json.dump(document, sys.stdout)
' "${GITHUB_REPOSITORY:?}" "$1"
}

status() {
  gh run view "$1" --repo "${GITHUB_REPOSITORY:?}" --json status | python3 -I -c 'import json, sys; print(json.load(sys.stdin)["status"])'
}

settle() {
  local run=$1 attempt=0 state
  while :; do
    if gh run watch "$run" --repo "${GITHUB_REPOSITORY:?}" --exit-status --interval "$pause" >/dev/null; then
      echo "run $run passed"
      return 0
    fi
    state=$(jobs "$run" | verdict)
    case "$state" in
      passed) echo "run $run passed"; return 0 ;;
      starved) ;;
      *) echo "run $run failed"; return 1 ;;
    esac
    if [ "$attempt" -ge "$reruns" ]; then
      echo "no runner took a job of run $run, also not in $reruns reruns"
      return 1
    fi
    attempt=$((attempt + 1))
    echo "no runner took a job of run $run: running its failed jobs again ($attempt of $reruns)"
    gh run rerun "$run" --repo "$GITHUB_REPOSITORY" --failed
    # The run reads as completed until GitHub has registered the new attempt.
    for _ in $(seq 1 20); do
      [ "$(status "$run")" = completed ] || break
      sleep "$pause"
    done
  done
}

case "${1:-}" in
  verdict) verdict ;;
  jobs) jobs "${2:?a run}" ;;
  settle) settle "${2:?a run}" ;;
  *) echo "usage: settle-ci.sh verdict | jobs <run> | settle <run>" >&2; exit 2 ;;
esac

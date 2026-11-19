#!/usr/bin/env bash
# Tests for tools/settle-ci.sh: its verdict on a run's jobs, and its waiting and rerunning against a `gh` that this
# script plays. Nothing here reaches GitHub.
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
tool=$root/tools/settle-ci.sh
work=$(mktemp -d "${TMPDIR:-/tmp}/activitykit-settle.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
tests=0

fail() {
  echo "FAIL $*" >&2
  exit 1
}

# What GitHub writes on a job that no hosted runner took within its 15 minutes.
no_runner='The job was not acquired by Runner of type hosted even after multiple attempts'
passed_job='{"name":"Rust (Linux)","conclusion":"success","annotations":[]}'
skipped_job='{"name":"Specification and docs","conclusion":"skipped","annotations":[]}'
starved_job="{\"name\":\"Swift and the iOS builds (macOS)\",\"conclusion\":\"cancelled\",\"annotations\":[\"$no_runner\",\"Due to capacity constraints, jobs targeting macOS arm64 runners may experience longer queue times.\"]}"
failed_job='{"name":"End to end on the simulator (macOS)","conclusion":"failure","annotations":["Process completed with exit code 65."]}'
stopped_job='{"name":"Swift and the iOS builds (macOS)","conclusion":"cancelled","annotations":["The operation was canceled."]}'
running_job='{"name":"Rust (Linux)","conclusion":null,"annotations":[]}'

expect_verdict() {
  local name=$1 want=$2 jobs=$3 got
  got=$(printf '%s' "$jobs" | bash "$tool" verdict)
  [ "$got" = "$want" ] || fail "$name: $got, not $want"
  tests=$((tests + 1))
}

expect_verdict "every job passed or was skipped" passed "[$passed_job,$skipped_job]"
expect_verdict "the one job that did not pass found no runner" starved "[$passed_job,$skipped_job,$starved_job]"
expect_verdict "two jobs found no runner" starved "[$starved_job,$starved_job,$passed_job]"
expect_verdict "a job failed" failed "[$passed_job,$failed_job]"
expect_verdict "a job found no runner and another failed" failed "[$starved_job,$failed_job]"
expect_verdict "a job was cancelled by hand" failed "[$passed_job,$stopped_job]"
expect_verdict "a job has no conclusion yet" failed "[$running_job,$passed_job]"
expect_verdict "a run without jobs" failed "[]"

# A `gh` for `settle`: `gh run watch` exits with the next line of $work/watch, `gh api` answers from $work/jobs.json
# and $work/annotations.json, `gh run view` says in_progress, and every `gh run rerun` is a line in $work/reruns.
mkdir -p "$work/bin"
cat > "$work/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  "run watch")
    code=$(head -n 1 "$STATE/watch")
    tail -n +2 "$STATE/watch" > "$STATE/watch.rest" && mv "$STATE/watch.rest" "$STATE/watch"
    exit "${code:-1}" ;;
  "run rerun") echo "$*" >> "$STATE/reruns" ;;
  "run view") echo '{"status":"in_progress"}' ;;
  "api "*)
    case "$2" in
      */actions/runs/*/jobs*) cat "$STATE/jobs.json" ;;
      */check-runs/*/annotations) cat "$STATE/annotations.json" ;;
      *) echo "unexpected gh api $2" >&2; exit 2 ;;
    esac ;;
  *) echo "unexpected gh $*" >&2; exit 2 ;;
esac
GH
chmod +x "$work/bin/gh"

# settle <watch exit codes> <a job's conclusion> <its annotation>: the exit code of `settle` and its reruns.
settle() {
  local codes=$1 conclusion=$2 note=$3
  printf '%s\n' $codes > "$work/watch"
  : > "$work/reruns"
  printf '{"jobs":[{"id":1,"name":"Rust (Linux)","conclusion":"success"},{"id":2,"name":"Swift and the iOS builds (macOS)","conclusion":"%s"}]}' "$conclusion" > "$work/jobs.json"
  printf '[{"message":"%s"}]' "$note" > "$work/annotations.json"
  exit_code=0
  PATH="$work/bin:$PATH" STATE="$work" GITHUB_REPOSITORY=owner/repo SETTLE_PAUSE=0 bash "$tool" settle 42 > "$work/output" 2>&1 || exit_code=$?
  reruns=$(wc -l < "$work/reruns" | tr -d ' ')
}

expect_settle() {
  local name=$1 want_exit=$2 want_reruns=$3
  [ "$exit_code" = "$want_exit" ] || fail "$name: exit $exit_code, not $want_exit: $(cat "$work/output")"
  [ "$reruns" = "$want_reruns" ] || fail "$name: $reruns reruns, not $want_reruns: $(cat "$work/output")"
  tests=$((tests + 1))
}

settle "0" success ""
expect_settle "a run that passes is left alone" 0 0

settle "1 0" cancelled "$no_runner"
expect_settle "a run whose job found no runner is run again and passes" 0 1
grep -q -- '--failed' "$work/reruns" || fail "only the jobs that did not pass are run again: $(cat "$work/reruns")"
tests=$((tests + 1))

settle "1 1 0" cancelled "$no_runner"
expect_settle "it is run again a second time" 0 2

settle "1 1 1 1 1" cancelled "$no_runner"
expect_settle "after three reruns without a runner it gives up" 1 3

settle "1" failure "Process completed with exit code 65."
expect_settle "a run that failed is not run again" 1 0

settle "1" cancelled "The operation was canceled."
expect_settle "a run that was cancelled by hand is not run again" 1 0

echo "settle-ci: $tests checks passed"

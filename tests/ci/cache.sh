#!/bin/sh
# What CI keeps between runs (.github/workflows/ci.yml): the keys of its caches, and records of the suites that passed.
#
#   cache.sh keys SUITE...        For each suite (simulator, swift or build) writes SUITE=NAME, the name of the record
#                                 that a pass for these exact inputs leaves. For the simulator also runtime=ID (the
#                                 simulator runtime it tests on) and products=KEY (the cache of the test host's Xcode
#                                 products).
#   cache.sh passed NAME          Looks for the record NAME that a run of this repository's CI left and prints that
#                                 run. Writes found=true or found=false.
#   cache.sh record SUITE [FILE]  Writes the record of this run's pass to $RUNNER_TEMP/passed-SUITE/. FILE is the list
#                                 of retried tests that tests/ios-host/run.sh leaves after a full pass; without it the
#                                 suite did not pass in full, and nothing is written. Writes recorded=true or false.
#
# Outputs go to $GITHUB_OUTPUT (standard output when it is not set). The inputs of a suite are the files it reads as git
# tracks them (nothing generated or ignored counts), the Xcode version, the runner's system, architecture and image
# ($ImageOS, $ImageVersion), and for the build checks and the simulator the Rust toolchain ($TOOLCHAIN); for the
# simulator also its runtime. The products key leaves out the image: Xcode and the toolchain decide what is built.
#
# A record is an artifact, not a cache: a push to main cannot restore the caches of a pull request, but it can find the
# artifact that the pull request's run left. Only runs of this repository's ci.yml count, not runs of a fork.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
# Raise to start every key and record afresh.
version=1
temp=${RUNNER_TEMP:-${TMPDIR:-/tmp}}

put() { printf '%s\n' "$1" >>"${GITHUB_OUTPUT:-/dev/stdout}"; }

# A hash of the tracked files that a suite reads: their paths, modes and contents.
files() {
  case $1 in
    simulator) set -- src swift build.rs Cargo.toml Cargo.lock rust-toolchain.toml .cargo templates contracts \
      tests/ios-host ':(exclude)tests/ios-host/output' ;;
    swift) set -- swift tests/swift tests/fixtures ;;
    build) set -- src swift build.rs Cargo.toml Cargo.lock rust-toolchain.toml .cargo tests/build ;;
  esac
  list=$(git -C "$root" ls-files --stage -- "$@")
  [ -n "$list" ] || { echo "git lists no files for $1" >&2; exit 1; }
  printf '%s\n' "$list" | git hash-object --stdin
}

# The newest iOS simulator runtime, read from CoreSimulator's list of runtime images: the first simctl call on a fresh
# runner starts CoreSimulator, which took from 18 s to 2 minutes. simctl's newest available iOS when no image lists one.
newest_runtime() {
  images=/Library/Developer/CoreSimulator/Images/images.plist
  if [ -r "$images" ]; then
    python3 -I - "$images" <<'PYTHON'
import plistlib, re, sys
with open(sys.argv[1], "rb") as file:
    images = plistlib.load(file).get("images", [])
found = []
for image in images:
    identifier = image.get("runtimeInfo", {}).get("bundleIdentifier", "")
    match = re.fullmatch(r"com\.apple\.CoreSimulator\.SimRuntime\.iOS-(\d+)-(\d+)(?:-(\d+))?", identifier)
    if match:
        found.append((tuple(int(part or 0) for part in match.groups()), identifier))
if found:
    print(max(found)[1])
PYTHON
  fi | grep . || xcrun simctl list runtimes | awk '/^iOS/ && !/unavailable/ { id = $NF } END { print id }'
}

keys() {
  xcode=$(xcodebuild -version | awk '/^Xcode / { v = $2 } /^Build version / { b = $3 } END { print v "-" b }')
  system=${RUNNER_OS:-$(uname -s)}-${RUNNER_ARCH:-$(uname -m)}
  for suite in "$@"; do
    case $suite in simulator | swift | build) ;; *) echo "unknown suite: $suite" >&2; exit 2 ;; esac
    hash=$(files "$suite")
    inputs="version $version
suite $suite
files $hash
xcode $xcode
runner $system ${ImageOS:-local} ${ImageVersion:-local}"
    if [ "$suite" != swift ]; then
      inputs="$inputs
rust ${TOOLCHAIN:?TOOLCHAIN names the Rust toolchain}"
    fi
    if [ "$suite" = simulator ]; then
      # CI passes it on to tests/ios-host/run.sh as RUNTIME.
      runtime=${RUNTIME:-$(newest_runtime)}
      [ -n "$runtime" ] || { echo "no iOS simulator runtime" >&2; exit 1; }
      inputs="$inputs
runtime $runtime"
      put "runtime=$runtime"
      put "products=simulator-products-v$version-$system-xcode$xcode-rust$TOOLCHAIN-$hash"
    fi
    printf '%s\n' "$inputs" >"$temp/inputs-$suite.txt"
    name=passed-$suite-$(git hash-object --stdin <"$temp/inputs-$suite.txt")
    printf '%s, from:\n%s\n' "$name" "$inputs" >&2
    put "$suite=$name"
  done
}

passed() {
  name=$1
  repository=${GITHUB_REPOSITORY:?GITHUB_REPOSITORY names the repository}
  server=${GITHUB_SERVER_URL:-https://github.com}
  # The records of that name that have not expired, newest first, from runs of this repository and not of a fork.
  if ! records=$(gh api "repos/$repository/actions/artifacts?name=$name&per_page=100" --jq '.artifacts
      | map(select((.expired | not) and .workflow_run.head_repository_id == .workflow_run.repository_id))
      | sort_by(.created_at) | reverse | .[] | "\(.id) \(.workflow_run.id)"'); then
    echo "::warning title=Test results not looked up::GitHub's artifact API failed, so the suite runs"
    put found=false
    return
  fi
  work=$(mktemp -d "$temp/passed.XXXXXX")
  # Word splitting into pairs of artifact and run IDs, which are plain numbers.
  # shellcheck disable=SC2086
  set -- $records
  while [ $# -ge 2 ]; do
    artifact=$1 run=$2
    shift 2
    workflow=$(gh api "repos/$repository/actions/runs/$run" --jq .path) || continue
    [ "$workflow" = .github/workflows/ci.yml ] || continue
    gh api "repos/$repository/actions/artifacts/$artifact/zip" >"$work/record.zip" || continue
    unzip -p "$work/record.zip" passed.txt >"$work/passed.txt" 2>/dev/null || continue
    url=$server/$repository/actions/runs/$run
    echo "$name: the suite passed for these inputs in $url"
    cat "$work/passed.txt"
    sed -n 's/^retried //p' "$work/passed.txt" | while read -r test; do
      echo "::warning title=Retried UI test::$test failed once and passed on a retry in $url"
    done
    echo "::notice title=Passed before::$name: skipped, the suite passed for the same inputs in $url"
    rm -rf "$work"
    put found=true
    put "run=$url"
    return
  done
  rm -rf "$work"
  echo "$name: no run has passed these inputs yet"
  put found=false
}

record() {
  suite=$1
  if [ $# -ge 2 ] && [ ! -f "$2" ]; then
    echo "$suite did not pass in full: no record"
    put recorded=false
    return
  fi
  dir=$temp/passed-$suite
  mkdir -p "$dir"
  { cat "$temp/inputs-$suite.txt"
    echo "run ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-local}/actions/runs/${GITHUB_RUN_ID:-0} attempt ${GITHUB_RUN_ATTEMPT:-1}"
    echo "commit ${GITHUB_SHA:-$(git -C "$root" rev-parse HEAD)} ${GITHUB_REF:-}"
    if [ $# -ge 2 ]; then awk '{ print "retried " $0 }' "$2"; fi
  } >"$dir/passed.txt"
  cat "$dir/passed.txt"
  put recorded=true
}

command=${1:-}
[ $# -eq 0 ] || shift
case $command in
  keys) keys "$@" ;;
  passed) passed "$1" ;;
  record) record "$@" ;;
  *) echo "usage: cache.sh keys SUITE... | passed NAME | record SUITE [FILE]" >&2; exit 2 ;;
esac

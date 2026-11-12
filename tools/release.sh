#!/usr/bin/env bash
# Plans a release from the conventional subjects of the commits since the last tag and writes the files a release
# changes: the crate's version in Cargo.toml and in both lock files, the dependency line of the README and the
# changelog. tests/release/run.sh runs it in repositories of its own; .github/workflows/auto-release.yml runs it on main.
#
#   feat                                -> minor        fix, perf, refactor, docs, revert -> patch
#   test, ci, chore, build, style       -> no release   `!` or a BREAKING CHANGE footer   -> major, only with --major
#
# Before 1.0 a change that breaks callers is a `feat`: the minor moves, which is how Cargo reads a 0.x version.
set -euo pipefail

root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
temporary=$(mktemp -d "${TMPDIR:-/tmp}/activitykit-release-tool.XXXXXX")
trap 'rm -rf "$temporary"' EXIT HUP INT TERM

die() {
  if [[ ${GITHUB_ACTIONS:-} == true ]]; then
    echo "::error::$*" >&2
  else
    echo "error: $*" >&2
  fi
  exit 2
}

is_version() {
  [[ $1 =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]
}

validate_version() {
  is_version "$1" || die "not a stable SemVer triple: $1"
}

compare_versions() {
  local left=$1 right=$2 left_major left_minor left_patch right_major right_minor right_patch index
  validate_version "$left"
  validate_version "$right"
  IFS=. read -r left_major left_minor left_patch <<< "$left"
  IFS=. read -r right_major right_minor right_patch <<< "$right"
  local -a left_parts=("$left_major" "$left_minor" "$left_patch")
  local -a right_parts=("$right_major" "$right_minor" "$right_patch")
  version_comparison=0
  for index in 0 1 2; do
    if ((10#${left_parts[$index]} < 10#${right_parts[$index]})); then
      version_comparison=-1
      return
    fi
    if ((10#${left_parts[$index]} > 10#${right_parts[$index]})); then
      version_comparison=1
      return
    fi
  done
}

bump_version() {
  local version=$1 level=$2 major minor patch
  validate_version "$version"
  IFS=. read -r major minor patch <<< "$version"
  case $level in
    1) bumped_version="$major.$minor.$((patch + 1))" ;;
    2) bumped_version="$major.$((minor + 1)).0" ;;
    3) bumped_version="$((major + 1)).0.0" ;;
    *) die "cannot bump $version by level $level" ;;
  esac
}

latest_stable_tag() {
  local tag candidate
  latest_tag=
  latest_version=
  while IFS= read -r tag; do
    candidate=${tag#v}
    is_version "$candidate" || continue
    if [[ -z $latest_version ]]; then
      latest_tag=$tag
      latest_version=$candidate
      continue
    fi
    compare_versions "$candidate" "$latest_version"
    if ((version_comparison > 0)); then
      latest_tag=$tag
      latest_version=$candidate
    fi
  done < <(git tag --merged HEAD --list 'v*')
  [[ -n $latest_tag ]] || die 'no stable vMAJOR.MINOR.PATCH tag is merged into HEAD'
}

manifest_version() {
  current_version=$(awk '
    /^\[package\]$/ { package = 1; next }
    /^\[/ { package = 0 }
    package && /^version = "/ {
      value = $0
      sub(/^version = "/, "", value)
      sub(/"$/, "", value)
      print value
      found++
    }
    END { if (found != 1) exit 1 }
  ' Cargo.toml) || die 'Cargo.toml must have exactly one package version'
  validate_version "$current_version"
}

classify_commit() {
  local sha=$1 parent_line subject kind body
  local -a parent_fields
  parent_line=$(git show -s --format='%H %P' "$sha")
  read -r -a parent_fields <<< "$parent_line"
  class_bump=0
  class_breaking=false
  class_note=true
  if ((${#parent_fields[@]} > 2)); then
    class_note=false
    return
  fi
  subject=$(git show -s --format=%s "$sha")
  if [[ $subject =~ ^chore:\ release\ v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    class_note=false
    return
  fi
  if [[ ! $subject =~ ^(feat|fix|perf|refactor|docs|revert|test|ci|chore|build|style)(\([^()]+\))?(!)?:[[:space:]]+([^[:space:]].*)$ ]]; then
    die "${sha:0:7} has a non-conventional subject: $subject"
  fi
  kind=${BASH_REMATCH[1]}
  case $kind in
    feat) class_bump=2 ;;
    fix|perf|refactor|docs|revert) class_bump=1 ;;
    test|ci|chore|build|style) class_bump=0 ;;
  esac
  [[ -n ${BASH_REMATCH[3]} ]] && class_breaking=true
  body=$(git show -s --format=%b "$sha")
  if grep -Eq '^BREAKING( CHANGE|-CHANGE):[[:space:]]*[^[:space:]]' <<< "$body"; then
    class_breaking=true
  fi
}

load_commits() {
  commits_file=$temporary/commits
  git rev-list --reverse "$latest_tag..HEAD" > "$commits_file"
}

analyze_commits() {
  local sha body release_subject="chore: release v$current_version"
  real_commits=0
  highest=0
  breaking=false
  major_marker=false
  while IFS= read -r sha; do
    [[ -n $sha ]] || continue
    classify_commit "$sha"
    ((class_bump > highest)) && highest=$class_bump
    [[ $class_breaking == true ]] && breaking=true
    if [[ $class_note == true ]]; then
      real_commits=$((real_commits + 1))
    fi
    if [[ $(git show -s --format=%s "$sha") == "$release_subject" ]]; then
      body=$(git show -s --format=%b "$sha")
      grep -Fxq 'Release-Mode: manual-major' <<< "$body" && major_marker=true
    fi
  done < "$commits_file"
  return 0
}

plan_ahead_version() {
  bump_version "$latest_version" 3
  if [[ $current_version == "$bumped_version" && $major_marker == true ]]; then
    plan_action=tag
    plan_version=$current_version
    return
  fi
  [[ $breaking == false ]] || die 'breaking commit found; dispatch a manual major release'
  ((highest > 0)) || die "Cargo.toml advanced to $current_version without a release-bearing commit"
  bump_version "$latest_version" "$highest"
  [[ $current_version == "$bumped_version" ]] || \
    die "Cargo.toml advanced to $current_version; commit subjects require $bumped_version"
  plan_action=tag
  plan_version=$current_version
}

plan_current_version() {
  local manual_major=$1
  if [[ $manual_major == true ]]; then
    ((real_commits > 0)) || { plan_action=none; plan_version=; return; }
    bump_version "$latest_version" 3
    plan_action=prepare
    plan_version=$bumped_version
    return
  fi
  [[ $breaking == false ]] || die 'breaking commit found; dispatch a manual major release'
  if ((highest == 0)); then
    plan_action=none
    plan_version=
    return
  fi
  bump_version "$latest_version" "$highest"
  plan_action=prepare
  plan_version=$bumped_version
}

compute_plan() {
  local manual_major=$1
  latest_stable_tag
  manifest_version
  load_commits
  analyze_commits
  compare_versions "$current_version" "$latest_version"
  ((version_comparison >= 0)) || die "Cargo.toml $current_version is behind the latest tag $latest_tag"
  if ((version_comparison > 0)); then
    plan_ahead_version
  else
    plan_current_version "$manual_major"
  fi
}

emit_plan() {
  local tag=
  [[ -n $plan_version ]] && tag=v$plan_version
  printf 'action=%s\nversion=%s\ntag=%s\nprevious_tag=%s\n' \
    "$plan_action" "$plan_version" "$tag" "$latest_tag"
  if [[ -n ${GITHUB_OUTPUT:-} ]]; then
    printf 'action=%s\nversion=%s\ntag=%s\nprevious_tag=%s\n' \
      "$plan_action" "$plan_version" "$tag" "$latest_tag" >> "$GITHUB_OUTPUT"
  fi
}

rewrite_manifest() {
  local old=$1 new=$2 output=$3
  awk -v old="$old" -v new="$new" '
    /^\[package\]$/ { package = 1 }
    /^\[/ && $0 != "[package]" { package = 0 }
    package && $0 == "version = \"" old "\"" { print "version = \"" new "\""; changed++; next }
    { print }
    END { if (changed != 1) { print "Cargo.toml package version replacement count: " changed > "/dev/stderr"; exit 1 } }
  ' Cargo.toml > "$output" || die 'could not update Cargo.toml safely'
}

rewrite_lock() {
  local path=$1 old=$2 new=$3 output=$4
  awk -v old="$old" -v new="$new" '
    /^\[\[package\]\]$/ { package = 0 }
    /^name = "activitykit"$/ { package = 1; packages++ }
    package && $0 == "version = \"" old "\"" { print "version = \"" new "\""; changed++; next }
    { print }
    END {
      if (packages != 1 || changed != 1) {
        print FILENAME " activitykit packages=" packages ", replacements=" changed > "/dev/stderr"
        exit 1
      }
    }
  ' "$path" > "$output" || die "could not update $path safely"
}

# The README names the dependency by its major and minor version.
rewrite_readme() {
  local old=$1 new=$2 output=$3
  awk -v old="${old%.*}" -v new="${new%.*}" '
    $0 == "activitykit = \"" old "\"" { print "activitykit = \"" new "\""; dependencies++; next }
    { print }
    END {
      if (dependencies != 1) {
        print "README dependency replacements=" dependencies > "/dev/stderr"
        exit 1
      }
    }
  ' README.md > "$output" || die 'could not update README.md safely'
}

build_changelog_section() {
  local version=$1 date=$2 sha subject notes=$temporary/changelog-section
  if awk -v version="$version" '$0 == "## " version || index($0, "## " version " ") == 1 { found = 1 } END { exit !found }' CHANGELOG.md; then
    die "CHANGELOG already contains $version"
  fi
  : > "$notes"
  printf '\n## %s - %s\n\n' "$version" "$date" >> "$notes"
  while IFS= read -r sha; do
    [[ -n $sha ]] || continue
    classify_commit "$sha"
    [[ $class_note == true ]] || continue
    subject=$(git show -s --format=%s "$sha")
    printf -- '- %s (%s%.7s%s)\n' "$subject" '`' "$sha" '`' >> "$notes"
  done < "$commits_file"
  [[ $(wc -l < "$notes" | tr -d ' ') -gt 3 ]] || die 'a release needs at least one changelog subject'
  changelog_section=$notes
}

rewrite_changelog() {
  local section=$1 output=$2
  awk -v section="$section" '
    $0 == "## Unreleased" {
      headings++
      print
      while ((getline line < section) > 0) print line
      close(section)
      next
    }
    { print }
    END { if (headings != 1) { print "Unreleased heading count: " headings > "/dev/stderr"; exit 1 } }
  ' CHANGELOG.md > "$output" || die 'could not update CHANGELOG.md safely'
}

prepare_release() {
  local wanted=$1 manual_major=$2 date=$3 generated=$temporary/generated
  validate_version "$wanted"
  [[ $date =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "not an ISO release date: $date"
  compute_plan "$manual_major"
  [[ $plan_action == prepare && $plan_version == "$wanted" ]] || \
    die "current plan is $plan_action ${plan_version:--}, not prepare $wanted"
  mkdir "$generated"
  rewrite_manifest "$current_version" "$wanted" "$generated/Cargo.toml"
  rewrite_lock Cargo.lock "$current_version" "$wanted" "$generated/Cargo.lock"
  # The simulator host has a workspace of its own, whose lock file names the crate by path and version.
  rewrite_lock tests/ios-host/Cargo.lock "$current_version" "$wanted" "$generated/ios-host.lock"
  rewrite_readme "$current_version" "$wanted" "$generated/README.md"
  build_changelog_section "$wanted" "$date"
  rewrite_changelog "$changelog_section" "$generated/CHANGELOG.md"
  chmod 0644 "$generated"/*
  mv "$generated/Cargo.toml" Cargo.toml
  mv "$generated/Cargo.lock" Cargo.lock
  mv "$generated/ios-host.lock" tests/ios-host/Cargo.lock
  mv "$generated/README.md" README.md
  mv "$generated/CHANGELOG.md" CHANGELOG.md
}

release_notes() {
  local version=$1 count
  validate_version "$version"
  count=$(awk -v plain="## $version" -v heading="## $version - " '$0 == plain || index($0, heading) == 1 { count++ } END { print count + 0 }' CHANGELOG.md)
  [[ $count == 1 ]] || die "CHANGELOG has $count release-note sections for $version"
  awk -v plain="## $version" -v heading="## $version - " '
    $0 == plain || index($0, heading) == 1 { found = 1; next }
    found && /^## / { exit }
    found { lines[++count] = $0 }
    END {
      first = 1
      while (first <= count && lines[first] == "") first++
      last = count
      while (last >= first && lines[last] == "") last--
      if (last < first) exit 1
      for (cursor = first; cursor <= last; cursor++) print lines[cursor]
    }
  ' CHANGELOG.md || die "CHANGELOG notes for $version are empty"
}

usage() {
  echo 'usage: tools/release.sh plan [--major]' >&2
  echo '       tools/release.sh prepare VERSION [--major] [--date YYYY-MM-DD]' >&2
  echo '       tools/release.sh notes VERSION' >&2
  exit 2
}

cd "$root"
command=${1-}
[[ -n $command ]] || usage
shift
case $command in
  plan)
    manual_major=false
    if (($# > 0)); then
      [[ $# == 1 && $1 == --major ]] || usage
      manual_major=true
    fi
    compute_plan "$manual_major"
    emit_plan
    ;;
  prepare)
    (($# > 0)) || usage
    wanted=$1
    shift
    manual_major=false
    release_date=$(date -u +%F)
    while (($# > 0)); do
      case $1 in
        --major) manual_major=true; shift ;;
        --date) (($# >= 2)) || usage; release_date=$2; shift 2 ;;
        *) usage ;;
      esac
    done
    prepare_release "$wanted" "$manual_major" "$release_date"
    ;;
  notes)
    [[ $# == 1 ]] || usage
    release_notes "$1"
    ;;
  *) usage ;;
esac

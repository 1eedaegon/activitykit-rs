#!/bin/sh
# Checks that docs/spec.md and the tests agree. It fails when
#   - a requirement has no row in the spec's test table, or the row names no test;
#   - a test in the table does not exist (file and function), or its file does not name the requirement;
#   - a requirement is named by no test file, or a test file names an ID the spec does not define.
# Test files: everything under tests/, src/**/tests.rs, src/**/*_tests.rs, and of other src files the `mod tests` part
# and the doctests of the rustdoc.
set -eu
root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
exec python3 -I - "$root" <<'PYTHON'
import pathlib, re, sys
from collections import Counter

root = pathlib.Path(sys.argv[1])
ID = re.compile(r"\bAK-[A-Z]+-[0-9]+\b")
spec = (root / "docs/spec.md").read_text()
head, _, table = spec.partition("\n## Tests\n")
if not table:
    sys.exit("docs/spec.md has no '## Tests' section")

defined = []
for line in head.splitlines():
    match = re.match(r"^\| (AK-[A-Z]+-[0-9]+) \|", line)
    if match:
        defined.append(match.group(1))
problems = [f"{name} is defined twice" for name, count in Counter(defined).items() if count > 1]
defined_set = set(defined)

def test_text(path):
    text = path.read_text(errors="replace")
    relative = path.relative_to(root).as_posix()
    if relative.startswith("src/") and not (path.name == "tests.rs" or path.name.endswith("_tests.rs")):
        marker = re.search(r"#\[cfg\(test\)\]\n(pub(\(crate\))? )?mod tests", text)
        tests = text[marker.start():] if marker else ""
        # A doctest counts with the item it documents, which the table names as `file::Item`.
        doctests, inside = [], False
        for line in text.splitlines():
            stripped = line.strip()
            if stripped.startswith(("///", "//!")):
                body = stripped[3:].strip()
                if body.startswith("```"):
                    inside = not inside
                    continue
                if inside:
                    doctests.append(body)
            else:
                if inside and doctests and re.match(r"(pub\s+)?(enum|struct|fn|trait)\s", stripped):
                    doctests.append(stripped)
                inside = False
                if doctests and re.match(r"(pub\s+)?(enum|struct|fn|trait)\s", stripped):
                    doctests.append(stripped)
        return tests + "\n" + "\n".join(doctests)
    return text

files = {}
for path in sorted((root / "tests").rglob("*")):
    if path.is_file() and path.suffix in {".rs", ".swift", ".sh"} and "target" not in path.parts:
        files[path.relative_to(root).as_posix()] = test_text(path)
for path in sorted((root / "src").rglob("*.rs")):
    files[path.relative_to(root).as_posix()] = test_text(path)

named = {}
for relative, text in files.items():
    for name in ID.findall(text):
        named.setdefault(name, set()).add(relative)

traced = {}
for line in table.splitlines():
    match = re.match(r"^\| (AK-[A-Z]+-[0-9]+) \| (.*) \|\s*$", line)
    if not match:
        continue
    requirement, cell = match.groups()
    if requirement in traced:
        problems.append(f"{requirement} has two rows in the test table")
    tests = re.findall(r"`([^`]+)::([A-Za-z_][A-Za-z0-9_]*)` \((unit|doc|Swift host|simulator|build)\)", cell)
    traced[requirement] = tests
    if requirement not in defined_set:
        problems.append(f"the test table names {requirement}, which the spec does not define")
    for relative, function, _level in tests:
        text = files.get(relative)
        if text is None:
            problems.append(f"{requirement}: {relative} is not a test file")
            continue
        if not re.search(rf"\b(fn|func|enum|struct)\s+{function}\b|^{function}\(\)\s*\{{", text, re.M):
            problems.append(f"{requirement}: {relative} has no test {function}")
        if requirement not in ID.findall(text):
            problems.append(f"{requirement}: {relative} does not name it")

for requirement in defined:
    if not traced.get(requirement):
        problems.append(f"{requirement} has no test in the test table")
    if requirement not in named:
        problems.append(f"{requirement} is named by no test file")
for name, where in sorted(named.items()):
    if name not in defined_set:
        problems.append(f"{', '.join(sorted(where))} name {name}, which docs/spec.md does not define")

areas = Counter(name.split("-")[1] for name in defined)
levels = Counter(level for tests in traced.values() for _, _, level in tests)
print("requirements by area: " + ", ".join(f"{area} {count}" for area, count in sorted(areas.items())))
print(f"requirements: {len(defined)}; test references: {sum(levels.values())} "
      f"({', '.join(f'{level} {count}' for level, count in sorted(levels.items()))})")
if problems:
    print("\n".join("FAIL " + problem for problem in problems))
    sys.exit(f"spec coverage: {len(problems)} problem(s)")
print("spec coverage: every requirement has a test, and every test names a requirement of the spec")
PYTHON

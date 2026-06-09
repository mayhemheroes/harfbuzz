#!/usr/bin/env bash
# harfbuzz/mayhem/test.sh — RUN harfbuzz's SHAPE tests as a functional suite. This is an
# OUTPUT-ASSERTING oracle: harfbuzz's own test/shape/run-tests.py feeds each case (font;options;
# unicodes) to the `hb-shape` utility and compares hb-shape's stdout glyph string to the expected
# glyph string baked into the .tests files under test/shape/data/*/tests/*.tests. A test PASSES iff
# the produced glyphs equal the expected glyphs; it FAILS on any mismatch.
#
# This is deliberately NOT exit-code based. A reward-hacking patch that makes hb-shape exit(0),
# print nothing, or emit garbage would produce glyph output that does NOT match the expected
# strings, so run-tests.py would count those as failures (not passes) and this script exits non-zero.
#
# mayhem/build.sh produced /mayhem/hb-shape with a CLEAN normal-flags meson build. This script only
# RUNS the suite — it never compiles. The .tests data + fonts are static in-tree.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

HB_SHAPE=/mayhem/hb-shape
[ -x "$HB_SHAPE" ] || { echo "missing $HB_SHAPE — run mayhem/build.sh first" >&2; exit 2; }

RUNNER="$SRC/test/shape/run-tests.py"
[ -f "$RUNNER" ] || { echo "missing $RUNNER" >&2; exit 2; }

# Select exactly the .tests files harfbuzz's own meson wiring registers as the `shape` suite — and
# NOT the upstream-disabled ones. Each dataset's test/shape/data/<set>/meson.build lists its active
# files in an `<set>_tests = [ ... ]` array (e.g. text_rendering_tests_tests); the cases upstream
# knows are environment/rounding-sensitive are parked in a SEPARATE `disabled_..._tests` array that
# meson never registers (see test/shape/data/text-rendering-tests/DISABLED). A naive `find *.tests`
# would also run those disabled cases and report spurious failures, so we mirror meson's selection.
SELECTOR="$(mktemp)"
cat > "$SELECTOR" <<'PY'
import re, os
base = os.path.join(os.environ["SRC"], "test/shape/data")
sets = {"in-house": "in_house_tests",
        "aots": "aots_tests",
        "text-rendering-tests": "text_rendering_tests_tests"}
out = []
for s, var in sets.items():
    mb_path = os.path.join(base, s, "meson.build")
    if not os.path.exists(mb_path):
        continue
    mb = open(mb_path).read()
    m = re.search(r"\b" + var + r"\s*=\s*\[(.*?)\]", mb, re.S)
    if not m:
        continue
    for name in re.findall(r"'([^']+\.tests)'", m.group(1)):
        p = os.path.join(base, s, "tests", name)
        if os.path.exists(p):
            out.append(p)
print("\n".join(out))
PY
tests_files=()
while IFS= read -r f; do [ -n "$f" ] && tests_files+=("$f"); done < <(python3 "$SELECTOR")
rm -f "$SELECTOR"
[ "${#tests_files[@]}" -gt 0 ] || { echo "no shape .tests files selected" >&2; exit 2; }
echo "## running harfbuzz shape suite over ${#tests_files[@]} .tests files via $HB_SHAPE"

# run-tests.py accumulates pass/fail/skip across all files in one invocation and prints a single
# TAP summary line:  "# <P> tests passed; <F> failed; <K> skipped."  We drive ONE invocation with
# every .tests file so the totals are exact, capture its full output, then parse that summary line.
# Each "ok"/"not ok" line is an output comparison performed inside run-tests.py.
out="$(python3 "$RUNNER" "$HB_SHAPE" "${tests_files[@]}" 2>&1)"
rc=$?
# Show TAP plan + summary, plus any mismatch detail, but keep the bulk of "ok" lines quiet.
printf '%s\n' "$out" | grep -E '^(not ok|# .*tests passed|# All tests|# No tests|1\.\.)' || true

summary="$(printf '%s\n' "$out" | grep -E '^# [0-9]+ tests passed; [0-9]+ failed; [0-9]+ skipped\.' | tail -1)"
if [ -z "$summary" ]; then
  echo "FATAL: could not find run-tests.py summary line (runner crashed?)" >&2
  emit_ctrf "harfbuzz-shape" 0 1 0 || true
  exit 1
fi

passed=$( printf '%s' "$summary" | sed -n 's/^# \([0-9][0-9]*\) tests passed;.*/\1/p')
failed=$( printf '%s' "$summary" | sed -n 's/^# [0-9][0-9]* tests passed; \([0-9][0-9]*\) failed;.*/\1/p')
skipped=$(printf '%s' "$summary" | sed -n 's/^# [0-9][0-9]* tests passed; [0-9][0-9]* failed; \([0-9][0-9]*\) skipped\..*/\1/p')
: "${passed:=0}" "${failed:=0}" "${skipped:=0}"

# If the runner itself exited non-zero with no counted failures (e.g. a parse/setup crash), treat
# as a failure so a broken hb-shape can never sneak through as a pass.
if [ "$rc" -ne 0 ] && [ "$failed" -eq 0 ] && [ "$passed" -eq 0 ]; then
  failed=1
fi

emit_ctrf "harfbuzz-shape" "$passed" "$failed" "$skipped"

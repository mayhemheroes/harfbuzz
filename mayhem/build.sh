#!/usr/bin/env bash
# harfbuzz/mayhem/build.sh — meson build (ASan+UBSan) of the harfbuzz libraries + all SIX
# libFuzzer harnesses (hb-shape, hb-subset, hb-raster, hb-vector, hb-gpu, hb-repacker — full
# OSS-Fuzz parity), plus a standalone (non-fuzzer) reproducer per harness. A THIRD, separate,
# CLEAN normal-flags build produces the `hb-shape` (and `hb-subset`) utilities that
# mayhem/test.sh uses as an output-asserting shaping oracle.
#
# The raster/vector/gpu/repacker harnesses link the experimental harfbuzz libraries
# (libharfbuzz_raster/_vector/_gpu/_subset), all of which the meson options enable by default.
# hb-gpu uses harfbuzz's CPU-side GPU encoder (libharfbuzz_gpu) — NOT the optional `gpu_demo`
# tool, which is the only thing that needs a real GL/GLEW/GLFW backend — so it builds headlessly.
#
# harfbuzz builds with meson. We compile the PROJECT ITSELF with $SANITIZER_FLAGS (via meson's
# c_args/cpp_args) so the fuzzed code — not just the harness — is instrumented, and link the
# libFuzzer engine into each harness via meson's `fuzzer_ldflags` option (exactly how upstream
# wires up its fuzzers: when fuzzer_ldflags is set, test/fuzzing/meson.build links the engine and
# defines HB_IS_IN_FUZZER; when it is empty, it instead links the project's own run-once driver
# main.cc — which is precisely the standalone file-input reproducer we want). So we run meson
# twice: once with the engine (the Mayhem targets) and once without (the -standalone reproducers).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# Build knobs from the ENV, overridable. SANITIZER_FLAGS uses `=` (not `:=`) so an explicit empty
# value (--build-arg SANITIZER_FLAGS=) is honored → no-sanitizer build (natural crash).
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS: emit DWARF ≤ 3 symbols so Mayhem triage can read backtraces (§6.2 item 10).
# Clang-19's plain -g emits DWARF-5; -gdwarf-3 forces DWARF-3. Appended AFTER $SANITIZER_FLAGS.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
export CC CXX MAYHEM_JOBS DEBUG_FLAGS

cd "$SRC"

# harfbuzz disables UBSan's vptr check (the library is built -fno-rtti), matching upstream's
# oss-fuzz recipe — UBSan's vptr instrumentation needs RTTI, which harfbuzz turns off. Only add the
# opt-out when UBSan is actually requested, so the empty/no-sanitizer build stays clean.
HB_SAN="$SANITIZER_FLAGS"
case "$HB_SAN" in
  *undefined*) HB_SAN="$HB_SAN -fno-sanitize=vptr" ;;
esac
# SanitizerCoverage instrumentation: the base image's SANITIZER_FLAGS contains only
# -fsanitize=address,undefined — it intentionally omits the coverage flags to leave
# the coverage mode to each project's harness.  Without -fsanitize=fuzzer-no-link the
# harfbuzz libraries compile WITHOUT edge-coverage callbacks, so libFuzzer iterates but
# Mayhem reports 0 edges.  Append fuzzer-no-link unless a fuzzer flag is already present
# (e.g. --build-arg SANITIZER_FLAGS already includes it, or the empty no-sanitizer case).
case "$HB_SAN" in
  *fuzzer*) ;;
  *) HB_SAN="$HB_SAN -fsanitize=fuzzer-no-link" ;;
esac
# Combine sanitizer + debug flags for compile steps; link flags carry only the sanitizer (no debug flags needed there).
HB_COMPILE="$HB_SAN $DEBUG_FLAGS"

# Common meson configure flags. --wrap-mode=nodownload keeps the build hermetic/offline (no
# subproject fetches); experimental_api + subset (default enabled) match the upstream fuzzers.
# The fuzzers live under test/fuzzing, which meson only configures when `tests` is enabled — so we
# enable tests but disable utilities, keeping the build off glib/cairo/freetype/chafa (the api and
# shape/subset test dirs self-skip without glib; the fuzzing subdir only needs libharfbuzz).
meson_common=(
  --buildtype=plain
  --default-library=static
  --wrap-mode=nodownload
  -Dexperimental_api=true
  -Dtests=enabled
  -Dutilities=disabled
  "-Dc_args=$HB_COMPILE"
  "-Dcpp_args=$HB_COMPILE"
  "-Dc_link_args=$HB_SAN"
  "-Dcpp_link_args=$HB_SAN"
)

FUZZERS=(hb-shape-fuzzer hb-subset-fuzzer hb-raster-fuzzer hb-vector-fuzzer hb-gpu-fuzzer hb-repacker-fuzzer)
NINJA_TARGETS=()
for f in "${FUZZERS[@]}"; do NINJA_TARGETS+=("test/fuzzing/$f"); done

# 1) libFuzzer build (the Mayhem targets): fuzzer_ldflags=$LIB_FUZZING_ENGINE links the engine and
#    defines HB_IS_IN_FUZZER so the harness exposes LLVMFuzzerTestOneInput.
rm -rf "$SRC/build-fuzz"
meson setup "$SRC/build-fuzz" "${meson_common[@]}" \
      "-Dfuzzer_ldflags=$LIB_FUZZING_ENGINE" \
  || { cat "$SRC/build-fuzz/meson-logs/meson-log.txt" 2>/dev/null; false; }
ninja -C "$SRC/build-fuzz" -j"$MAYHEM_JOBS" "${NINJA_TARGETS[@]}"
for f in "${FUZZERS[@]}"; do
  cp "$SRC/build-fuzz/test/fuzzing/$f" "/mayhem/$f"
done

# 2) Standalone (non-fuzzer) reproducers: fuzzer_ldflags='' makes meson link the project's own
#    run-once driver (test/fuzzing/main.cc), which reads input files and calls
#    LLVMFuzzerTestOneInput once each — a natural-crash reproducer, no libFuzzer runtime. Still
#    built with $SANITIZER_FLAGS (so the empty off-switch yields a clean reproducer too).
rm -rf "$SRC/build-standalone"
meson setup "$SRC/build-standalone" "${meson_common[@]}" \
      "-Dfuzzer_ldflags=" \
  || { cat "$SRC/build-standalone/meson-logs/meson-log.txt" 2>/dev/null; false; }
ninja -C "$SRC/build-standalone" -j"$MAYHEM_JOBS" "${NINJA_TARGETS[@]}"
for f in "${FUZZERS[@]}"; do
  cp "$SRC/build-standalone/test/fuzzing/$f" "/mayhem/$f-standalone"
done

# 3) NORMAL-flags utility build (the functional-test oracle): build the `hb-shape` (and `hb-subset`)
#    command-line tools so test.sh can assert harfbuzz's actual SHAPING OUTPUT against the expected
#    glyph strings shipped under test/shape/data/*/tests/*.tests. This is a CLEAN, unsanitized build,
#    fully separate from the ASan/UBSan fuzz builds above: no $SANITIZER_FLAGS, no fuzzer engine.
#    hb-shape needs glib (HAVE_GLIB gates the utilities) + freetype; cairo is optional (null_dep) and
#    not required by hb-shape, so we leave -Dcairo at its auto default. -Dutilities=enabled forces the
#    tools to build (so a missing dep fails loudly here rather than silently disabling hb-shape), and
#    -Dtests=enabled keeps the shape test wiring available. The .tests data + fonts are static in-tree,
#    so nothing test-specific needs compiling — only the hb-shape binary.
rm -rf "$SRC/build-util"
meson setup "$SRC/build-util" \
      --buildtype=plain \
      --default-library=static \
      --wrap-mode=nodownload \
      -Dexperimental_api=true \
      -Dtests=enabled \
      -Dutilities=enabled \
      -Dglib=enabled \
      -Dfreetype=enabled \
  || { cat "$SRC/build-util/meson-logs/meson-log.txt" 2>/dev/null; false; }
ninja -C "$SRC/build-util" -j"$MAYHEM_JOBS" util/hb-shape util/hb-subset
cp "$SRC/build-util/util/hb-shape"  "/mayhem/hb-shape"
cp "$SRC/build-util/util/hb-subset" "/mayhem/hb-subset"

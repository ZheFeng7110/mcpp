#!/usr/bin/env bash
# requires: gcc
# mcpp#225 (cluster E — E1 bounded glob walk + E2 run-cache reuse):
#   E1: expand_glob must bound its walk to the glob's literal directory
#       prefix ("src" for "src/**/*.{...}") instead of always walking the
#       whole project root. A large, unrelated top-level sibling directory
#       (`blob/`, ~1500 files) exercises exactly the tree an unbounded walk
#       would otherwise have to stat/canonicalize on every scan.
#   E2: `mcpp run` must reuse the build cache `mcpp build` already resolved
#       (fingerprint + ninja freshness, same gate as `mcpp build`'s own
#       fast path) instead of unconditionally calling prepare_build (full
#       toolchain resolution + modgraph scan) on every invocation.
#
# Not asserted via wall-clock (brittle across CI hosts) — asserted via the
# absence of the scan phase's observability marker: prepare_build logs
# `mcpp::log::verbose("scan", "scanning module sources")` right before it
# invokes the scanner (see prepare.cppm). Under MCPP_VERBOSE=1 that line is
# grep-able on stderr. `mcpp run` only reaches prepare_build when its own
# fast path (try_fast_run in execute.cppm) misses — so if the line is
# absent, the run never re-scanned.
set -e

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

cd "$TMP"
mkdir -p proj/src proj/blob

cat > proj/mcpp.toml <<'EOF'
[package]
name = "runscope"
version = "0.1.0"
EOF

cat > proj/src/main.cpp <<'EOF'
#include <cstdio>
int main() { std::puts("hello from runscope"); return 0; }
EOF

# Large unrelated sibling tree, NOT under src/ and not matched by the
# default "src/**/*.{...}" source glob — present purely to make an
# unbounded (root-wide) walk expensive/observable, and to prove the bounded
# walk (E1) never has a reason to touch it.
for i in $(seq 1 1500); do
    : > "proj/blob/file_$i.txt"
done

cd proj
"$MCPP" build

# `mcpp build` already resolves + writes a complete cache (incl.
# BuildCacheEntry::runTargets) via run_build_plan, so even the FIRST
# `mcpp run` after a build should hit the fast path — there is no separate
# "warm-up" run required.
MCPP_VERBOSE=1 "$MCPP" run > "$TMP/run1.out" 2>&1
if grep -q 'scan: scanning module sources' "$TMP/run1.out"; then
    echo "FAIL: first mcpp run (post-build) re-scanned module sources instead of reusing the build cache"
    cat "$TMP/run1.out"
    exit 1
fi
grep -q "hello from runscope" "$TMP/run1.out" || {
    echo "FAIL: mcpp run did not produce expected program output"
    cat "$TMP/run1.out"
    exit 1
}

# Second run: same assertion, now also covering that the fast path is
# stable across repeated invocations (not a one-shot fluke).
MCPP_VERBOSE=1 "$MCPP" run > "$TMP/run2.out" 2>&1
if grep -q 'scan: scanning module sources' "$TMP/run2.out"; then
    echo "FAIL: second mcpp run re-scanned module sources instead of reusing the build cache"
    cat "$TMP/run2.out"
    exit 1
fi
grep -q "hello from runscope" "$TMP/run2.out" || {
    echo "FAIL: mcpp run did not produce expected program output"
    cat "$TMP/run2.out"
    exit 1
}

# Sanity: touching a source file must still force a real rebuild (the fast
# path's freshness gate, not a permanent bypass).
sleep 1.1
touch src/main.cpp
MCPP_VERBOSE=1 "$MCPP" run > "$TMP/run3.out" 2>&1
grep -q 'scan: scanning module sources' "$TMP/run3.out" || {
    echo "FAIL: mcpp run did not re-scan after a source change (fast path should have missed)"
    cat "$TMP/run3.out"
    exit 1
}
grep -q "hello from runscope" "$TMP/run3.out" || {
    echo "FAIL: mcpp run did not produce expected program output after rebuild"
    cat "$TMP/run3.out"
    exit 1
}

echo "PASS: mcpp run reuses the resolved build cache (no re-scan) with a large unrelated sibling tree present, and still rebuilds on source changes"

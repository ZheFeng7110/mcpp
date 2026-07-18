#!/usr/bin/env bash
# requires: gcc
# 119_dep_cfg_sources.sh — #229: a PATH DEPENDENCY's `[target.'cfg(...)'.build]`
# conditional `sources` must be compiled, in BOTH `mcpp build` and `mcpp test`.
#
# Regression: `merge_conditional_build` (the L1b cfg-sources merge) was only
# ever invoked for the root package (prepare.cppm root call site) and for
# version/registry dependencies (loadVersionDep). Path/git dependencies load
# their manifest directly and skipped the merge entirely — a path dep's
# cfg-conditional `sources` were parsed into `conditionalConfigs` but never
# folded into `buildConfig.sources` / `modules.sources`, so the modgraph scan
# never saw the file and the final link failed with `undefined reference`.
#
# `mylib` is a path dependency whose `mylib.cppm` module forward-declares
# `impl_value()` (extern "C", to sidestep name mangling) but the DEFINITION
# lives in `src/impl.cpp`, which is reachable ONLY through the cfg-conditional
# `[target.'cfg(...)'.build] sources` — never through the unconditional
# `[build] sources` glob. Host-aware: both `cfg(unix)` and `cfg(windows)`
# blocks point at the same file, so exactly one always applies (mirrors
# 86_target_cfg_dependencies.sh's host-aware dual-predicate style) and the
# test runs identically on all 3 CI platforms.
set -e

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT
cd "$TMP"

mkdir -p mylib/src
cat > mylib/mcpp.toml <<'EOF'
[package]
name    = "mylib"
version = "0.1.0"

[targets.mylib]
kind = "lib"

[build]
sources = ["src/**/*.cppm"]

# impl.cpp is reachable ONLY through these conditional blocks — never through
# the unconditional [build] sources glob above. Exactly one of unix/windows
# always matches the resolved host target.
[target.'cfg(unix)'.build]
sources = ["src/impl.cpp"]
[target.'cfg(windows)'.build]
sources = ["src/impl.cpp"]
EOF
cat > mylib/src/mylib.cppm <<'EOF'
export module mylib;

// Defined in src/impl.cpp, which is pulled in ONLY via cfg-conditional
// [target.'cfg(...)'.build] sources — extern "C" so the module boundary
// doesn't affect the link name.
extern "C" int impl_value();

export int mylib_answer() { return impl_value(); }
EOF
cat > mylib/src/impl.cpp <<'EOF'
extern "C" int impl_value() { return 42; }
EOF

mkdir -p app/src app/tests
cat > app/mcpp.toml <<'EOF'
[package]
name    = "app"
version = "0.1.0"

[dependencies]
mylib = { path = "../mylib" }
EOF
cat > app/src/main.cpp <<'EOF'
import mylib;
import std;
int main() {
    std::println("value = {}", mylib_answer());
    return mylib_answer() == 42 ? 0 : 1;
}
EOF
cat > app/tests/t.cpp <<'EOF'
import mylib;
int main() {
    return mylib_answer() == 42 ? 0 : 1;
}
EOF

cd app

# (1) `mcpp build` must compile+link mylib's cfg-conditional source.
"$MCPP" build > b.log 2>&1 || {
    cat b.log
    echo "FAIL: build did not compile the path dep's cfg-conditional sources (undefined reference expected pre-fix)"
    exit 1
}
out="$("$MCPP" run 2>&1 | tail -1)"
[[ "$out" == "value = 42" ]] || { echo "FAIL: unexpected run output: $out"; exit 1; }

# (2) `mcpp test` must ALSO compile+link it (the per-package funnel must fire
#     in both modes, mirroring 100_feature_sources_test_mode.sh's build/test
#     parity check).
"$MCPP" test > t.log 2>&1 || {
    cat t.log
    echo "FAIL: test mode did not compile the path dep's cfg-conditional sources"
    exit 1
}

echo "OK"

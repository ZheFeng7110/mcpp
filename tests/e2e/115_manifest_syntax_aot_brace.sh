#!/usr/bin/env bash
# requires: gcc
# #227 + #228: [[build.flags]] array-of-tables and glob brace alternation
# {a,b} are both pure-syntax additions to the manifest grammar — this test
# exercises them TOGETHER, the way a real "codec backends" manifest would:
#   - two source directories selected by ONE glob with brace alternation
#     (p/{aac,bsf}/**), a third sibling directory (p/opus) excluded from it
#   - per-glob flags declared via the NEW [[build.flags]] array-of-tables
#     syntax (rather than the existing flags = [{...}] inline-table array),
#     with a brace glob on the flags entry itself
# Assert: build succeeds, and the per-glob define only reaches units under
# the brace-matched directories (not the sibling excluded from both the
# sources glob and the flags glob).
set -e

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

cd "$TMP"
"$MCPP" new aotbrace > /dev/null
cd aotbrace

mkdir -p src/p/aac src/p/bsf src/p/opus

cat > src/p/aac/aac.cpp <<'EOF'
#ifndef CODEC
#error "per-glob define (via [[build.flags]] AOT) did not reach aac.cpp"
#endif
extern "C" int aac_id() { return 1; }
EOF

cat > src/p/bsf/bsf.cpp <<'EOF'
#ifndef CODEC
#error "per-glob define (via [[build.flags]] AOT) did not reach bsf.cpp"
#endif
extern "C" int bsf_id() { return 2; }
EOF

cat > src/p/opus/opus.cpp <<'EOF'
#ifdef CODEC
#error "brace glob over-matched: opus.cpp is outside {aac,bsf}"
#endif
extern "C" int opus_id() { return 3; }
EOF

cat > src/main.cpp <<'EOF'
import std;
extern "C" int aac_id();
extern "C" int bsf_id();
extern "C" int opus_id();
int main() {
    std::println("ids = {}", aac_id() + bsf_id() + opus_id());
    return 0;
}
EOF

# sources: brace alternation selects p/aac and p/bsf, plus opus explicitly
# (so it's compiled but must NOT receive the CODEC define) and main.cpp.
# [build].flags: NEW `[[build.flags]]` array-of-tables syntax (issue #227),
# with a brace glob (issue #228) on the entry itself.
cat > mcpp.toml <<'EOF'
[package]
name    = "aotbrace"
version = "0.1.0"

[build]
sources = ["src/p/{aac,bsf}/**/*.cpp", "src/p/opus/**/*.cpp", "src/main.cpp"]

[[build.flags]]
glob    = "src/p/{aac,bsf}/**"
defines = ["CODEC"]
EOF

"$MCPP" build > build.log 2>&1 || { cat build.log; echo "build failed"; exit 1; }
out="$("$MCPP" run 2>&1 | tail -1)"
[[ "$out" == "ids = 6" ]] || { echo "unexpected output: $out (want ids = 6)"; exit 1; }

echo "OK"

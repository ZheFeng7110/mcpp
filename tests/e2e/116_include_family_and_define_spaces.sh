#!/usr/bin/env bash
# requires: gcc
# mcpp#226 + mcpp#234: the full include-family flag spelling (-I/-iquote/
# -isystem/-idirafter/-iprefix/-L) must root-relativize, not just -I; and any
# flag-vector token that contains a space (e.g. `-DT=long long`, one manifest
# `defines` entry) must survive as ONE shell argument through emission, not
# silently split into two.
set -e

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

cd "$TMP"
"$MCPP" new incfam > /dev/null
cd incfam

# --- Part 1: #226 — -iquote (joined spelling) resolves root-relative -------
# hdr/magic.h is NOT next to the including .c file, so plain quote-include
# lookup (current-dir-of-includer, then quote search path) only finds it if
# -iquotehdr got rewritten to an absolute, root-relative "-iquote<root>/hdr".
mkdir -p hdr
cat > hdr/magic.h <<'EOF'
#define MAGIC 42
EOF

cat > src/magic_user.c <<'EOF'
#include "magic.h"
int get_magic(void) { return MAGIC; }
EOF

cat > src/main.cpp <<'EOF'
import std;
extern "C" int get_magic();
extern long long get_big();

int main() {
    std::println("magic={} big={}", get_magic(), get_big());
    return 0;
}
EOF

# --- Part 2: #234 — a flag-vector token containing a space must reach the
# compiler as ONE argv token, not split on the space. T is injected via a
# per-glob `defines = ["T=long long"]` targeting this file specifically. If
# the space split the token, the compiler would see a bogus positional
# "long" argument and this translation unit would fail to build.
cat > src/typed_user.cpp <<'EOF'
typedef T MyLong;
long long get_big() {
    MyLong big = 123456789012LL;
    return static_cast<long long>(big);
}
EOF

cat > mcpp.toml <<'EOF'
[package]
name    = "incfam"
version = "0.1.0"

[build]
cflags = ["-iquotehdr"]
flags = [
  { glob = "src/typed_user.cpp", defines = ["T=long long"] },
]
EOF

"$MCPP" build > build.log 2>&1 || { cat build.log; echo "build failed"; exit 1; }

out="$("$MCPP" run 2>&1 | tail -1)"
[[ "$out" == "magic=42 big=123456789012" ]] || {
    echo "unexpected output: $out"; exit 1; }

echo "OK"

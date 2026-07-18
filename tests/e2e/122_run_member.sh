#!/usr/bin/env bash
# requires:
# run-member-selection: `mcpp run` gains -p/--package, matching `build -p` /
# `test -p`. `mcpp run -p memberB` in a workspace with two binary members
# must build+run memberB's binary specifically (not memberA's, not an
# auto-picked one).
set -euo pipefail

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT
cd "$TMP"

mkdir -p memberA/src memberB/src

cat > mcpp.toml <<'EOF'
[workspace]
members = ["memberA", "memberB"]
EOF

cat > memberA/mcpp.toml <<'EOF'
[package]
name = "memberA"
version = "0.1.0"

[targets.memberA]
kind = "bin"
main = "src/main.cpp"
EOF
cat > memberA/src/main.cpp <<'EOF'
import std;
int main() { std::println("hello from memberA"); return 0; }
EOF

cat > memberB/mcpp.toml <<'EOF'
[package]
name = "memberB"
version = "0.1.0"

[targets.memberB]
kind = "bin"
main = "src/main.cpp"
EOF
cat > memberB/src/main.cpp <<'EOF'
import std;
int main() { std::println("hello from memberB"); return 0; }
EOF

# `-p memberB` must run memberB's binary — assert its DISTINCT output, not
# memberA's (and not "no binary target found").
OUT=$("$MCPP" run -p memberB 2>run_b.log) || { cat run_b.log; echo "FAIL: run -p memberB failed"; exit 1; }
echo "$OUT"
[[ "$OUT" == *"hello from memberB"* ]] || {
    echo "FAIL: expected memberB's output, got: $OUT"
    exit 1
}
[[ "$OUT" != *"hello from memberA"* ]] || {
    echo "FAIL: memberA's output leaked into -p memberB run"
    exit 1
}

# `-p memberA` runs the other one.
OUT=$("$MCPP" run -p memberA 2>run_a.log) || { cat run_a.log; echo "FAIL: run -p memberA failed"; exit 1; }
echo "$OUT"
[[ "$OUT" == *"hello from memberA"* ]] || {
    echo "FAIL: expected memberA's output, got: $OUT"
    exit 1
}

# Unknown member name errors clearly instead of silently picking one.
if "$MCPP" run -p nope > run_bad.log 2>&1; then
    echo "FAIL: run -p nope should have failed"
    exit 1
fi
grep -qi "nope" run_bad.log || {
    cat run_bad.log
    echo "FAIL: expected an error mentioning the unknown member 'nope'"
    exit 1
}

echo "OK"

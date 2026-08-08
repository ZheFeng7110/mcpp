#!/usr/bin/env bash
# requires:
# 76_compile_commands_generated.sh — `mcpp build` of a minimal project must
# emit a valid Clang compilation database (compile_commands.json) at the
# project root, on EVERY platform (Linux / macOS / Windows). IDE/clangd
# integration depends on it, and generation is unconditional in the ninja
# backend, so this guards the contract directly rather than as a side effect
# of the more specific CDB tests (47 prebuilt-module-path, 59 std flag).
#
# No `requires:` capability → runs on all three CI platforms.
set -e

TMP=$(mktemp -d)
trap "rm -rf $TMP" EXIT

cd "$TMP"
"$MCPP" new app > /dev/null
cd app

# A second source reached through a MULTI-SEGMENT glob (literal prefix
# "generated/modules") — the shape that used to leak MIXED separators into
# the CDB's `file`/`-c` on Windows (`root\generated/modules\extra.cpp`),
# because MSVC's std::filesystem::path keeps the `/` from the manifest glob.
mkdir -p generated/modules
cat > generated/modules/extra.cpp <<'EOF'
int mcpp_extra_anchor() { return 1; }
EOF
cat >> mcpp.toml <<'EOF'

[build]
sources = ["src/**/*.cpp", "generated/modules/**/*.cpp"]
EOF

"$MCPP" build > /dev/null

cdb=compile_commands.json
[[ -f "$cdb" ]] || { echo "FAIL: no $cdb generated at project root"; exit 1; }
[[ -s "$cdb" ]] || { echo "FAIL: $cdb is empty"; exit 1; }

# Top-level must be a JSON array.
first="$(head -c 1 "$cdb")"
[[ "$first" == "[" ]] || {
    echo "FAIL: $cdb does not start with '[' (got '$first') — not a JSON array"
    cat "$cdb"; exit 1
}

# CDB-required keys + the clang command form (command OR arguments).
for key in '"directory"' '"file"'; do
    grep -q "$key" "$cdb" || { echo "FAIL: $cdb missing $key"; cat "$cdb"; exit 1; }
done
grep -qE '"command"|"arguments"' "$cdb" || {
    echo "FAIL: $cdb has neither \"command\" nor \"arguments\""; cat "$cdb"; exit 1
}

# The minimal project's source (src/main.cpp) must have an entry.
grep -q 'main\.cpp' "$cdb" || { echo "FAIL: $cdb has no entry for src/main.cpp"; cat "$cdb"; exit 1; }

# Deeper structural validation when a JSON parser is available (GitHub-hosted
# runners ship python3). Skips cleanly where it isn't, keeping the grep checks
# above as the portable baseline.
if command -v python3 >/dev/null 2>&1; then
    python3 - "$cdb" <<'PY' || exit 1
import json, sys, os
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert isinstance(d, list) and d, "CDB must be a non-empty JSON array"
for e in d:
    assert "file" in e and "directory" in e, "entry missing file/directory: %r" % e
    assert ("command" in e) or ("arguments" in e), "entry missing command/arguments: %r" % e
    # Native separators on Windows: a multi-segment manifest glob used to
    # yield MIXED `root\generated/modules\x.cppm` file paths (MSVC's path
    # keeps the `/` from the glob prefix), which CLion refuses to parse.
    # Ninja hides the problem (it renders generic_string()); the CDB is
    # the .string() consumer.
    if os.name == "nt" and "/" in e["file"]:
        raise AssertionError("file must use native separators on Windows: %r" % e["file"])
print("  json validation OK (%d entries)" % len(d))
PY
fi

echo "OK"

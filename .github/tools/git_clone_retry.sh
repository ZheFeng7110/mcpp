#!/usr/bin/env bash
# git_clone_retry.sh — `git clone`, but a hosted runner's DNS hiccup is not a
# red build.
#
# WHY THIS EXISTS
#
# Measured on a macOS ARM64 runner, in a step that had not yet executed a single
# line of mcpp:
#
#   Cloning into '/tmp/xlings-src'...
#   fatal: unable to access 'https://github.com/openxlings/xlings/':
#          Could not resolve host: github.com
#   ##[error]Process completed with exit code 128
#
# Thirty seconds of resolver timeout, then a failed PR check that says nothing
# about the change under test. Every workflow in this repository that reaches an
# external repository did it with a bare `git clone`, so every one of them could
# fail this way — six call sites, one failure mode.
#
# THIS REPOSITORY ALREADY LEARNED THIS FOR `curl`
#
# `fetch_release.sh` carries the same lesson one protocol over: `curl --retry`
# alone does not cover a transport-layer error, and `--retry-all-errors` is what
# does. `git` has no such flag at all — the retry has to be here.
#
# WHY BOUNDED, AND WHY IT DOES NOT TRY TO BE CLEVER
#
# git reports "the host does not resolve", "the repository does not exist" and
# "the credentials are wrong" as the same exit 128, with only the message to
# tell them apart. Parsing that message would be a second, weaker copy of git's
# own error taxonomy — and it would be wrong the first time git rephrased one.
#
# So this retries EVERY failure, a bounded number of times. A genuinely missing
# repository costs the attempts and then fails with git's own last message
# intact, which is ~50s and a diagnostic that still names the real cause. A
# resolver blip costs one backoff. That trade is the same one `--retry-all-errors`
# makes, and it is the right way round: a false red costs a maintainer a rerun
# and their attention, a slow true red costs 50 seconds.
#
# Usage:  git_clone_retry.sh [git clone args...] <url> <dir>
#         git_clone_retry.sh --rev <ref> <url>          # print the commit it names
#         git_clone_retry.sh --commit <sha> <url> <dir> # that commit, exactly
# Env:    GIT_CLONE_ATTEMPTS (default 4), GIT_CLONE_BACKOFF (default "5 15 30")
set -euo pipefail

ATTEMPTS="${GIT_CLONE_ATTEMPTS:-4}"
read -r -a BACKOFF <<< "${GIT_CLONE_BACKOFF:-5 15 30}"

# The destination is the last argument when it is not an option. Removing a
# partial clone before retrying matters: git refuses to clone into a directory
# that exists and is not empty, so without this the second attempt fails for a
# different reason than the first and the log stops making sense.
dest="${*: -1}"

# `cmd || rc=$?`, NOT `if cmd; then …; fi; rc=$?`.
#
# After an `if`, `$?` is the status of the IF STATEMENT — which is 0 when the
# body did not run. Written that way this script exits 0 on a clone that never
# succeeded, i.e. it turns a hard failure into a green step with a missing
# checkout. Caught by asserting the exit code in the helper's own test rather
# than by reading the output, which looked correct.
#
# ONE COPY OF IT, for all three verbs below. They back off over the same
# sequence and give up in the same words, so the retry is a property of the
# helper rather than of whichever verb was written last.
failed() {  # $1 = attempt number (1-based), $2 = exit status of that attempt
    if (( $1 == ATTEMPTS )); then
        echo "git_clone_retry: giving up after $ATTEMPTS attempts (last exit $2)" >&2
        exit "$2"
    fi
    delay="${BACKOFF[$(( $1 - 1 < ${#BACKOFF[@]} ? $1 - 1 : ${#BACKOFF[@]} - 1 ))]}"
    echo "git_clone_retry: attempt $1/$ATTEMPTS failed (exit $2); retrying in ${delay}s" >&2
    sleep "$delay"
}

# ── TWO MORE VERBS, AND WHY THEY ARE IN THIS FILE ──────────────────────────
#
# `--rev` and `--commit` exist because "clone this branch" stopped being one
# act the moment four jobs needed it. Every `build` job of `openkal-cross.yml`
# cloned `main` of the index and of the runtime of its own accord, on runners
# that become available at different moments — the macOS leg waits in a queue
# the others do not — and the `run` job then asserted that all four had built
# the same sources, and failed the run when they had not. On 2026-10-13 that
# assertion was right to fail and the change under test had nothing to do with
# it: the run started at 12:43 UTC, its build jobs at 12:52:08 through
# 13:01:33, and mcpp-index@main took four commits between 12:56:12 and
# 13:17:58 — so clones taken minutes apart straddled pushes, and the run job
# reported `index sources differ`.
#
# The repair is to resolve the ref ONCE, at the start of the run, and have
# every host materialise that commit. Writing the SHA into the workflow would
# be the pin nobody is reminded to move that `openkal-cross.yml` warns about in
# its own header, so the resolution is a job — and these are the two primitives
# it needs: ask what a ref names, and get exactly that commit.

# `--rev <ref> <url>`: print the commit the ref names.
#
# `ls-remote` rather than clone-and-rev-parse: what the caller wants is one
# number, and the tree behind it is tens of megabytes on both of the
# repositories this is pointed at.
if [[ "${1:-}" == "--rev" ]]; then
    [ "$#" -eq 3 ] || { echo "git_clone_retry: usage: --rev <ref> <url>" >&2; exit 2; }
    ref="$2"; url="$3"
    # A bare name is a BRANCH. `refs/…` and `HEAD` are taken as written, so a
    # tag or a fully qualified ref can be asked for too.
    case "$ref" in
        refs/*|HEAD) want="$ref" ;;
        *)           want="refs/heads/$ref" ;;
    esac
    for (( i = 1; i <= ATTEMPTS; i++ )); do
        rc=0
        # stderr is NOT captured: what git says about a URL it cannot reach is
        # the diagnostic, and it is the message a plain clone would have shown.
        listing=$(git ls-remote "$url" "$want") || rc=$?
        if (( rc == 0 )); then
            sha=$(printf '%s\n' "$listing" | awk -v w="$want" '$2 == w { print $1; exit }')
            # No such ref is an ANSWER, not a blip: the host was reached and
            # said the ref is not there, so retrying only delays the report.
            [ -n "$sha" ] || { echo "git_clone_retry: $url has no $want" >&2; exit 1; }
            printf '%s\n' "$sha"
            exit 0
        fi
        failed "$i" "$rc"
    done
fi

# `--commit <sha> <url> <dir>`: materialise exactly that commit, and nothing
# the branch did afterwards.
#
# NOT `git clone --branch <sha>`: that argument takes a branch or a tag, and a
# commit is neither. `init` + `fetch --depth 1 origin <sha>` is the shape that
# names a commit, and however far the branch moves after the resolution, it
# costs one commit's tree once.
if [[ "${1:-}" == "--commit" ]]; then
    [ "$#" -eq 4 ] || { echo "git_clone_retry: usage: --commit <sha> <url> <dir>" >&2; exit 2; }
    sha="$2"; url="$3" dest="$4"
    [[ "$sha" =~ ^[0-9a-f]{40}$ ]] \
        || { echo "git_clone_retry: --commit wants a 40-hex commit, got '$sha'" >&2; exit 2; }
    for (( i = 1; i <= ATTEMPTS; i++ )); do
        rc=0
        {
            git -c init.defaultBranch=main init --quiet "$dest" &&
                git -C "$dest" remote add origin "$url" &&
                git -C "$dest" fetch --quiet --depth 1 origin "$sha" &&
                git -C "$dest" checkout --quiet --detach FETCH_HEAD
        } || rc=$?
        if (( rc == 0 )); then
            exit 0
        fi
        # Nothing a failed attempt made survives it, for the reason the clone
        # path gives below about its partial clone: a tree half-made by this
        # attempt is not a retry, it is a second failure with a different cause.
        # And a caller that gives up should not find a directory claiming to be
        # the checkout it asked for.
        rm -rf -- "$dest"
        failed "$i" "$rc"
    done
fi

for (( i = 1; i <= ATTEMPTS; i++ )); do
    rc=0
    git clone "$@" || rc=$?
    if (( rc == 0 )); then
        exit 0
    fi
    # Nothing to remove on the last attempt: there is no retry to prepare for.
    if (( i < ATTEMPTS )) && [[ -n "$dest" && "$dest" != -* && -e "$dest" ]]; then
        echo "git_clone_retry: removing partial '$dest' before retrying" >&2
        rm -rf -- "$dest"
    fi
    failed "$i" "$rc"
done

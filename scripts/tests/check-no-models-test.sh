#!/usr/bin/env bash
# SPDX-License-Identifier: MIT OR Apache-2.0
#
# Tests for scripts/check-no-models.sh and the hooks in .githooks/. Each case
# runs in a throwaway git repository under mktemp (its own index and
# history, never this repository's), with fake files generated here: no real
# model is involved. The hook cases set core.hooksPath of the throwaway
# repository to this repository's .githooks/ and run real git commit, merge
# and push commands there (the push goes to a bare repository under mktemp).
# Usage: scripts/tests/check-no-models-test.sh. Exits non-zero on any failure.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
guard=$here/../check-no-models.sh
hooks=$(cd "$here/../../.githooks" && pwd)

# Isolate from the caller's git: a hook exports GIT_INDEX_FILE and friends,
# and a global excludes file would change what --all sees.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
    GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_PREFIX
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.invalid
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.invalid

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
# The default core.excludesFile is $XDG_CONFIG_HOME/git/ignore, even without
# a global configuration.
export XDG_CONFIG_HOME=$tmp/xdg

fails=0 count=0
ok() { count=$((count + 1)); echo "ok   $1"; }
fail() { count=$((count + 1)); echo "FAIL $1"; fails=$((fails + 1)); }

# Creates a fresh repository with no commits and prints its path. (It runs
# in a command substitution, so the name comes from mktemp, not a counter.)
new_repo() {
    local repo
    repo=$(mktemp -d "$tmp/repo.XXXXXX")
    git init -q -b main "$repo"
    printf 'recipe only\n' >"$repo/README.md"
    printf '%s\n' "$repo"
}

# A repository using this repository's hooks, with README.md committed
# through them.
hooked_repo() {
    local repo
    repo=$(new_repo)
    git -C "$repo" config core.hooksPath "$hooks"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m init >/dev/null 2>&1
    printf '%s\n' "$repo"
}

# expect <pass|fail> <description> <repo> <guard args...> [-- <expected path>]
# The guard must exit 0 (pass) or 1 (fail); for a failure, the expected path
# must be named in its output (a path with control characters as %q shows it).
expect() {
    local want=$1 desc=$2 repo=$3 out status
    shift 3
    local -a args=()
    while (($#)) && [[ $1 != -- ]]; do args+=("$1"); shift; done
    local path=
    if (($#)); then path=$2; fi
    [[ $path != *[[:cntrl:]]* ]] || printf -v path '%q' "$path"
    status=0
    out=$(cd "$repo" && "$guard" "${args[@]}" 2>&1) || status=$?
    if [[ $want == pass ]]; then
        if ((status == 0)); then ok "$desc"; else fail "$desc (exit $status): $out"; fi
    elif ((status != 1)); then
        fail "$desc (exit $status, want 1): $out"
    elif [[ -n $path ]] && ! grep -qF -- "$path:" <<<"$out"; then
        fail "$desc (path $path not reported): $out"
    else
        ok "$desc"
    fi
}

# stage_case <pass|fail> <description> <path> <generator command...>: writes
# the file with the generator (stdout to the file), stages it, runs --staged.
stage_case() {
    local want=$1 desc=$2 path=$3 repo
    shift 3
    repo=$(new_repo)
    mkdir -p "$(dirname "$repo/$path")"
    "$@" >"$repo/$path"
    git -C "$repo" add -f -- "$path" README.md
    expect "$want" "$desc" "$repo" --staged -- "$path"
}

# link_case <pass|fail> <description> <link path> <target>: a staged symlink.
link_case() {
    local want=$1 desc=$2 path=$3 target=$4 repo
    repo=$(new_repo)
    mkdir -p "$(dirname "$repo/$path")"
    ln -s -- "$target" "$repo/$path"
    git -C "$repo" add -f -- "$path"
    expect "$want" "$desc" "$repo" --staged -- "$path"
}

elf() { printf '\177ELF\002\001\001\000'; }
# Fake binary payloads: a protobuf-like ONNX header, a TFLite flatbuffer
# header, a zip local file header.
onnx_like() { printf '\010\007\022\007tf2onnx:\000\n'; }
tflite_like() { printf '\034\000\000\000TFL3\000\000\016\000'; }

# refused <description> <repo> <git args...>: the git command must fail and
# HEAD must not move.
refused() {
    local desc=$1 repo=$2 before out status=0
    shift 2
    before=$(git -C "$repo" rev-parse -q --verify HEAD || true)
    out=$(git -C "$repo" "$@" 2>&1) || status=$?
    if ((status == 0)); then
        fail "$desc: git $* succeeded"
    elif [[ $(git -C "$repo" rev-parse -q --verify HEAD || true) != "$before" ]]; then
        fail "$desc: HEAD moved"
    elif ! grep -qF 'model files, archives and binaries must never be committed' <<<"$out"; then
        fail "$desc: git failed, but not through the guard: $out"
    else
        ok "$desc"
    fi
}

# accepted <description> <repo> <git args...>: the git command must succeed.
accepted() {
    local desc=$1 repo=$2 out
    shift 2
    if out=$(git -C "$repo" "$@" 2>&1); then ok "$desc"; else fail "$desc: $out"; fi
}

echo "== staged (the default), in a repository with no commits"
repo=$(new_repo)
mkdir -p "$repo/scripts" "$repo/convert" "$repo/licenses/modnet"
printf '#!/bin/sh\necho hello\n' >"$repo/scripts/test.sh"
printf 'import onnx\n' >"$repo/convert/fix_tconv.py"
printf '[[models]]\nid = "x"\n' >"$repo/models.toml"
git -C "$repo" add README.md scripts/test.sh convert/fix_tconv.py models.toml
expect pass "clean text files pass" "$repo"
expect pass "clean text files pass (--staged)" "$repo" --staged
expect pass "nothing staged passes" "$(new_repo)"

echo "== paths: models and weights"
for f in model.onnx model.ORT selfie.tflite model.lite saved_model.pb graph.pbtxt keras.h5 m.keras \
    model.pdmodel model.pdiparams model.pdparams model.pdopt weights.pt weights.pth last.ckpt \
    model.safetensors weights.bin arr.npy arr.npz obj.pkl m.engine m.trt m.plan m.mlmodel; do
    stage_case fail "the model or weight file $f fails" "models/$f" printf 'x\n'
done
stage_case fail "an .mlpackage directory fails" m.mlpackage/Manifest.json printf '{}\n'
stage_case fail "a model at the top fails" modnet_photographic.onnx printf 'x\n'

echo "== paths: archives, libraries, documents, logs"
for f in a.zip a.tar a.tar.gz a.tar.xz a.tar.zst a.tgz a.gz a.xz a.zst a.bz2 a.7z x-1.0-py3-none-any.whl; do
    stage_case fail "the archive $f fails" "dl/$f" printf 'x\n'
done
stage_case fail "a .so library fails" lib/x.so printf 'x\n'
stage_case fail "a versioned library fails" lib/libx.so.1.2 printf 'x\n'
stage_case fail "an object file fails" x.o printf 'x\n'
stage_case fail "Python bytecode fails" scripts/lib/models.cpython-312.pyc printf 'x\n'
stage_case fail "a PDF fails" docs/card.pdf printf 'not really a pdf\n'
stage_case fail "a log fails" build-models.log printf 'x\n'

echo "== paths: build output and environments"
stage_case fail "dist/ fails" dist/SHA256SUMS printf 'x\n'
stage_case fail "dist/MANIFEST.toml fails" dist/MANIFEST.toml printf 'schema = 1\n'
stage_case fail "build/ fails" build/work.abc/facts.tsv printf 'x\n'
stage_case fail "Dist/ fails (letter case)" Dist/SHA256SUMS printf 'x\n'
stage_case fail "BUILD/ fails (letter case)" BUILD/build-models.txt printf 'x\n'
stage_case fail "a virtual environment fails" build2/venvs/tflite/pyvenv.cfg printf 'x\n'
stage_case fail "a .venv fails" .venv/pyvenv.cfg printf 'x\n'
stage_case fail "__pycache__ fails" convert/__pycache__/x.txt printf 'x\n'
stage_case pass "docs/dist.md is not dist/" docs/dist.md printf '# notes\n'
stage_case pass "a nested build-notes directory is not build/" docs/build/notes.md printf '# notes\n'
stage_case pass "docs/onnx-notes.md is not a model" docs/onnx-notes.md printf '# notes\n'
stage_case pass "a path with a space passes" "my notes/a b.md" printf 'text\n'
stage_case fail "a model under a directory with a newline fails" $'a\nb/m.onnx' printf 'x\n'
stage_case pass "a clean path with a newline passes" $'a\nb/notes.md' printf 'text\n'

echo "== paths: the repository's own files pass"
for f in README.md NOTICE LICENSE-MIT LICENSE-APACHE models.toml .gitignore requirements/tflite.txt requirements/tflite.lock \
    convert/fix_tconv.py convert/verify_model.py scripts/build-models.sh scripts/lib/common.sh \
    scripts/lib/models.py scripts/check-no-models.sh scripts/test.sh docs/models.md docs/release.md \
    licenses/modnet/LICENSE licenses/modnet/NOTICE; do
    stage_case pass "the repository file $f passes" "$f" printf '# text\n'
done
stage_case pass "the Apache licence text passes" licenses/modnet/LICENSE \
    printf '                              Apache License\n                        Version 2.0, January 2004\n'

echo "== content"
stage_case fail "ELF magic under an innocent name fails" tool.txt elf
stage_case fail "gzip data named notes.txt fails" notes.txt sh -c 'printf "hello\n" | gzip -c'
stage_case fail "zip data under an innocent name fails" data.txt printf 'PK\003\004rest\n'
stage_case fail "an ar archive under an innocent name fails" data.txt printf '!<arch>\nmember/         0           0     0     644     2         `\nx\n'
mkdir -p "$tmp/tarsrc"
printf 'text\n' >"$tmp/tarsrc/member.txt"
stage_case fail "a POSIX tar under an innocent name fails" bundle.dat tar --format=ustar -cf - -C "$tmp/tarsrc" member.txt
stage_case fail "7z magic under an innocent name fails" data.txt printf '7z\274\257\047\034rest\n'
stage_case fail "a TFLite flatbuffer under an innocent name fails" model.txt tflite_like
stage_case fail "an ONNX model (protobuf) under an innocent name fails" model.txt onnx_like
stage_case fail "a NUL byte in the first 8 KiB fails" data.dat printf 'abc\000def\n'
stage_case fail "a text file over 1 MiB fails" big.txt sh -c 'head -c 1048577 /dev/zero | tr "\0" "a"'
stage_case pass "a TOML file passes" models.toml printf 'schema = 1\n[[models]]\nid = "modnet"\n'

repo=$(new_repo)
head -c 1048576 /dev/zero | tr '\0' 'a' >"$repo/exact.txt"
git -C "$repo" add exact.txt
expect pass "a text file of exactly 1 MiB passes" "$repo" --staged

repo=$(new_repo)
printf 'staged content\n' >"$repo/notes.txt"
git -C "$repo" add notes.txt
elf >"$repo/notes.txt"
expect pass "--staged checks the staged content, not the work tree" "$repo" --staged

echo "== symbolic links, submodules, type changes, renames"
link_case pass "a symlink inside the repository passes" docs/readme README.md
link_case pass "a symlink up to the repository root passes" docs/a/readme ../../README.md
link_case fail "a symlink to an absolute path fails" docs/passwd /etc/passwd
link_case fail "a symlink leaving the repository fails" docs/up ../../outside
link_case fail "a symlink leaving through a newline directory fails" $'a\nb/up' ../../x

repo=$(new_repo)
other=$(hooked_repo)
git -C "$repo" update-index --add --cacheinfo "160000,$(git -C "$other" rev-parse HEAD),sub"
expect fail "a submodule (gitlink) fails" "$repo" --staged -- sub

repo=$(new_repo)
ln -s README.md "$repo/tool"
git -C "$repo" add README.md tool
git -C "$repo" commit -q -m init
rm "$repo/tool"
elf >"$repo/tool"
git -C "$repo" add tool
check_status=$(git -C "$repo" diff --cached --name-status)
[[ $check_status == T* ]] || fail "fixture: the change is not a type change: $check_status"
expect fail "a symlink replaced by an ELF (type change T) fails" "$repo" --staged -- tool

repo=$(new_repo)
elf >"$repo/notes.txt"
git -C "$repo" add README.md notes.txt
git -C "$repo" commit -q -m init
git -C "$repo" mv notes.txt renamed.txt
expect fail "a renamed offending file fails" "$repo" --staged -- renamed.txt
repo=$(new_repo)
printf 'x\n' >"$repo/x.txt"
git -C "$repo" add README.md x.txt
git -C "$repo" commit -q -m init
mkdir "$repo/lib"
git -C "$repo" mv x.txt lib/libx.so
expect fail "a rename to a library name fails" "$repo" --staged -- lib/libx.so
git -C "$repo" rm -q --cached lib/libx.so
expect pass "a deletion passes" "$repo" --staged

echo "== --all"
repo=$(new_repo)
printf 'ignored.bin\n' >"$repo/.gitignore"
git -C "$repo" add README.md .gitignore
expect pass "--all passes a clean tree" "$repo" --all
elf >"$repo/ignored.bin"
expect pass "--all does not report ignored files" "$repo" --all
printf 'fake\n' >"$repo/untracked.so"
expect fail "--all catches an untracked, not ignored file" "$repo" --all -- untracked.so
expect pass "--staged ignores the untracked file" "$repo" --staged
repo=$(new_repo)
ln -s /etc/os-release "$repo/os-release"
expect fail "--all catches an absolute symlink" "$repo" --all -- os-release
repo=$(new_repo)
git init -q "$repo/nested"
printf 'x\n' >"$repo/nested/file"
expect fail "--all catches a nested repository" "$repo" --all -- nested
repo=$(new_repo)
onnx_like >"$repo/fx.txt"
expect fail "--all checks the content" "$repo" --all -- fx.txt
repo=$(new_repo)
printf '/dist/\n' >"$repo/.gitignore"
mkdir -p "$repo/dist"
onnx_like >"$repo/dist/m.onnx"
expect pass "--all does not report an ignored dist/" "$repo" --all

echo "== --range"
repo=$(new_repo)
git -C "$repo" add README.md
git -C "$repo" commit -q -m init
elf >"$repo/tool.txt"
git -C "$repo" add tool.txt
git -C "$repo" commit -q -m bad
git -C "$repo" rm -q tool.txt
git -C "$repo" commit -q -m removed >/dev/null 2>&1
expect pass "--range of the first commit passes" "$repo" --range HEAD~2
expect fail "--range sees a file a later commit deleted" "$repo" --range HEAD~2..HEAD -- tool.txt
expect fail "--range with --not --remotes and no remote checks every commit" "$repo" \
    --range main --not --remotes=origin -- tool.txt
expect pass "--range of the deletion alone passes" "$repo" --range HEAD~1..HEAD
status=0
(cd "$repo" && "$guard" --range no-such-rev >/dev/null 2>&1) || status=$?
if ((status == 2)); then ok "--range of an unknown revision exits 2"; else fail "--range of an unknown revision exits $status, want 2"; fi

echo "== hooks: git commit"
repo=$(hooked_repo)
ok "a clean first commit goes through the hook"
printf 'more\n' >>"$repo/README.md"
git -C "$repo" add README.md
accepted "a clean commit goes through the hook" "$repo" commit -q -m clean
elf >"$repo/tool.txt"
git -C "$repo" add tool.txt
refused "git commit of a staged ELF is refused" "$repo" commit -q -m bad
git -C "$repo" rm -q --cached tool.txt
rm "$repo/tool.txt"

printf 'notes\n' >"$repo/notes.txt"
git -C "$repo" add notes.txt
accepted "a clean notes.txt is committed" "$repo" commit -q -m notes
elf >"$repo/notes.txt"
refused "git commit -a of a modified file turned ELF is refused" "$repo" commit -q -a -m bad
refused "git commit <path> of an unstaged ELF is refused" "$repo" commit -q -m bad notes.txt
printf 'notes, edited\n' >"$repo/notes.txt"
git -C "$repo" add notes.txt
onnx_like >"$repo/notes.txt"
refused "git commit <path> checks the work tree file, not the clean staged one" "$repo" \
    commit -q -m bad notes.txt
printf 'notes, edited again\n' >"$repo/notes.txt"
accepted "a clean git commit -a passes" "$repo" commit -q -a -m edit
git -C "$repo" update-index --add --cacheinfo "160000,$(git -C "$repo" rev-parse HEAD),sub"
refused "git commit of a submodule is refused" "$repo" commit -q -m sub
git -C "$repo" rm -q --cached sub

echo "== hooks: git merge (pre-merge-commit)"
repo=$(hooked_repo)
git -C "$repo" worktree add -q -b side "$tmp/side.wt" >/dev/null 2>&1
elf >"$tmp/side.wt/tool.txt"
git -C "$tmp/side.wt" add tool.txt
accepted "the side branch commits with --no-verify" "$tmp/side.wt" commit -q --no-verify -m side
printf 'main\n' >"$repo/main.txt"
git -C "$repo" add main.txt
accepted "main moves on through the hook" "$repo" commit -q -m main
refused "a merge bringing the side branch's ELF is refused" "$repo" merge -q --no-ff -m merge side
git -C "$repo" merge --abort >/dev/null 2>&1 || true
git -C "$tmp/side.wt" rm -q tool.txt
printf 'side\n' >"$tmp/side.wt/side.txt"
git -C "$tmp/side.wt" add side.txt
git -C "$tmp/side.wt" commit -q -m clean >/dev/null 2>&1
accepted "a merge of a cleaned side branch passes" "$repo" merge -q --no-ff -m merge side

echo "== hooks: git push (pre-push)"
remote=$tmp/remote.git
git init -q --bare "$remote"
repo=$(hooked_repo)
git -C "$repo" remote add origin "$remote"
elf >"$repo/tool.txt"
git -C "$repo" add tool.txt
git -C "$repo" commit -q --no-verify -m bad
git -C "$repo" rm -q tool.txt
git -C "$repo" commit -q -m removed >/dev/null 2>&1
refused "pushing a new branch whose history holds an ELF is refused" "$repo" push -q origin main
if git -C "$remote" rev-parse -q --verify refs/heads/main >/dev/null; then
    fail "the refused push created main on the remote"
else
    ok "the refused push left the remote empty"
fi
expect fail "--range main --not --remotes=origin finds it with no remote-tracking ref" "$repo" \
    --range main --not --remotes=origin -- tool.txt

repo=$(hooked_repo)
git -C "$repo" remote add origin "$remote"
accepted "pushing a clean new branch passes" "$repo" push -q origin main
printf 'more\n' >>"$repo/README.md"
git -C "$repo" commit -q -a -m more >/dev/null 2>&1
accepted "pushing a clean update passes" "$repo" push -q origin main
pushed=$(git -C "$repo" rev-parse HEAD)
printf 'x\n' >"$repo/libx.so"
git -C "$repo" add -f libx.so
git -C "$repo" commit -q --no-verify -m bad
refused "pushing an update that adds a library is refused" "$repo" push -q origin main
if [[ $(git -C "$remote" rev-parse refs/heads/main) == "$pushed" ]]; then
    ok "the remote keeps the last clean commit"
else
    fail "the refused push moved the remote"
fi

echo "== usage"
status=0
(cd "$(new_repo)" && "$guard" --bogus >/dev/null 2>&1) || status=$?
if ((status == 2)); then ok "an unknown option exits 2"; else fail "an unknown option exits $status, want 2"; fi
status=0
(cd "$(new_repo)" && "$guard" --range >/dev/null 2>&1) || status=$?
if ((status == 2)); then ok "--range without a revision exits 2"; else fail "--range without a revision exits $status, want 2"; fi

if ((fails > 0)); then
    echo "$fails of $count check(s) failed"
    exit 1
fi
echo "all $count checks passed"

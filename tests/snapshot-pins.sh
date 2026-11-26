#!/bin/sh
# The dotnet, brave and electron snapshots run downloaded code on the host. With a pinned checksum or commit that
# does not match, none of it may run; with matching ones, the script goes on. curl, git and node are stand-ins on
# PATH: nothing is downloaded.
set -u
cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
W=$(mktemp -d) || exit 1
trap 'rm -rf "$W"' EXIT
mkdir -p "$W/bin" "$W/serve"
export SERVE="$W/serve" RAN="$W/ran"
fail=0
bad() { echo "FAIL: $1"; fail=1; }

# curl: writes the file in $SERVE named like the URL's last part to -o's argument
cat > "$W/bin/curl" <<'EOS'
#!/bin/sh
out= url=
while [ $# -gt 0 ]; do
    case $1 in -o) out=$2; shift ;; https://*) url=$1 ;; --proto|--proto-redir|--retry) shift ;; esac
    shift
done
if [ -n "$out" ]; then cp "$SERVE/${url##*/}" "$out"; else cat "$SERVE/${url##*/}"; fi
EOS
# git: fetches nothing; rev-parse HEAD says what $SERVE/head says; checkout of brave-core leaves an empty DEPS
cat > "$W/bin/git" <<'EOS'
#!/bin/sh
dir=.
while :; do case ${1-} in -C) dir=$2; shift 2 ;; -c) shift 2 ;; *) break ;; esac; done
case ${1-} in
    init) shift; [ "$1" = -q ] && shift; mkdir -p "$1/.git" ;;
    checkout) printf 'vars = {}\ndeps = {}\n' > "$dir/DEPS" ;;
    rev-parse) cat "$SERVE/head" 2>/dev/null || exit 1 ;;
    log) echo 0 ;;
    config) echo dk@example.invalid ;;
esac
exit 0
EOS
printf '#!/bin/sh\necho "node $1" >> "$RAN"\nexit 1\n' > "$W/bin/node"
chmod +x "$W/bin/"*
run() { rm -f "$RAN"; PATH="$W/bin:$PATH" sh "$ROOT/src/scripts/snapshot-$1.sh" "$W/out.tar.zst" "$W/work-$1" "$2" "$3" "$4" "$5" "${6-}" > "$W/log" 2>&1; }
sum() { "$1" "$2" | cut -d' ' -f1; }

# --- dotnet: the source archive's own script, then the SDK
mkdir -p "$W/vmr/dotnet-x"
printf '#!/bin/sh\necho prep >> "$RAN"\nmkdir -p prereqs\n' > "$W/vmr/dotnet-x/prep-source-build.sh"; chmod +x "$W/vmr/dotnet-x/prep-source-build.sh"
tar -C "$W/vmr" -czf "$SERVE/abc123.tar.gz" dotnet-x
mkdir -p "$W/sdk"; echo sdk > "$W/sdk/dotnet"; tar -C "$W/sdk" -czf "$SERVE/dotnet-sdk-1.0-linux-musl-x64.tar.gz" dotnet
V=$(sum sha256sum "$SERVE/abc123.tar.gz"); K=$(sum sha512sum "$SERVE/dotnet-sdk-1.0-linux-musl-x64.tar.gz")
run dotnet v1 1.0 abc123 0000 "$K" && bad "dotnet: a wrong archive checksum was accepted"
[ ! -e "$RAN" ] || bad "dotnet: code from an unverified source archive ran"
rm -rf "$W/work-dotnet"
run dotnet v1 1.0 abc123 "$V" 0000 && bad "dotnet: a wrong SDK checksum was accepted"
[ ! -e "$W/work-dotnet/src/.dotnet-musl/dotnet" ] || bad "dotnet: an unverified SDK was unpacked"
rm -rf "$W/work-dotnet"
run dotnet v1 1.0 abc123 "$V" "$K" || { cat "$W/log"; bad "dotnet: matching pins did not work"; }
grep -qx prep "$RAN" 2>/dev/null || bad "dotnet: the verified source's script did not run"

# --- brave: pnpm is run by node
mkdir -p "$W/pn/package/bin"; echo x > "$W/pn/package/bin/pnpm.mjs"; tar -C "$W/pn" -czf "$SERVE/pnpm-9.9.9.tgz" package
I="sha512-$(openssl dgst -sha512 -binary "$SERVE/pnpm-9.9.9.tgz" | base64 | tr -d '\n')"
echo 1111111111111111111111111111111111111111 > "$SERVE/head"
run brave v1 9.9.9 1111111111111111111111111111111111111111 sha512-WRONG && bad "brave: a wrong pnpm integrity was accepted"
[ ! -e "$RAN" ] || bad "brave: node ran an unverified pnpm"
[ ! -e "$W/work-brave/pnpm/package" ] || bad "brave: an unverified pnpm was unpacked"
run brave v1 9.9.9 1111111111111111111111111111111111111111 "$I"   # (the stand-in node then fails: far enough)
grep -q 'pnpm.mjs' "$RAN" 2>/dev/null || { cat "$W/log"; bad "brave: the verified pnpm was not run"; }

# --- electron: nothing from a checkout at another commit runs
D=2222222222222222222222222222222222222222
mkdir -p "$W/work-electron"
echo 3333333333333333333333333333333333333333 > "$SERVE/head"
printf '#!/bin/sh\necho "python3 $*" >> "$RAN"\nexit 1\n' > "$W/bin/python3"; chmod +x "$W/bin/python3"
run electron v1 1.2.3 $D 4444444444444444444444444444444444444444 5555555555555555555555555555555555555555 \
    && bad "electron: a checkout at another commit was accepted"
[ ! -e "$RAN" ] || bad "electron: a script from an unverified checkout ran: $(cat "$RAN")"
grep -q 'pinned' "$W/log" || { cat "$W/log"; bad "electron: it did not say why it stopped"; }

# --- dart: the same
mkdir -p "$W/work-dart"
run dart 1.0 $D 5555555555555555555555555555555555555555 '' && bad "dart: a checkout at another commit was accepted"
[ ! -e "$RAN" ] || bad "dart: a script from an unverified checkout ran: $(cat "$RAN")"

# --- too few arguments are an error, not a fetch by tag
run brave v1 9.9.9 '' '' && bad "brave: ran without pins"
grep -q 'refs/tags' "$ROOT/src/scripts/snapshot-electron.sh" "$ROOT/src/scripts/snapshot-brave.sh" | grep -q fetch && bad "a tag is still fetched"
[ $fail = 0 ] && echo "ok: nothing downloaded runs unless it matches its pin"
exit $fail

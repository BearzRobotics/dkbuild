#!/bin/sh
# The DEPS readers of the snapshot scripts: DEPS comes from upstream, and what it says goes to `git fetch` and (the
# paths) to `rm -rf` on the host. A URL must be https, nothing may be read as an option, a path stays inside.
set -u
cd "$(dirname "$0")/.." || exit 1
W=$(mktemp -d) || exit 1
trap 'rm -rf "$W"' EXIT
fail=0
R=0123456789012345678901234567890123456789
for s in brave euro-office; do
    # the script's own reader: the python between the line that runs it and EOF
    sed -n "/^python3 -I - .*DEPS > deps.txt <<'EOF'\$/,/^EOF\$/p" "src/scripts/snapshot-$s.sh" | sed '1d;$d' > "$W/read.py"
    [ -s "$W/read.py" ] || { echo "FAIL: no DEPS reader found in snapshot-$s.sh"; exit 1; }
    case $s in
        brave) ok_paths='third_party/x' ;;
        *) ok_paths='build buildtools base/trace_event/common third_party/googletest/src third_party/icu third_party/jinja2 third_party/markupsafe third_party/zlib tools/clang' ;;
    esac
    deps() { # deps PATH VALUE: a DEPS with every wanted path honest, then PATH = VALUE
        { echo 'vars = {"git": "https://example.invalid"}'
          echo 'deps = {'
          for q in $ok_paths; do [ "$q" = "$1" ] || echo "  \"$q\": Var(\"git\") + \"/r.git@$R\","; done
          printf '  "%s": "%s",\n}\n' "$1" "$2"; } > "$W/DEPS"
    }
    first=${ok_paths%% *}
    deps "$first" "https://example.invalid/a.git@$R"
    python3 -I "$W/read.py" "$W/DEPS" > "$W/out" 2>"$W/err" || { cat "$W/err"; echo "FAIL: $s: an honest DEPS was refused"; fail=1; }
    deps "$first" "https://example.invalid/a.git@refs/tags/v1.2.3"
    python3 -I "$W/read.py" "$W/DEPS" >/dev/null 2>&1 || { echo "FAIL: $s: a tag was refused"; fail=1; }
    for bad in "--upload-pack=touch\${IFS}x;false@." "ext::sh -c id@$R" "file:///etc@$R" "git@example.invalid:a.git@$R" \
               "https://example.invalid/a.git@--upload-pack=x" "https://example.invalid/a b@$R"; do
        deps "$first" "$bad"
        python3 -I "$W/read.py" "$W/DEPS" >/dev/null 2>&1 && { echo "FAIL: $s: accepted '$bad'"; fail=1; }
    done
    if [ "$s" = brave ]; then
        for p in '../../x' '/etc/x' 'a/../../x' '-rf' 'a b'; do
            deps "$p" "https://example.invalid/a.git@$R"
            python3 -I "$W/read.py" "$W/DEPS" >/dev/null 2>&1 && { echo "FAIL: $s: accepted the path '$p'"; fail=1; }
        done
    fi
    grep -q '^export GIT_ALLOW_PROTOCOL=https$' "src/scripts/snapshot-$s.sh" || { echo "FAIL: $s: git may use other protocols"; fail=1; }
done
[ $fail = 0 ] && echo "ok: the DEPS readers pass only https URLs, plain revisions and paths inside the checkout"
exit $fail

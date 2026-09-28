#!/usr/bin/env bash
# Stand-in for ps2fpkg used by the test suite. Builds a tiny fake PKG named
# the way the real tool does, and fails for inputs with "BROKEN" in the name.
set -u
iso="$1"; shift
out="out" title=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift ;;
        -t) title="$2"; shift ;;
    esac
    shift
done
echo "fake ps2fpkg: $iso title=$title" >>"${FAKE_PS2FPKG_LOG:-/dev/null}"
case "$iso" in
    *BROKEN*) echo "error: unsupported disc image" >&2; exit 1 ;;
esac
re='([A-Z]{4})[-_]([0-9]{3})\.?([0-9]{2})'
tid="NOID00000"
[[ $iso =~ $re ]] && tid="${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
mkdir -p "$out"
head -c 2048 /dev/zero >"$out/UP9000-${tid}_00-${tid}0000001.pkg"

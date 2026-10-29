#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if pgrep -x PDFReader >/dev/null; then
    echo "PDF Reader를 종료한 뒤 다시 실행해 주세요." >&2
    exit 1
fi
sh scripts/build.sh
ditto "build/.staging.noindex/PDF Reader.app" "/Applications/PDF Reader.app"
open "/Applications/PDF Reader.app"

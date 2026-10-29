#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if pgrep -x 'PDFReader|ChatPDF' >/dev/null; then
    echo "ChatPDF를 종료한 뒤 다시 실행해 주세요." >&2
    exit 1
fi
sh scripts/build.sh
ditto "build/.staging.noindex/ChatPDF.app" "/Applications/ChatPDF.app"
open "/Applications/ChatPDF.app"

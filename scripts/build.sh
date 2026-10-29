#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build -c release
rm -rf "build/.staging.noindex/ChatPDF.app"
mkdir -p "build/.staging.noindex/ChatPDF.app/Contents/MacOS" "build/.staging.noindex/ChatPDF.app/Contents/Resources"
cp .build/release/ChatPDF "build/.staging.noindex/ChatPDF.app/Contents/MacOS/ChatPDF"
strip -S "build/.staging.noindex/ChatPDF.app/Contents/MacOS/ChatPDF"
cp Resources/Info.plist "build/.staging.noindex/ChatPDF.app/Contents/Info.plist"
cp LICENSE NOTICE "build/.staging.noindex/ChatPDF.app/Contents/Resources/"
swift scripts/GenerateAssets.swift
iconutil -c icns build/AppIcon.iconset -o "build/.staging.noindex/ChatPDF.app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "build/.staging.noindex/ChatPDF.app"

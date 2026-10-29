#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
swift build -c release
mkdir -p "build/.staging.noindex/PDF Reader.app/Contents/MacOS" "build/.staging.noindex/PDF Reader.app/Contents/Resources"
cp .build/release/PDFReader "build/.staging.noindex/PDF Reader.app/Contents/MacOS/PDFReader"
cp Resources/Info.plist "build/.staging.noindex/PDF Reader.app/Contents/Info.plist"
swift scripts/GenerateAssets.swift
iconutil -c icns build/AppIcon.iconset -o "build/.staging.noindex/PDF Reader.app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "build/.staging.noindex/PDF Reader.app"

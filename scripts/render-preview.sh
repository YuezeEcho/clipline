#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/toolchain-env.sh
SOURCES=(Sources/Tendedero/*.swift)
PREVIEW_SOURCES=()
for file in "${SOURCES[@]}"; do
  case "$file" in */main.swift|*/AppDelegate.swift) ;; *) PREVIEW_SOURCES+=("$file");; esac
done
swiftc "${CLIPLINE_SWIFT_FLAGS[@]}" -whole-module-optimization -parse-as-library \
  "${PREVIEW_SOURCES[@]}" Tests/RenderPreview.swift -o .build/render-preview
mkdir -p build
.build/render-preview "$PWD/build" -AppleLanguages '(zh-Hans)'

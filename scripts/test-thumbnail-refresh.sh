#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/toolchain-env.sh
sources=()
for file in Sources/Tendedero/*.swift; do
  case "$file" in
    Sources/Tendedero/main.swift|Sources/Tendedero/AppDelegate.swift) ;;
    *) sources+=("$file") ;;
  esac
done
swiftc "${CLIPLINE_SWIFT_FLAGS[@]}" -whole-module-optimization -parse-as-library \
  "${sources[@]}" Tests/ThumbnailRefreshChecks.swift -o .build/thumbnail-refresh-checks
.build/thumbnail-refresh-checks

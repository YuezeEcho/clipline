#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/toolchain-env.sh
sources=()
for file in Sources/Tendedero/*.swift; do
  case "$file" in */main.swift|*/AppDelegate.swift) ;; *) sources+=("$file");; esac
done
swiftc "${CLIPLINE_SWIFT_FLAGS[@]}" -whole-module-optimization -parse-as-library \
  "${sources[@]}" Tests/CaptureLibraryChecks.swift -o .build/capture-library-checks
.build/capture-library-checks

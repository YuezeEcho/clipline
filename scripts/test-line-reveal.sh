#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/toolchain-env.sh
sources=()
for file in Sources/Tendedero/*.swift; do
  case "$file" in */main.swift|*/AppDelegate.swift) ;; *) sources+=("$file");; esac
done
swiftc "${CLIPLINE_SWIFT_FLAGS[@]}" -whole-module-optimization -parse-as-library \
  "${sources[@]}" Tests/LineRevealChecks.swift -o .build/line-reveal-checks
.build/line-reveal-checks

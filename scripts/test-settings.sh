#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/toolchain-env.sh
SOURCES=(Sources/Tendedero/*.swift)
CHECK_SOURCES=()
for file in "${SOURCES[@]}"; do
  case "$file" in */main.swift|*/AppDelegate.swift) ;; *) CHECK_SOURCES+=("$file");; esac
done
swiftc "${CLIPLINE_SWIFT_FLAGS[@]}" -whole-module-optimization -parse-as-library \
  "${CHECK_SOURCES[@]}" Tests/SettingsChecks.swift -o .build/settings-checks
.build/settings-checks

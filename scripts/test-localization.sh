#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/toolchain-env.sh
swiftc "${CLIPLINE_SWIFT_FLAGS[@]}" -whole-module-optimization -parse-as-library \
  Sources/Tendedero/Localization.swift Tests/LocalizationChecks.swift \
  -o .build/localization-checks
.build/localization-checks

#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/toolchain-env.sh
swiftc "${CLIPLINE_SWIFT_FLAGS[@]}" -whole-module-optimization -parse-as-library \
  Sources/Tendedero/ScrollSway.swift Tests/ScrollSwayChecks.swift -o .build/scroll-sway-checks
.build/scroll-sway-checks

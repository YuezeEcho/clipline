#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/toolchain-env.sh
swiftc "${CLIPLINE_SWIFT_FLAGS[@]}" -whole-module-optimization -parse-as-library \
  Sources/Tendedero/TopEdgeTrigger.swift Sources/Tendedero/MenuBarHitTest.swift Sources/Tendedero/MenuBarClickMonitor.swift Tests/TopEdgeTriggerChecks.swift -o .build/top-edge-checks
.build/top-edge-checks

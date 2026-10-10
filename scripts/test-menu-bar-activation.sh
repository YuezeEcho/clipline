#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/toolchain-env.sh
swiftc "${CLIPLINE_SWIFT_FLAGS[@]}" -whole-module-optimization -parse-as-library \
  Sources/Tendedero/TopEdgeTrigger.swift Sources/Tendedero/MenuBarHitTest.swift \
  Sources/Tendedero/MenuBarActivation.swift Tests/MenuBarActivationChecks.swift -o .build/menu-bar-activation-checks
.build/menu-bar-activation-checks

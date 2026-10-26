#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/tests
swiftc -swift-version 5 Sources/LibreDesktop/Glucose.swift Sources/LibreDesktop/LibreClient.swift \
    tests/LibreTests.swift -o build/tests/libre-tests
build/tests/libre-tests
swiftc -swift-version 5 Sources/LibreDesktop/Glucose.swift Sources/LibreDesktop/GlucoseHistory.swift \
    Sources/LibreDesktop/LibreClient.swift Sources/LibreDesktop/LibreViewClient.swift \
    Sources/LibreDesktop/LibreHistoryArchive.swift tests/LibreHistoryTests.swift \
    -o build/tests/libre-history-tests
build/tests/libre-history-tests

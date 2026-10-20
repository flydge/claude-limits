#!/bin/bash
# Builds and runs the LimitsCore tests. Run: bash menubar/test.sh
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p ../build
swiftc -o ../build/limits-core-tests Sources/LimitsCore.swift Tests/main.swift
../build/limits-core-tests

#!/bin/bash
# Runs the unit tests with only the Command Line Tools installed.
# `swift test` needs Swift Testing's macro plugin, which ships with full Xcode only, so this
# rewrites the test file into plain functions, compiles it with the non-UI sources, and runs it.
set -euo pipefail
cd "$(dirname "$0")/.."

WORK="$(mktemp -d "${TMPDIR:-/tmp}/portkit-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

sed -e '/^import Testing/d' -e '/^@testable import/d' \
    -e 's/@Suite struct/struct/' -e 's/@Test func/func/' \
    -e 's/#expect(/expect(/g' -e 's/Issue.record(/record(/' \
    Tests/PortKitTests/PortKitTests.swift > "$WORK/tests.swift"

{
  cat <<'SWIFT'
import Foundation
var failures = 0, current = ""
func expect(_ ok: Bool, line: Int = #line) { if !ok { failures += 1; print("  ✖ \(current) (line \(line))") } }
func record(_ msg: String) { failures += 1; print("  ✖ \(current): \(msg)") }
func run(_ name: String, _ body: () throws -> Void) {
    current = name
    let before = failures
    do { try body() } catch { failures += 1; print("  ✖ \(name) threw \(error)") }
    print(failures == before ? "✔ \(name)" : "✖ \(name)")
}
SWIFT
  awk '/^struct [A-Za-z]+/ { suite = $2 }
       /^    func [A-Za-z]+\(\)/ { name = $2; sub(/\(.*/, "", name); printf "run(\"%s.%s\") { try %s().%s() }\n", suite, name, suite, name }' \
    "$WORK/tests.swift"
  echo 'print(failures == 0 ? "All tests passed." : "\(failures) failure(s).")'
  echo 'exit(failures == 0 ? 0 : 1)'
} > "$WORK/main.swift"

SOURCES=$(ls Sources/PortKit/*.swift | grep -v -e Views.swift -e AppModel.swift)
# shellcheck disable=SC2086
swiftc -module-name PortKitTestHarness -o "$WORK/run" $SOURCES "$WORK/tests.swift" "$WORK/main.swift"
TMPDIR="$WORK" "$WORK/run"

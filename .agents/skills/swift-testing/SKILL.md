---
name: swift-testing
description: Apply this repository's Swift test conventions. Use when creating, editing, organizing, running, or reviewing Swift tests, test targets, test fixtures, or test-support code in ios, shared, or desktop.
---

# Swift Testing

Organize Swift tests consistently across the repository. Apply the framework and runner requirements below specifically to iOS tests.

## Test organization

- Scope each Swift test file to exactly one production source file and name the test file after that source. Never combine tests for several production source files in one test file.
- Apply the repository's `$swift-style` conventions to test files.
- Apply `$swift-data` as well when testing records, persistence, migrations, or queries.

## iOS tests

- Use Swift Testing: import `Testing`, add `@Suite` when useful, and mark test cases with `@Test`.
- Do not use `XCTest` or `XCTestCase` unless an external API forces it.
- Run native module tests with `mise -C ios run test` from the repository root or `mise run test` from `ios/`.
- Add iOS test targets as unit-test bundle targets in `ios/project.yml` and let XcodeGen wire them into the workspace.
- Do not assume `swift test` is the default runner for app modules. Use it deliberately only for platform-independent foundation code.

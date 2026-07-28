# iOS Agent Notes

The native app lives here and is SwiftUI/TCA-first.

Before iOS work, use every repo-local skill matching the task:

- `$ios-development` for the toolchain, builds, XcodeGen, targets, packages, and module structure.
- `$swift-style` for every Swift source or test file.
- `$swiftui` for views, previews, styling, layout, animation, feedback, and presentation.
- `$modern-uikit` for collection views, hosted SwiftUI rows, scroll behavior, and UIKit performance validation.
- `$tca` for feature domains, reducers, bindings, effects, dependencies, and navigation.
- `$swift-data` for records, persistence, database access, and typed queries.
- `$swift-testing` for tests, test targets, fixtures, and test-support code.

Use all matching skills together when a change crosses concerns. Continue to
follow the repository-wide product, collaboration, and Conductor integration
guidance in the root `AGENTS.md`.

## Conductor Cloud API

The Conductor API base URL is `https://api.conductor.build/v0`. Fetch the
current OpenAPI contract from `https://api.conductor.build/v0/openapi.json`
before changing the Cloud client, including its accepted agent and model IDs.

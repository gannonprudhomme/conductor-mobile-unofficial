# iOS Agent Notes

The native iOS app lives here and is SwiftUI/TCA-first.

- Use Xcode 26.5 and iOS 26 as the minimum deployment target.
- Use Swift 6 language mode everywhere. Keep strict concurrency enabled.
- Do not add Bazel yet. The current build entry points are
  `mise -C ios run gen` and `mise -C ios run build` from the repo root, or
  `mise run gen` and `mise run build` from `ios/`.
- Run native module tests with `mise -C ios run test` from the repo root, or
  `mise run test` from `ios/`.
- Use Swift Testing for iOS tests: `import Testing`, `@Suite` when useful, and
  `@Test` for test cases. Do not use `XCTest`/`XCTestCase` unless an external
  API forces it.
- Add iOS test targets as unit-test bundle targets in `ios/project.yml` and let
  XcodeGen wire them into the workspace. Do not assume `swift test` is the
  default runner for app modules, though it can be used deliberately for
  platform-independent foundation code.
- Use XcodeBuildMCP to build, run, and visually inspect SwiftUI changes in the
  simulator whenever possible.
- Use XcodeGen as the source of truth for the app project. Edit
  `ios/project.yml`, then run `mise -C ios run gen`.
- Keep `ios/ConductorMobile.xcworkspace` checked in. It includes the generated
  app project and local Swift package modules so modules can be built
  individually.
- Keep `ConductorMobile` as a thin app target. It should bootstrap dependencies
  and render `ConductorMain.MainView`.
- Put app code in local Swift package modules under `ios/Modules`.
- Follow the MovieRating module shape: foundation modules under
  `ios/Modules/Foundations` and feature modules under `ios/Modules`.
- Keep a single Swift package manifest at `ios/Modules/Package.swift` for all
  iOS modules.
- Put persistence, SQLiteData schema, and migrations in `ConductorData`.
- Put feature state/actions/reducers/views in feature modules such as
  `ConductorWorkspaces`.
- Use SwiftUI all the way down.
- Use the `ConductorDesign` theme for all colors and fonts: `.theme(_:)`
  (`ThemeColorStyle`/`ThemeFontStyle`), e.g. `.foregroundStyle(.theme(.textPrimary))`,
  `.background(.theme(.background))`, `.font(.theme(.body))`. Never use Apple's
  platform colors (`.secondary`, `Color.gray`, `.primary`, etc.) or system fonts
  (`.caption`, `.body`) directly in app UI.
- All screens are dark mode only. We do not support light mode. Force dark mode in
  previews with `.preferredColorScheme(.dark)`.
- Use `@ScaledMetric` for manually sized SwiftUI images so image dimensions
  scale with Dynamic Type.
- When presenting runtime errors to users, use an alert title that states what
  failed in user terms, and put `error.localizedDescription` in the alert
  message/description.
- When a repeated row/cell or expensive region depends on model data, prefer a
  dedicated child `View` that takes the model instead of a helper function or
  computed view fragment. Child views give SwiftUI smaller invalidation
  boundaries and better rerender behavior.
- Use the Composable Architecture for feature state/actions/reducers.
- Use modern TCA: `@Reducer`, `@ObservableState`, `StoreOf`, scoped stores, and
  no legacy `ViewStore`/`WithViewStore`.
- Use Point-Free Dependencies for controllable dependencies and previews.
- Use Swift Navigation helpers for navigation and presentation once flows exist.
- Use SQLiteData and StructuredQueries-style schema/query APIs for persistence.
  Avoid ad hoc SQLite access in SwiftUI views.
- For externally-defined string states that are decoded, encoded, or persisted
  from Conductor, prefer `RawRepresentable` structs with static known values
  over Swift enums. This preserves unknown future values while still allowing
  ergonomic comparisons and pattern matching for known cases.

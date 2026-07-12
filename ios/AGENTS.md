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
- Begin every Swift file with the standard Xcode filename, module, and creator
  comment header used by existing files.
- Follow the MovieRating module shape: foundation modules under
  `ios/Modules/Foundations` and feature modules under `ios/Modules`.
- Keep a single Swift package manifest at `ios/Modules/Package.swift` for all
  iOS modules.
- Put persistence, SQLiteData schema, and migrations in `ConductorData`.
- Put feature state/actions/reducers/views in feature modules such as
  `ConductorWorkspaces`.
- Use SwiftUI all the way down.
- For remote images, always use `CachedAsyncImage` from `ConductorDesign`.
  Never use SwiftUI's `AsyncImage` directly.
- Within SwiftUI result-builder closures, place a blank line between sibling
  view declarations. Keep each view's modifier chain together without blank
  lines.
- Indent modifiers beneath the view they modify, including row modifiers inside
  `List` and `ForEach` closures.
- Use `EdgeInsets(vertical:horizontal:)` for paired vertical and horizontal
  padding. Do not chain separate `.padding(.vertical, ...)` and
  `.padding(.horizontal, ...)` modifiers.
- When a background needs a shape, pass the style and shape directly to
  `.background(_:in:)`, such as `.background(.theme(.highlight), in: .capsule)`.
  Do not build a shape and call `.fill` inside a background closure.
- For incrementing or decrementing numeric text, prefer
  `.contentTransition(.numericText(value:))` and animate value changes unless
  that transition would misrepresent the content.
- Keep sensory feedback data-driven whenever possible. Prefer triggering it
  from the raw state that represents the interaction, with a condition when
  needed; use a separately incremented trigger only when no meaningful state
  change can drive the feedback.
- For a raw sheet or full-screen-cover dismissal control, use
  `Button(role: .close)` inside a `ToolbarItem` with `.cancellationAction`
  placement.
- Every app-level `ProgressView` must use `.progressViewStyle(.conductor(...))`
  and an explicit themed color. Never use the platform-default progress style
  directly in app UI.
- Give toolbar titles and primary toolbar icons an explicit
  `.foregroundStyle(.theme(.textPrimary))`. Never rely on the system toolbar
  tint for app toolbar content.
- Keep the first `if`/`guard` condition on the same line as the keyword and the
  opening brace on the same line as the final condition. Do not put a bare
  `if`/`guard` or opening brace on its own line.
- Prefer `if` and `switch` expressions when their branches select a value, such
  as `let owner = if ...`, instead of assigning to the value in each branch.
- Use the `ConductorDesign` theme for all colors and fonts: `.theme(_:)`
  (`ThemeColorStyle`/`ThemeFontStyle`), e.g. `.foregroundStyle(.theme(.textPrimary))`,
  `.background(.theme(.background))`, `.font(.theme(.body))`. Never use Apple's
  platform colors (`.secondary`, `Color.gray`, `.primary`, etc.) or system fonts
  (`.caption`, `.body`) directly in app UI.
- All screens are dark mode only. We do not support light mode. Force dark mode in
  previews with `.preferredColorScheme(.dark)`.
- Use `@ScaledMetric` for manually sized SwiftUI images so image dimensions
  scale with Dynamic Type.
- Annotate stored button action closures with `@MainActor`, such as
  `let action: @MainActor () -> Void`.
- Never use `Spacer` to pin content in a layout. Set an explicit frame alignment
  on the content or container instead.
- Keep primary screen content mounted while showing full-screen loading or status
  UI in an `.overlay`. Do not replace the screen with an `if`/`else` loading branch.
    - This makes the animation from not loaded -> loaded more smooth
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
- Handle `.task` first in reducer action switches.
- Capture feature state needed by an effect directly in the `.run` capture
  list, e.g. `.run { [id = state.id] send in ... }`.
- When a feature has multiple mutually exclusive presentations, such as an
  alert and a sheet, model them with one `@Presents var destination` and a
  nested `@Reducer enum Destination`.
- Use Point-Free Dependencies for controllable dependencies and previews.
- Use Swift Navigation helpers for navigation and presentation once flows exist.
- Use SQLiteData and StructuredQueries-style schema/query APIs for persistence.
  Avoid ad hoc SQLite access in SwiftUI views.
- Observe database-backed detail records with `@FetchOne`, seeded with the value
  used for navigation, so workspace or repository updates refresh the detail UI.
- Always sort and filter SQLite-backed feature data in SQLiteData/StructuredQueries
  queries, including dynamic `@FetchAll`/`@Fetch` reloads for active filters.
  Never sort or filter those database results with computed Swift arrays in
  feature state or views.
- For externally-defined string states that are decoded, encoded, or persisted
  from Conductor, prefer `RawRepresentable` structs with static known values
  over Swift enums. This preserves unknown future values while still allowing
  ergonomic comparisons and pattern matching for known cases.

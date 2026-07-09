# iOS Agent Notes

The native iOS app lives here and is SwiftUI/TCA-first.

- Use Xcode 26.5 and iOS 26 as the minimum deployment target.
- Use Swift 6 language mode everywhere. Keep strict concurrency enabled.
- Do not add Bazel yet. The current build entry points are
  `mise -C ios run gen` and `mise -C ios run build` from the repo root, or
  `mise run gen` and `mise run build` from `ios/`.
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
- Use the Composable Architecture for feature state/actions/reducers.
- Use modern TCA: `@Reducer`, `@ObservableState`, `StoreOf`, scoped stores, and
  no legacy `ViewStore`/`WithViewStore`.
- Use Point-Free Dependencies for controllable dependencies and previews.
- Use Swift Navigation helpers for navigation and presentation once flows exist.
- Use SQLiteData and StructuredQueries-style schema/query APIs for persistence.
  Avoid ad hoc SQLite access in SwiftUI views.

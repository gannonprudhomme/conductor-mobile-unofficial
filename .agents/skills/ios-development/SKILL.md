---
name: ios-development
description: Apply this repository's native iOS project and tooling conventions. Use when changing iOS builds, modules, targets, packages, dependencies, XcodeGen, workspaces, simulators, project.yml, or project structure under ios.
---

# iOS Development

Develop the native app through its checked-in workspace and local Swift package modules.

## Toolchain and commands

- Use Xcode 26.5 and iOS 26 as the minimum deployment target.
- Use Swift 6 language mode everywhere and keep strict concurrency enabled.
- Do not add Bazel yet.
- Generate and build from the repository root with `mise -C ios run gen` and `mise -C ios run build`, or from `ios/` with `mise run gen` and `mise run build`.

## Project generation

- Treat XcodeGen as the source of truth for the app project. Edit `ios/project.yml`, then run `mise -C ios run gen`.
- Keep `ios/ConductorMobile.xcworkspace` checked in. It contains the generated app project and local Swift package modules so modules can be built individually.
- Keep the iOS package manifest at `ios/Modules/Package.swift` and the shared package manifest at `shared/Package.swift`.

## Module structure

- Keep `ConductorMobile` as a thin app target that bootstraps dependencies and renders `ConductorMain.MainView`.
- Put app code in local Swift package modules under `ios/Modules`.
- Keep iOS-only feature and design modules under `ios/Modules`. Put modules used by both the iOS app and desktop server in the root `shared/` package.

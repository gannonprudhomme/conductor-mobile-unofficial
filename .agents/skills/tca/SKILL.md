---
name: tca
description: Apply this repository's Composable Architecture patterns. Use when creating, editing, refactoring, or reviewing iOS feature state, actions, reducers, effects, bindings, presentations, dependency clients, previews, or state-driven navigation.
---

# The Composable Architecture

Build feature logic with modern TCA and keep behavior in testable feature domains.

## Feature domains

- Put feature state, actions, reducers, and views in feature modules such as `ConductorWorkspaces`.
- Use `@Reducer`, `@ObservableState`, `StoreOf`, and scoped stores. Never use legacy `ViewStore` or `WithViewStore`.
- Handle `.task` first in reducer action switches.

## Bindings and presentation

- For feature-owned SwiftUI bindings, conform the action to `BindableAction`, add `case binding(BindingAction<State>)`, include `BindingReducer()` in the reducer, and bind with `$store.property`.
- Never derive feature-owned bindings with `.sending`.
- Model multiple mutually exclusive presentations, such as an alert and a sheet, with one `@Presents var destination` and a nested `@Reducer enum Destination`.
- Use Swift Navigation helpers for state-driven navigation and presentation once flows exist.

## Effects and dependencies

- Capture feature state needed by an effect directly in the `.run` capture list, for example `.run { [id = state.id] send in ... }`.
- Use Point-Free Dependencies for controllable dependencies and previews.

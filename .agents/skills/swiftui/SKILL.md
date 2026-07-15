---
name: swiftui
description: Apply this app's SwiftUI view and design-system conventions. Use when creating, editing, refactoring, reviewing, or validating SwiftUI views, previews, styling, layout, animation, feedback, loading UI, alerts, toolbars, or reusable visual components in ios.
---

# SwiftUI

Build the native app with SwiftUI throughout and apply the `ConductorDesign` system consistently.

## Validation

- Use XcodeBuildMCP to build, run, and visually inspect SwiftUI changes in the simulator whenever possible.

## Design system

- Use `.theme(_:)` with `ThemeColorStyle` and `ThemeFontStyle` for every app color and font, such as `.foregroundStyle(.theme(.textPrimary))`, `.background(.theme(.background))`, and `.font(.theme(.body))`.
- Never use Apple's platform colors such as `.secondary`, `.primary`, or `Color.gray`, or system fonts such as `.caption` and `.body`, directly in app UI.
- Support dark mode only. Force dark mode in previews with `.preferredColorScheme(.dark)`.
- Use `CachedAsyncImage` from `ConductorDesign` for remote images. Never use SwiftUI's `AsyncImage` directly.
- Use `@ScaledMetric` for manually sized images so their dimensions scale with Dynamic Type.

## Layout and composition

- Put a blank line between sibling view declarations inside SwiftUI result-builder closures. Keep a view's modifier chain together without blank lines.
- Indent modifiers beneath the view they modify, including row modifiers inside `List` and `ForEach` closures.
- Use `EdgeInsets(vertical:horizontal:)` for paired vertical and horizontal padding instead of chaining separate padding modifiers.
- Pass a style and shape directly to `.background(_:in:)`, such as `.background(.theme(.highlight), in: .capsule)`. Do not build a shape and call `.fill` inside a background closure.
- Never use `Spacer` to pin content. Set an explicit frame alignment on the content or its container.
- Prefer a dedicated child `View` that takes the model for a repeated row, cell, or expensive model-driven region instead of a helper function or computed view fragment. Use the child view as a smaller invalidation boundary.

## Interaction and presentation

- Prefer `.contentTransition(.numericText(value:))` for incrementing or decrementing numeric text and animate the value change unless that transition would misrepresent the content.
- Drive sensory feedback from the raw state representing the interaction, adding a condition when needed. Use a separately incremented trigger only when no meaningful state change can drive the feedback.
- Use `Button(role: .close)` inside a `ToolbarItem` with `.cancellationAction` placement for raw sheet or full-screen-cover dismissal controls.
- Give toolbar titles and primary toolbar icons an explicit `.foregroundStyle(.theme(.textPrimary))`; never rely on the system toolbar tint.
- Annotate stored button action closures with `@MainActor`, for example `let action: @MainActor () -> Void`.

## Loading and errors

- Give every app-level `ProgressView` an explicit semantic style and themed color. Use `.progressViewStyle(.conductor(...))` only while an agent is working and `.progressViewStyle(.network)` for ordinary network requests.
- Keep primary screen content mounted while showing full-screen loading or status UI in an `.overlay`. Do not replace the screen with an `if`/`else` loading branch, so the transition to loaded content remains smooth.
- Present runtime errors with an alert title that states what failed in user terms. Put `error.localizedDescription` in the alert message or description; the prohibition against `localizedDescription` applies to logs, not user-facing text.

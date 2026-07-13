# Chat Text Field Translucency

## Goal

Make the chat composer read as a clear, translucent surface while retaining its Liquid Glass treatment and the app's dark theme tint.

## Design

Change the `ChatTextField` container's glass style from regular glass with an 80% background tint to clear glass with a 75% background tint:

```swift
.glassEffect(
    .clear
        .tint(.theme(.background).opacity(0.75)),
    in: .rect(cornerRadius: 26)
)
```

No layout, shape, control, state, or interaction behavior changes. The existing theme color remains the tint source, and the existing rounded rectangle remains the glass shape.

## Verification

Build the iOS app, install and launch it on the connected physical device, and confirm that chat content is visible through the composer while its controls remain legible.

---
name: swift-style
description: Apply this repository's Swift source style. Use whenever creating, editing, refactoring, or reviewing Swift files in ios, shared, or desktop, including naming, formatting, control flow, closures, enum layout, source headers, and logging.
---

# Swift Style

Apply these conventions to every Swift source and test file in the repository.

## Source files

- Begin every Swift file with the standard Xcode filename, module, and creator comment header used by existing files.
- Keep `// swift-tools-version:` as the first line of every Swift package manifest instead of placing the standard header above it.

## Naming and control flow

- Name Boolean values as questions or predicates with prefixes such as `is`, `has`, `can`, or `should`.
- Keep the first `if` or `guard` condition on the same line as the keyword. Keep the opening brace on the same line as the final condition; never put a bare keyword or opening brace on its own line.
- Give every `guard` a multiline `else` body, even when it contains only one `return` or `throw`.
- Prefer `if` and `switch` expressions when branches select a value instead of assigning that value separately in each branch.
- In a `switch`, place cases that perform work before no-op cases that only `return` or `return .none`. Apply this ordering to reducer action switches too.
- Place nested type declarations after all cases within a Swift enum.

## Calls and diagnostics

- Use trailing-closure syntax whenever a call ends in one or more closure arguments. For multiple trailing closures, retain every label after the first closure.
- Call `@DependencyClient` endpoints through their generated methods with named arguments. Access underlying closure properties only while overriding dependencies in tests or previews.
- Interpolate an error itself in logs. Never log its `localizedDescription`, so the concrete diagnostic information is preserved.

---
name: swift-data
description: Apply this repository's Swift persistence and data-modeling conventions. Use when working with SQLiteData, StructuredQueries, database records, migrations, fetch properties, persisted Conductor values, database tests, or data ownership across ios, shared, and desktop.
---

# Swift Data and Persistence

Use compile-time-safe records and queries while preserving Conductor's external schema and values.

## Ownership

- Put records shared with the desktop server in `shared/SharedConductorData`. Keep those records aligned with Conductor's actual database schema.
- Put the mobile database, migrations, client, mobile-only state, previews, and app queries in `ios/Modules/Foundations/ConductorMobileData`.
- Keep mobile persistence, computed mobile state, UI, and lifecycle code out of the shared package.

## Queries

- Use SQLiteData and StructuredQueries for Swift database reads and writes. Avoid ad hoc SQLite access in SwiftUI views.
- Reserve raw SQL for schema setup and migrations, or the smallest localized `#sql` fragment when StructuredQueries cannot express an operation directly.
- Keep a short, simple StructuredQueries statement on one line. When a query spans multiple lines, put the table and every chained query operation on separate lines.
- Sort and filter SQLite-backed feature data in SQLiteData or StructuredQueries queries, including dynamic `@FetchAll` and `@Fetch` reloads for active filters. Never sort or filter those database results with computed Swift arrays in feature state or views.
- Observe database-backed detail records with `@FetchOne`, seeded with the value used for navigation, so repository or workspace updates refresh the detail UI.

## Models and tests

- Prefer compile-time types in Swift code and tests.
- Seed database tests with concrete records using `.init(...)` or `.preview(...)`, and execute typed StructuredQueries statements instead of inserting or fetching records with raw SQL.
- Prefer `RawRepresentable` structs with static known values over Swift enums for externally defined string states decoded, encoded, or persisted from Conductor. Preserve unknown future values while allowing ergonomic comparisons and pattern matching for known cases.

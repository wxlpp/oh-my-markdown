# Render migration baseline

Schema 1 was exported from commit `96c6bad422bb38f989f7595c4e2e3574ac50761d`, before deletion of the compatibility renderer. macOS and iOS 18.0 have independent fixtures.

Each fixture ID is SHA-256 of source, layout width and placeholder mode joined with `|`. JSON contains the literal text, canonical attribute runs and TextKit layout frames. Fonts use name/point size; colors use resolved RGBA; paragraph styles include spacing, indents, line heights and tab stops; attachments include bounds and image point size. No platform objects are serialized.

Reproduction: create a detached temporary worktree at the base commit. Instrument `RenderMigrationParityTests.assertParity` to export the legacy side with the `canonicalAttributes` and layout functions in the current test. Export the two overflow table oracle strings separately at their natural width. Run `swift test --filter RenderMigrationParityTests` and `xcodebuild test -scheme MarkdownKit-Package -destination 'platform=iOS Simulator,OS=18.0,name=iPhone 16 Pro' -only-testing:MarkdownKitTests/RenderMigrationParityTests`.

Task 11 amended the list-item paragraph rows of the two list fixtures: their `defaultTabInterval` moved from 0 to the item tab stop. It is the only field that changed, and it changed because a paragraph with no interval past its last tab stop drops the rest of a line whose marker passes that stop — `10.` at an accessibility text size lost its item text. Nothing else in schema 1 is re-exported.

Changes to these expectations require explicit review against the base implementation. Runtime logs and export hashes are recorded in the Task 4C report.

# MarkdownKit Library Hardening Design

**Date:** 2026-09-07  
**Target release:** 0.2.0  
**Status:** In review

## 1. Context

MarkdownKit has a strong behavioral regression suite, but its current architecture leaves production risks around accessibility, Dynamic Type, image loading, task cancellation, streaming complexity, concurrency contracts, platform duplication, and delivery automation.

This project addresses all findings from the 2026-09-07 repository audit while preserving the existing Markdown IR and the TextKit 2 rendering behavior already covered by tests. Breaking public API changes are allowed for the 0.2.0 release.

## 2. Goals

1. Make rendered Markdown usable with VoiceOver, Voice Control, Switch Control, Full Keyboard Access, and large Dynamic Type sizes.
2. Make image and link handling safe by default and customizable by applications.
3. Ensure owned scanner/image/math/SVG work obeys structured lifetimes and cancellation, while the synchronous cmark phase is bounded by strict single-flight/coalescing and stale-result rejection.
4. Make streaming append scale close to linearly for long documents containing math delimiters, backslashes, and code regions.
5. Replace misleading or unsafe public concurrency contracts with explicit immutable values and actor-isolated state.
6. Remove duplicated cross-platform state machines from the UIKit and AppKit views.
7. Restore reliable formatting, CI, platform-test, documentation, and release gates.
8. Lower the supported platforms to iOS 18 and macOS 15 when verified by compilation and behavior tests. If a required TextKit 2 behavior makes either target impossible, retain the higher minimum only for that platform and document the exact unavailable API or behavior.

## 3. Non-goals

- Replacing TextKit 2 with a new SwiftUI-native renderer.
- Rewriting the Markdown IR or replacing swift-markdown.
- Adding WYSIWYG editing, collaborative editing, or table-editing UI.
- Adding disk image caching, offline persistence, or a general networking framework.
- Expanding MathJax package coverage beyond the currently documented core feature set.
- Guaranteeing source compatibility with MarkdownKit 0.1.x.

## 4. Architecture

### 4.1 Module responsibilities

#### MarkdownCore

`MarkdownCore` remains the platform-independent Markdown IR and parser layer. It will add:

- cooperative cancellation in MarkdownKit-owned scanner, mapping, and transformation loops;
- an explicit non-cancellable-region contract around synchronous swift-markdown/cmark parsing;
- incremental scanner state sufficient to resume math and code-region analysis from a proven-safe boundary;
- precise source-map data for rendered selections where the parser can provide it;
- deterministic full-parse fallback when an incremental boundary cannot be proven safe.

The result remains an immutable, `Sendable` document value.

#### MarkdownRenderKit

`MarkdownRenderKit` becomes an immutable rendering transformation layer. `AttributedStringRenderer` will no longer expose mutable image, math, or SVG caches and will not claim to be stateless while storing mutable state.

Background rendering preparation consumes a pure, `Sendable` `RenderInput` and produces a pure, `Sendable` display model containing block/source metadata, unresolved resource descriptions, and accessibility semantics. A `@MainActor` materializer combines that model with platform fonts, colors, images, TextKit objects, and resolved-resource handles to produce `RenderSnapshot`.

`RenderSnapshot` is `@MainActor`-isolated and deliberately does not conform to `Sendable`. It may contain `NSAttributedString`, text attachments, and platform images. No platform object crosses from the main actor inside an unchecked public container.

Platform types that cannot be proven `Sendable` stay on the main actor. `@unchecked Sendable` is permitted only at a small audited adapter boundary with a documented invariant; it must not be used to make a publicly mutable platform-object container appear safe.

#### MarkdownPlatformView

`MarkdownPlatformView` owns the rendering session and platform adapters:

- `MarkdownRenderSession` coordinates source revisions, parsing, resource requests, and snapshot publication.
- A shared platform-neutral session core contains logic currently duplicated across UIKit and AppKit views.
- UIKit and AppKit views retain only TextKit setup, layout/drawing, native selection/input plumbing, platform link opening, and accessibility bridges.
- Shared caches are separate dependencies and contain completed results only. In-flight request ownership and deduplication stay inside a session. A cache may outlive a view, but no task started by a view may implicitly do so.

#### MarkdownKit

The SwiftUI module continues to expose `MarkdownText`, `MarkdownStreamingText`, `MarkdownEditor`, style modifiers, and renderer modifiers. It additionally exposes configuration for image loading, link policy, load-error reporting, and Markdown-source copying.

The umbrella module will use supported public import/re-export mechanisms available in Swift 6.2 rather than underscored attributes where possible.

### 4.2 Session ownership

Each platform view owns one session by default. The session owns all tasks associated with the current source and cancels cancellable work when the source is replaced or the view is dismantled. Shared completed-result caches may be injected independently of the session; they never own in-flight tasks.

Two sessions requesting the same uncached resource may perform separate work. This is an intentional trade-off: it gives unambiguous ownership, makes view teardown cancellation correct, and avoids a reference-counted process-wide request broker. Within one session, identical in-flight requests are deduplicated. A future shared broker is outside 0.2.0 scope.

The session publishes immutable snapshots on `MainActor`. It never exposes its internal mutable dictionaries or tasks through public API.

## 5. Data flow and concurrency

1. A static or streaming source update enters `MarkdownRenderSession` and receives a monotonically increasing revision.
2. Replacing a source cancels MarkdownKit-owned cooperative phases and replaces the pending input with the newest revision. Appending coalesces pending chunks.
3. Parsing executes away from `MainActor` through an explicitly concurrent async function or structured child task. It does not use an unowned `Task.detached`.
4. Long scanner, substitution, mapping, and rendering-preparation loops check cancellation at bounded intervals.
5. `Markdown.Document(parsing:)` is a synchronous cmark call with no cancellation hook. It is treated as a non-cancellable region. The scheduler permits at most one cmark parse to be active per session; updates arriving during it are coalesced into one latest pending input rather than starting concurrent cmark parses.
6. A completed parse may commit only when its revision is still current. When a stale cmark parse returns, its output is discarded and the single coalesced pending input starts.
7. The background renderer creates a pure display model and enumerates unresolved image, math, and SVG requests; `MainActor` materializes the platform snapshot.
8. Session resource coordinators deduplicate requests by content, dimensions, scale, policy/renderer identity, and other output-affecting inputs.
9. Resource results may merge only when their source revision and loader/renderer identity remain current.
10. Source replacement, renderer replacement, policy replacement, view dismantling, and deinitialization cancel affected cancellable tasks.
11. Cancellation produces no cache entry. Only deterministic failures may enter a bounded negative cache.

Actor isolation is explicit:

- UIKit, AppKit, SwiftUI bridges, platform images/colors/fonts, TextKit, and accessibility state are `MainActor`-isolated.
- Parser inputs and outputs are immutable `Sendable` values.
- Session-owned resource coordination uses an actor and stores only transport bytes or other proven-`Sendable` values off the main actor. Platform-image materialization and platform-image cache access are main-actor isolated.
- CPU-heavy pure work is explicitly concurrent and returns a `Sendable` display model. The only audited unchecked adapter allowed in 0.2.0 is an immutable decoded-image handoff if the selected ImageIO representation lacks compiler-proven `Sendable`; its ownership/read-only invariant must be documented and tested.

## 6. Incremental parsing performance

The existing append path rebuilds UTF-8 arrays and scans the complete previous source when it contains `$` or `\`. The new path carries incremental scanner state and examines only a safe tail window.

The state records enough information to decide whether parsing may resume safely, including:

- the current safe UTF-8 boundary;
- open fenced-code state and fence marker/length;
- inline-code delimiter state relevant to the tail;
- math delimiter state relevant to the tail;
- line/list context needed to classify indented code conservatively.

Markdown constructs with non-local influence force a full parse. The fallback matrix includes reference-style link/image definitions, setext-heading and thematic-break ambiguity, HTML block continuation, blockquote/list lazy continuation, CRLF boundaries, and sources without a final newline. The implementation plan must map each construct to the conservative invalidation boundary it requires.

If state is absent, invalid, or inconsistent with the source prefix, the parser performs a full parse. Correctness always wins over incrementality.

Regular expressions and other immutable scanners are compiled once. Performance tests will cover 10 KB, 100 KB, and 1 MB documents, with plain Markdown and delimiter-heavy fixtures.

The primary acceptance metric is deterministic work, not wall-clock time. An internal test counter records bytes examined by incremental scanner/mapping passes. For a fixed 1 KB chunk sequence, cumulative examined bytes must not exceed `8 × (initialBytes + appendedBytes)` for fixtures that remain incrementally safe. Fixtures that intentionally trigger a non-local full fallback are measured and reported separately. Wall-clock benchmarks use one warm-up plus five measured runs and compare the median; they are diagnostic and do not replace the byte-work assertion.

## 7. Image loading and caching

### 7.1 Public abstraction

Applications may inject a `MarkdownImageLoading` implementation. The default loader:

- accepts only HTTPS URLs;
- requires a successful 2xx HTTP response;
- streams the response and cancels immediately when byte `20 MiB + 1` arrives, where the limit is exactly `20 × 1024 × 1024` bytes; it never obtains a fully buffered oversized body;
- validates ImageIO metadata before full-size decode using overflow-safe width × height arithmetic, an 8,192-pixel per-side limit, at most 32 frames, and a 40-megapixel cumulative frame budget;
- uses request and resource timeouts;
- respects task cancellation;
- re-applies the HTTPS policy to every redirect and the final response URL, rejecting HTTPS-to-HTTP downgrade;
- accepts `image/png`, `image/jpeg`, `image/gif`, `image/webp`, `image/heic`, and `image/heif`; the declared MIME type, detected ImageIO type, and selected decoder must agree;
- reports a typed, non-sensitive error.

Applications that need HTTP, file URLs, authenticated requests, or custom schemes must provide their own loader.

### 7.2 Cache

The default image cache uses `NSCache` or an equivalent cost-bounded implementation. Cost is based on estimated decoded bytes, not only entry count. It responds to memory-pressure notifications and is injectable for deterministic tests.

The cache stores successful decoded results only and is `@MainActor`-isolated because it holds platform images. Transfer actors cache only bounded `Data` while a request is active. Failures are either not cached or kept in a short, bounded negative cache when proven deterministic.

Security tests must prove that an oversized transfer is cancelled at the limit, the decoder is never invoked for rejected metadata/content, redirect downgrade is rejected, and a declared/detected type mismatch does not reach full decode.

### 7.3 Presentation

Before resolution, an image exposes its alt text or source fallback. After resolution, the same description remains attached to accessibility semantics. Internal network errors do not replace content with debug text. Hosts may observe failures through an optional callback.

## 8. Link policy

The default link opener accepts HTTP and HTTPS only. Other schemes are rejected unless an injected `MarkdownLinkPolicy` explicitly permits and handles them.

Links expose accessible labels, link traits/roles, activation actions, and keyboard operation. Invalid destinations remain readable text rather than interactive elements.

## 9. Accessibility and Dynamic Type

### 9.1 Structured accessibility model

The renderer produces platform-neutral accessibility nodes for:

- headings with levels;
- paragraphs and list items;
- links with activation metadata;
- images with alt text;
- inline and display math, announced using the original LaTeX unless a renderer supplies a better spoken description;
- tables with row/column position and header relationships;
- code blocks with language metadata when present.

Each accessibility node has a stable identity derived from source identity, semantic role, and source range rather than rendered array index. UIKit exposes these nodes through virtual accessibility elements or an accessibility container. AppKit exposes equivalent `NSAccessibilityElement` objects. Traversal follows document order. Nodes carry layout frames and hit-test/activation metadata. Horizontal table overlays must not duplicate or hide their semantic table nodes.

Snapshot updates diff nodes by stable identity and reuse platform accessibility objects. If the focused node survives an append, focus and activation remain on that node. If it disappears, focus moves to the nearest surviving semantic neighbor. Streaming announcements are coalesced and off by default; hosts may enable a polite “new content” announcement policy so token-level updates never produce announcement spam.

### 9.2 Dynamic Type and adaptive presentation

The default iOS style uses preferred text styles and scales code, heading, spacing, attachment bounds, and table chrome appropriately. The platform view reacts to content-size-category and relevant trait changes by rebuilding the style/render snapshot without replacing application-provided custom styles.

Custom fixed fonts remain supported but are documented as opting out of automatic Dynamic Type unless wrapped in the provided scaling helper.

Maximum accessibility sizes must not clip content or make tables/attachments overlap. Horizontal scrolling remains available for wide tables.

## 10. Selection and copying

The normal platform `Copy` action copies exactly the selected semantic rendered text. It must not expand a partial selection to an entire Markdown block. Output is defined as follows:

| Selection content | Normal Copy | Copy Markdown Source |
|---|---|---|
| Plain/styled text | Visible characters only | Exact source when mapped |
| Unresolved image | Visible placeholder label | Original image syntax |
| Resolved image | Alt text, or source fallback | Original image syntax |
| Inline/display math | Original LaTeX without object-replacement characters | Delimiters plus original LaTeX |
| Table | Tab-separated cells with newline-separated rows | Original pipe/table source |
| Cross-block selection | Exact semantic text across selected portions | Exact mapped span when possible |
| Programmatic IR without source | Semantic rendered text | `renderedFallback` |

Markdown source copying remains available through:

- a public proxy/API that returns source corresponding to the current selection;
- a distinct context-menu or command action named “Copy Markdown Source” where the platform permits it.

Source mapping aims for inline precision. When exact mapping is impossible, the result reports its granularity (`exact`, `blockExpanded`, or `renderedFallback`) instead of silently returning expanded content. Formula, image, and table source remain recoverable through the explicit source-copy path. This reversal of the 0.1.x default Copy behavior is a documented 0.2.0 migration item.

The package supplies localized menu strings for supported package localizations, beginning with English and Simplified Chinese. Hosts may override the source-copy command title and image/error accessibility fallbacks.

## 11. Public API and documentation changes

The 0.2.0 release may make breaking changes. Planned changes include:

- removing mutable cache properties from `AttributedStringRenderer`;
- removing unjustified public `@unchecked Sendable` conformances;
- replacing directly exposed coordinator internals with high-level configuration/session APIs;
- adding typed image loader, cache, link policy, error callback, and source-copy APIs;
- using public module import/re-export syntax where supported;
- documenting every public declaration with behavior, isolation, parameters, errors, and complexity where relevant;
- documenting 0.1.x migration steps and changed default security behavior.

Implementation-only types become `internal` or `package` where cross-target access requires it.

## 12. Platform support

The package manifest, Example application, and all test/UI-test hosts target iOS 18 and macOS 15. Both targets must compile under Swift 6.2 with warnings treated as errors.

CI must execute the iOS suite on an iOS 18 simulator runtime and the macOS suite on a macOS 15 runner. Compiling with an iOS 18/macOS 15 deployment target while executing only on a newer runtime is not sufficient evidence. If GitHub-hosted runners no longer provide one of these runtimes, release verification uses a documented self-hosted runner or reproducible local/VM run and archives the OS/runtime, Xcode version, and test results.

If a required API blocks one target, the implementation first attempts an availability-compatible adapter. Raising the minimum is allowed only when a required TextKit 2 behavior cannot be implemented correctly, and the reason must be captured in README and CHANGELOG with the exact API/behavior involved.

## 13. Code organization

The current large platform files will be decomposed by responsibility. Expected units include:

- render session and revision state;
- incremental parse scheduler;
- image coordinator and cache;
- math/SVG coordinators;
- source-selection mapping;
- accessibility semantic model;
- UIKit label/input bridge;
- AppKit label/input bridge;
- table overlay/layout helpers.

Extraction must preserve observable behavior and be performed in test-backed checkpoints. File size is not itself the acceptance criterion; clear ownership and removal of duplicated state machines are.

## 14. Testing strategy

### 14.1 Unit and integration tests

- Full-parse versus incremental-parse equivalence across delimiters, code regions, Unicode, tables, malformed input, reference definitions, setext/thematic ambiguity, HTML blocks, lazy list/blockquote continuation, CRLF splits, and missing final newlines. Small fixtures exercise every possible chunk boundary; larger fixtures use deterministic seeded chunk sequences.
- Cooperative cancellation of owned phases, stale revision rejection, rapid set/append/replace sequences, renderer/policy switching, and view destruction.
- Non-cancellable cmark scheduling: at most one active parse per session, latest-input coalescing, stale-output rejection, and exactly one follow-up parse after a burst of updates.
- Image scheme, status, MIME, body-size, pixel-size, timeout, cancellation, cache cost, eviction, and memory-pressure behavior.
- Math/SVG deduplication, cancellation, renderer identity, positive/negative cache limits, and deterministic failure classification.
- Exact rendered copy and explicit Markdown-source-copy granularity.
- Link-policy allow/reject behavior.
- Accessibility node labels, stable identities, frames, hit testing, roles, order, heading levels, link actions, alt text, math fallback, table coordinates, object reuse, and focus preservation/fallback across streaming updates.
- Dynamic Type style scaling and non-overlapping layout at accessibility sizes.

Tests must use Swift Testing synchronization primitives, controllable clocks, actors, or explicit awaitable seams. Timing-based `Task.sleep` polling will be removed from the existing suite.

### 14.2 Platform verification

- Run SwiftPM tests on a macOS 15 runtime.
- Build and test UIKit paths on an iOS 18 Simulator through an Xcode test plan.
- Run Example UI smoke tests for rendering, editing, selection/copy, links, image states, Dynamic Type, and accessibility identifiers/values.
- Render screenshots for normal content, wide tables, image loading states, math/SVG, dark mode, and maximum Dynamic Type.
- Send UI screenshots to the configured visual-review agent before completion.
- Manually verify VoiceOver, Voice Control Show Names/Numbers, Full Keyboard Access, and representative Switch Control traversal; record the checklist in release documentation.

### 14.3 Performance verification

- Record parsing and streaming measurements for 10 KB, 100 KB, and 1 MB fixtures.
- Record peak/cached image memory under bounded adversarial fixtures.
- Ensure performance thresholds are tolerant of CI variance while still catching a return to whole-document work per token.

## 15. Engineering gates

GitHub Actions will run:

1. SwiftFormat lint with zero violations.
2. macOS debug tests.
3. macOS release build with warnings as errors.
4. iOS Simulator build and test for `MarkdownKit` and `MarkdownMath`.
5. Example application build and UI smoke tests where runner support is reliable.

The existing 875 SwiftFormat findings will be fixed in a dedicated mechanical change before enabling the zero-violation gate. Empty template tests will be replaced or removed.

README, DocC comments, CONTRIBUTING, and CHANGELOG must describe the real CI, supported platforms, Dynamic Type behavior, image/link defaults, source-copy behavior, and 0.2.0 migration.

## 16. Delivery checkpoints

Implementation is divided into independently verifiable checkpoints:

1. Formatting baseline, CI skeleton, platform targets, and test infrastructure.
2. Immutable render API and explicit concurrency boundaries.
3. Shared render session, cooperative task cancellation, cmark single-flight/coalescing, and platform-view decomposition.
4. Incremental scanner state and performance tests.
5. Secure injectable image loading/cache and link policy.
6. Exact copy/source mapping API.
7. Dynamic Type and structured UIKit/AppKit accessibility.
8. Documentation, Example coverage, complete verification, visual review, and migration notes.

Each checkpoint requires tests, build verification, and a `superpowers-reviewer` review focused on plan conformance and incremental correctness. Review feedback is handled through the receiving-code-review workflow.

## 17. Audit traceability and release scope

| Audit ID | Finding | Owning checkpoint | 0.2.0 disposition |
|---|---|---:|---|
| A1 | Custom-drawn content lacks structured accessibility semantics | 7 | Release-blocking |
| A2 | Default typography does not honor Dynamic Type | 7 | Release-blocking |
| N1 | Image loading lacks transport/decode limits and bounded ownership | 5 | Release-blocking |
| C1 | Detached synchronous parsing defeats cancellation | 3 | Release-blocking |
| P1 | Streaming rescans the complete source on append | 4 | Release-blocking |
| C2 | Mutable public renderer/style uses unsafe concurrency claims | 2 | Release-blocking |
| U1 | Normal Copy expands partial selections to whole source blocks | 6 | Release-blocking |
| M1 | RenderKit's platform-neutral boundary leaks UIKit/AppKit objects | 2, 8 | Required for 0.2.0 API contract |
| M2 | UIKit/AppKit platform views duplicate large state machines | 3 | Required for 0.2.0 maintainability |
| D1 | Public API documentation is incomplete | 8 | Changed APIs are release-blocking; remaining legacy gaps may be scheduled for 0.2.x only when documented and safety-neutral |
| E1 | No GitHub Actions delivery gates | 1 | Release-blocking |
| E2 | SwiftFormat baseline has 875 findings | 1 | Release-blocking |
| T1 | Example tests contain empty templates | 1, 8 | Release-blocking for affected paths |
| T2 | Tests rely on 40 timing sleeps | 1–7 | Sleeps in touched/concurrency coverage are release-blocking; unrelated deterministic migration may continue through checkpoint 8 |
| S1 | Package platform floors are unnecessarily high | 1, 8 | Release-blocking unless an evidence-backed exception is approved |
| R1 | `AGENTS.md` references a missing `RTK.md` | 8 | Must be repaired or the include removed before release |

Deferral to 0.2.x is permitted only for explicitly listed documentation or mechanical cleanup that does not affect safety, correctness, public API truthfulness, or a modified execution path. Every deferral must have an issue, rationale, owner, and target release; no release-blocking row may be deferred silently.

## 18. Acceptance criteria

- Existing behavior tests continue to pass except where explicitly changed by this design.
- New tests demonstrate cooperative cancellation of owned work and stale-result rejection without sleeps.
- Burst-update tests prove at most one active cmark parse per session, latest-input coalescing, stale-output rejection, and one follow-up parse.
- For incrementally safe 1 KB chunk fixtures, the measured scanner/mapping work stays within `8 × (initialBytes + appendedBytes)`; exhaustive and seeded differential tests prove fallback correctness for non-local constructs.
- Default image and link behavior enforces the approved security policy.
- Image caches and all negative caches are bounded.
- Normal copy is selection-exact; source copy reports mapping granularity.
- UIKit and AppKit expose structured, ordered Markdown accessibility semantics with stable identity, correct frames/hit testing, and focus continuity across streaming updates.
- Default iOS style responds to Dynamic Type through accessibility sizes.
- The package builds and executes its relevant test suites on actual iOS 18 and macOS 15 runtimes, or a documented, evidence-backed exception is approved.
- Public API documentation and 0.2.0 migration notes are complete.
- SwiftFormat reports zero violations.
- Required macOS and iOS CI jobs pass.
- Rendered screenshots pass visual review.
- The complete diff passes final `superpowers-reviewer` review.

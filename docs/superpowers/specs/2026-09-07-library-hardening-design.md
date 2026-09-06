# MarkdownKit Library Hardening Design

**Date:** 2026-09-07
**Target release:** 0.2.0
**Status:** Approved

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
- Shared caches are separate dependencies and contain completed results only. In-flight resource-request ownership and deduplication stay inside a session. A cache may outlive a view. Cooperative work started for a view must not outlive it; the process parse executor described below is the sole explicit exception for an already-entered synchronous cmark call.

#### MarkdownKit

The SwiftUI module continues to expose `MarkdownText`, `MarkdownStreamingText`, `MarkdownEditor`, style modifiers, and renderer modifiers. It additionally exposes configuration for image loading, link policy, load-error reporting, and Markdown-source copying.

The umbrella module will use supported public import/re-export mechanisms available in Swift 6.2 rather than underscored attributes where possible.

### 4.2 Session ownership

Each platform view owns one session by default. The session owns all cancellable tasks associated with the current source and cancels them when the source is replaced or the view is dismantled. Shared completed-result caches may be injected independently of the session; they never own in-flight tasks.

Two sessions requesting the same uncached resource may perform separate work. This is an intentional trade-off: it gives unambiguous ownership, makes view teardown cancellation correct, and avoids a reference-counted process-wide request broker. Within one session, identical in-flight requests are deduplicated. A future shared broker is outside 0.2.0 scope.

The session publishes immutable snapshots on `MainActor`. It never exposes its internal mutable dictionaries or tasks through public API.

Synchronous cmark calls execute in an internal process-wide `ParseExecutor`, not in a task that retains the session or view. The executor admits at most two active cmark calls process-wide, at most one active job and one replaceable pending input per session token, and at most 64 waiting session tokens. A job owns only a copied immutable `Sendable` input plus revision/configuration tokens; it owns no session, view, platform object, callback closure, or cache. When the admission queue is full, it returns a typed transient busy result. A live session may own at most one replaceable retry task, may attempt admission at most three times within a two-second total deadline, and then reports a typed `parseBusy` failure on `MainActor` while retaining its last valid snapshot or initial placeholder. Only a later source/configuration update starts a new attempt sequence. A dismantled session never retries.

View/session teardown tombstones its token in the executor-facing result registry and removes its pending admission. An already-active cmark call is allowed to finish, but its result is dropped without callback, cache write, publication, retry, or pending follow-up. As soon as a token has no active or pending job, all registry state for it is removed; a later completion treats an absent token as stale. This bounded orphaned-call exception is explicit and cannot retain the view or session or grow a permanent tombstone set.

## 5. Data flow and concurrency

1. A static or streaming source update enters `MarkdownRenderSession` and receives a monotonically increasing revision.
2. Replacing a source cancels MarkdownKit-owned cooperative phases and replaces the pending input with the newest revision. Appending coalesces pending chunks.
3. Cancellable parsing preparation executes away from `MainActor` through an explicitly concurrent async function or structured child task. It does not use an unowned `Task.detached`. Entry into synchronous cmark is admitted by the bounded process-wide `ParseExecutor`.
4. Long scanner, substitution, mapping, and rendering-preparation loops check cancellation at bounded intervals.
5. `Markdown.Document(parsing:)` is a synchronous cmark call with no cancellation hook. It is treated as a non-cancellable region. The executor permits at most two active cmark calls process-wide and at most one per session token; updates arriving during one are coalesced into that session token's single latest pending input.
6. A completed parse may commit only when its revision is still current. When a stale cmark parse returns, its output is discarded and the single coalesced pending input starts.
7. The background renderer creates a pure display model and enumerates unresolved image, math, and SVG requests; `MainActor` materializes the platform snapshot.
8. Session resource coordinators deduplicate requests by content, dimensions, scale, policy/renderer identity, and other output-affecting inputs.
9. Resource results may merge only when their source revision and loader/renderer identity remain current.
10. Source replacement, renderer replacement, loader/policy replacement, view dismantling, and deinitialization cancel affected cancellable tasks. Teardown additionally tombstones the parse token so an active non-cancellable result has no observer and cannot start follow-up work.
11. Cancellation produces no cache entry. Only deterministic failures may enter a bounded negative cache.

Actor isolation is explicit:

- UIKit, AppKit, SwiftUI bridges, platform images/colors/fonts, TextKit, and accessibility state are `MainActor`-isolated.
- Parser inputs and outputs are immutable `Sendable` values.
- Session-owned resource coordination uses an actor and stores only transport bytes or other proven-`Sendable` values off the main actor. Platform-image materialization and platform-image cache access are main-actor isolated.
- CPU-heavy pure work is explicitly concurrent and returns a `Sendable` display model. The only audited unchecked adapter allowed in 0.2.0 is an immutable decoded-image handoff if the selected ImageIO representation lacks compiler-proven `Sendable`; its ownership/read-only invariant must be documented and tested.

Configuration isolation is also explicit. Loader, renderer, and policy values cross actors only through `Sendable` protocols or immutable `Sendable` request/configuration snapshots. Every output-affecting configuration has a stable public ID and a monotonically increasing session generation. Replacement cancels its cancellable work and invalidates pending publication/cache-write tokens; an old generation may neither publish nor populate a cache owned by the new generation.

Configuration IDs are cache namespaces, not arbitrary equality hints. Library defaults derive deterministic semantic IDs from every output-affecting setting. Custom configurations receive a library-issued unique instance ID by default, which guarantees isolation but not cross-instance sharing. A host may explicitly provide a versioned semantic namespace to share completed cache entries across instances; doing so asserts the protocol invariant that equal IDs produce equivalent output for the same request. Different output-affecting behavior must use different IDs. Cache keys always include both the resource request key and configuration ID.

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

The primary acceptance metric is deterministic work, not wall-clock time. Internal test instrumentation records all MarkdownKit-owned source-proportional work separately: scanner bytes, source-map bytes, UTF-8 materialization/copy and substitution bytes, bytes submitted to cmark, and rendering-preparation bytes. Moving a full-source pass into an uncounted phase is not permitted.

For a fixed 1 KB chunk sequence whose constructs remain incrementally safe, cumulative work must stay within these budgets relative to `N = initialBytes + appendedBytes`: scanner `≤ 3N`, mapping `≤ 3N`, materialization/copy/substitution `≤ 4N`, cmark input `≤ 4N`, rendering preparation `≤ 4N`, and all counted phases combined `≤ 16N`. Fixtures that intentionally trigger a documented non-local full fallback are measured and reported separately by phase. Wall-clock benchmarks use one warm-up plus five measured runs and compare the median; they are diagnostic and do not replace the work assertions.

## 7. Image loading and caching

### 7.1 Public abstraction

Remote images are host opt-in in 0.2.0 because fetching untrusted Markdown reveals network metadata such as the reader's IP address. Without opt-in, remote images remain accessible placeholders with alt text/source fallback. Applications may opt in to the default loader or inject a `MarkdownImageLoading` implementation.

`MarkdownImageLoading` is a `Sendable` async protocol; conformers may be actors. Its request and result values are immutable and `Sendable`, and the protocol returns encoded bytes plus validated metadata rather than a platform image. Each loader configuration has an explicit stable `MarkdownResourceConfigurationID: Hashable & Sendable`. Replacement always increments a session generation, cancels queued/active cancellable requests, and prevents old-generation results from publishing, invoking callbacks, or writing any cache. The cache namespace changes only when output semantics/ID change: an equivalent built-in configuration or explicitly shared semantic ID may read entries that completed before replacement, but a late result from the replaced generation may never populate that namespace.

The default loader:

- accepts only HTTPS URLs;
- requires a successful 2xx HTTP response;
- streams the response and cancels immediately when byte `20 MiB + 1` arrives, where the limit is exactly `20 × 1024 × 1024` bytes; it never obtains a fully buffered oversized body;
- validates ImageIO metadata before full-size decode using overflow-safe width × height arithmetic, an 8,192-pixel per-side limit, at most 32 frames, and a 40-megapixel cumulative frame budget;
- uses a 15-second request timeout and 30-second resource timeout; hosts may configure each within 1...120 seconds;
- respects task cancellation;
- re-applies the HTTPS policy to every redirect and the final response URL, rejecting HTTPS-to-HTTP downgrade;
- uses an ephemeral isolated URL session with no shared cookie storage, credential storage, or URL cache and performs no implicit authentication; cross-host redirects carry no host-supplied or authorization headers;
- accepts `image/png`, `image/jpeg`, `image/gif`, `image/webp`, `image/heic`, and `image/heif`; the declared MIME type, detected ImageIO type, and selected decoder must agree;
- reports a typed, non-sensitive error containing only an error category and, when useful, sanitized URL origin (`scheme`, host, and non-default port); path, parameters, query, fragment, credentials, and response body are never included.

Applications that need HTTP, file URLs, authenticated requests, or custom schemes must provide their own loader.

### 7.2 Cache

The default resource coordinator enforces both per-session and process-wide limits. It is a shared permit/budget actor, not the owner of request tasks or results. Per session, at most two transfers and one decode are active. Process-wide, at most four transfers and two decodes are active.

Before a transfer begins, it atomically reserves the full 20 MiB single-request encoded allowance from an 80 MiB process-wide encoded budget. It never begins while holding a partial reservation, and it never waits for additional encoded budget after retaining response bytes. The reservation remains charged until the encoded body is released after rejection or decode consumption. Requests unable to reserve the full allowance wait before network activity in a cancellable queue; source replacement and teardown remove their queued entries. This deliberately trades utilization for a deadlock-free hard bound.

ImageIO creates a thumbnail/downsampled image directly for the validated display pixel size and scale; it must not first allocate the full-resolution platform image. The requested output is capped at 4,096 pixels per side and 64 MiB accounted decoded-pixel cost per image even when source metadata is within the 40-megapixel admission limit.

Decoded images use an explicit `@MainActor` accounting ledger and LRU, not `NSCache.totalCostLimit`. Each unique decoded resource has one residency record containing its resource/configuration identity, accounted decoded-pixel cost, and explicit owner leases. In-flight publication, the completed cache, and every published `RenderSnapshot`/attachment acquire leases to the same record. The resource cost is charged once while at least one lease exists. Cache eviction releases only the cache lease; it does not reduce the ledger while any snapshot still displays the resource. Snapshot replacement or view teardown explicitly releases publication leases, and only the final owner release removes the record's cost.

The hard process-wide accounted decoded-pixel budget is 192 MiB across all residency records, with a 128 MiB completed-cache ownership sublimit. Before decode, the coordinator reserves a conservative downsampled pixel cost and synchronously releases eligible LRU cache-only records as needed; if sufficient budget is still unavailable, it further reduces the requested thumbnail size within presentation limits or leaves that image as an accessible placeholder. It does not begin decode while waiting for budget. Publishing computes retained, added, and removed resource identities, admits all added leases/cost first, then atomically swaps snapshots and releases removed leases; an old snapshot and a disjoint new snapshot may not temporarily exceed the hard budget. In-flight-to-cache/snapshot ownership transfer never double-counts or prematurely uncharges a record. Memory pressure clears cache leases, not publication leases. The ledger/cache is injectable for deterministic tests.

The hard contract covers decoded pixel backing, not total process RSS. The decoder normalizes thumbnails to 8-bit-per-component BGRA/sRGB. Predecode reservation uses overflow-safe `alignUp(pixelWidth × 4, 64) × pixelHeight` summed across retained frames; after decode it is reconciled upward, before publication, against the sum of each `CGImage.bytesPerRow × height`. Framework objects, color-space objects, allocator metadata, and transient decoder overhead are monitored through the §14.3 peak-memory gate but are not mislabeled as a byte-exact RSS bound.

The cache stores successful decoded results only and is `@MainActor`-isolated because it holds platform images. Transfer actors cache only bounded `Data` while a request is active. Failures are either not cached or kept in a short, bounded negative cache when proven deterministic.

Security tests must prove that an oversized transfer is cancelled at the limit, the decoder is never invoked for rejected metadata/content, redirect downgrade is rejected, and a declared/detected type mismatch does not reach full decode. A 100-unique-image adversarial fixture must also prove the transfer/decode concurrency ceilings, 80 MiB encoded reservation budget, 192 MiB accounted decoded-pixel limit, 128 MiB completed-cache ownership sublimit, 64 MiB per-image output ceiling, atomic ownership transfer, and teardown queue cleanup. It must publish images, evict their cache leases while snapshots still display them, verify that their residency costs remain charged and later images downsample/wait/remain placeholders, then verify teardown returns the ledger to baseline. Dedicated two-by-17-MiB and four-by-9-MiB response tests must complete or wait before transfer admission; no request may wait for budget while holding a partial encoded body.

### 7.3 Presentation

Before resolution, an image exposes its alt text or source fallback. After resolution, the same description remains attached to accessibility semantics. Internal network errors do not replace content with debug text. Hosts may observe failures through an optional `@MainActor` callback; stale configuration generations never invoke it.

## 8. Link policy

`MarkdownLinkPolicy` is a `Sendable` protocol whose pure decision method consumes an immutable URL/request snapshot and returns an immutable disposition. It does not open applications or touch platform state. An injected `@MainActor` link handler performs an allowed activation. Policy and handler configurations have stable IDs/generations under the replacement rules in §5.

The default link policy accepts HTTP and HTTPS only, and the default `@MainActor` handler delegates an allowed URL to the platform opener. Other schemes are rejected unless injected policy and handler configurations explicitly permit and handle them.

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

Each accessibility node has a stable identity derived from the session's source-generation, semantic role, an immutable start anchor, and parser-assigned lineage. A growing end offset is metadata and never participates in identity. Source replacement starts a new generation; streaming append preserves lineage for surviving nodes, including the growing final paragraph, list item, or table.

The semantic model is a tree. Paragraphs, list items, headings, and tables may act as containers; exposed leaves are the units traversed and spoken by the platform. A block with no interactive descendants may expose one leaf. A block containing links, images, or math does not also expose a duplicate full-block label: its non-interactive text ranges become text leaves with child ranges excluded, while each interactive/attachment descendant is its own leaf. Heading/list context is propagated to appropriate leaves. Tables expose row/cell leaves with header relationships and row/column coordinates; aggregate table/container labels and horizontal visual overlays are not separately exposed.

UIKit maps exposed leaves to virtual accessibility elements or an accessibility container. AppKit maps them to equivalent `NSAccessibilityElement` objects. Traversal follows document order. Leaves carry layout frames and hit-test/activation metadata.

Snapshot updates diff nodes by stable identity and reuse platform accessibility objects. If the focused node survives an append, focus and activation remain on that node even when its end range grows. If it disappears, focus moves to the nearest surviving semantic neighbor. Streaming announcements are coalesced and off by default; hosts may enable a polite “new content” announcement policy so token-level updates never produce announcement spam.

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
- Non-cancellable cmark scheduling with a blocking fake parser: no more than two active calls process-wide or one per session token, 64-token bounded admission, at most one retry task per session, three-attempt/two-second exhaustion, latest-input coalescing, stale-output rejection, and exactly one follow-up parse after a burst of updates. While a call is blocked, weak view/session references must deallocate; teardown must cause no commit, callback, retry, cache write, or follow-up. After creating and destroying 1,000 sessions, registry state must return to the active/pending baseline.
- Image opt-in, scheme, status, MIME, body-size, pixel-size, timeout, isolated credential/cookie/cache behavior, sanitized errors, cancellation, configuration replacement, concurrency/aggregate budgets, hard LRU accounting, eviction, and memory-pressure behavior. When a loader is replaced mid-request, its old result must neither publish, report through the new callback, nor write any completed/negative cache. Cross-session tests prove that equal semantic configuration IDs share equivalent entries, while unique or different IDs cannot read each other's entries.
- Math/SVG deduplication, cancellation, renderer identity, positive/negative cache limits, and deterministic failure classification.
- Exact rendered copy and explicit Markdown-source-copy granularity.
- Link-policy allow/reject behavior, main-actor activation, configuration replacement, and stale-result rejection.
- Accessibility node labels, stable identities, frames, hit testing, roles, order, heading levels, link actions, alt text, math fallback, table coordinates, object reuse, and focus preservation/fallback across streaming updates. Golden traversal/speech fixtures include a paragraph with two links, an image, and inline math, plus repeated appends while focus remains in a growing paragraph and table.
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
2. macOS 15 debug tests.
3. macOS 15 release build with warnings as errors.
4. iOS 18 Simulator build and test for `MarkdownKit` and `MarkdownMath`.
5. Example application build and UI smoke tests as a release gate. When GitHub-hosted runtime support is unavailable, the documented self-hosted/local/VM run from §12 is archived instead of skipping the gate.

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
| T2 | Timing sleeps appear at 26 test call sites and 5 product/example call sites (`rg -n "Task\\.sleep" Sources Tests Example`, 2026-09-07) | 1–7 | Sleeps in touched/concurrency coverage are release-blocking; unrelated deterministic migration may continue through checkpoint 8 |
| S1 | Package platform floors are unnecessarily high | 1, 8 | Release-blocking unless an evidence-backed exception is approved |
| R1 | `AGENTS.md` references a missing `RTK.md` | 8 | Must be repaired or the include removed before release |

Deferral to 0.2.x is permitted only for explicitly listed documentation or mechanical cleanup that does not affect safety, correctness, public API truthfulness, or a modified execution path. Every deferral must have an issue, rationale, owner, and target release; no release-blocking row may be deferred silently.

## 18. Acceptance criteria

- Existing behavior tests continue to pass except where explicitly changed by this design.
- New tests demonstrate cooperative cancellation of owned work and stale-result rejection without sleeps.
- Burst-update and teardown tests prove the process-wide cmark executor limits, per-session single flight/retry bounds, 64-token admission limit, latest-input coalescing, stale-output rejection, one follow-up parse for a live session, no follow-up for a tombstoned session, view/session deallocation while a fake cmark call remains blocked, and registry cleanup after 1,000-session churn.
- For incrementally safe 1 KB chunk fixtures, scanner, mapping, materialization/copy/substitution, cmark input, rendering preparation, and combined work stay within their §6 budgets; exhaustive and seeded differential tests prove fallback correctness for non-local constructs.
- Default image and link behavior enforces the approved security policy.
- Remote images remain placeholders until the host explicitly opts in; the default loader uses no ambient cookies, credentials, cache, or authentication and reports only sanitized errors.
- Image transfer/decode concurrency, upfront encoded reservations, lease-based hard decoded-pixel accounting across in-flight/cache/published snapshots, completed caches, and all negative caches enforce the §7 budgets under 100 distinct valid requests. Cache eviction cannot uncharge a still-published image, teardown returns the ledger to baseline, and two 17 MiB plus four 9 MiB concurrency fixtures cannot hold-and-wait.
- Configuration-ID tests prove default instance isolation, deterministic built-in equivalence, explicit semantic sharing, and separation of different output-affecting configurations across sessions.
- Normal copy is selection-exact; source copy reports mapping granularity.
- UIKit and AppKit expose non-duplicating tree-structured Markdown accessibility semantics with stable lineage identity, correct frames/hit testing, and focus continuity across growing-tail streaming updates.
- Default iOS style responds to Dynamic Type through accessibility sizes.
- The package builds and executes its relevant test and Example smoke suites on actual iOS 18 and macOS 15 runtimes. The only permitted exception is an approved minimum-version increase under §12, followed by execution on that new actual minimum runtime.
- Public API documentation and 0.2.0 migration notes are complete.
- SwiftFormat reports zero violations.
- Required macOS and iOS CI jobs pass.
- Rendered screenshots pass visual review.
- The complete diff passes final `superpowers-reviewer` review.

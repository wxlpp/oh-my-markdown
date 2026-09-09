import Foundation
import MarkdownRenderKit

/// Completed-cache identity: same bytes, same output extent, same configuration.
package struct ImageCacheKey: Hashable {
    package let source: URL
    package let pixelWidth: Int
    package let pixelHeight: Int
    package let configurationID: MarkdownConfigurationID
    package init(source: URL, pixelWidth: Int, pixelHeight: Int, configurationID: MarkdownConfigurationID) {
        self.source = source
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
        self.configurationID = configurationID
    }
}

/// Pre-decode identity. Production always builds it with the coordinator's
/// configured extent, so it is the *requested* extent, never the achieved one.
/// A downsized result is kept out of the process cache by the explicit
/// `decodedPixelSize == self.maxPixelSize` guard in `ImageLoadCoordinator.load`,
/// not by this key — do not delete that guard on the strength of this type's name.
package struct ImageSourceKey: Hashable {
    package let source: URL
    package let configurationID: MarkdownConfigurationID
    package let requestedPixelSize: Int
    package init(source: URL, configurationID: MarkdownConfigurationID, requestedPixelSize: Int) {
        self.source = source
        self.configurationID = configurationID
        self.requestedPixelSize = requestedPixelSize
    }
}

/// One physical decoded allocation. Accounting identity is `backingID`, not the
/// cache key: two sessions decoding the same URL charge two backings.
@MainActor package final class ImageBacking {
    package let backingID: UUID
    package let image: PlatformImage
    package let accountedPixelBytes: Int
    package init(backingID: UUID, image: PlatformImage, accountedPixelBytes: Int) {
        self.backingID = backingID
        self.image = image
        self.accountedPixelBytes = accountedPixelBytes
    }
}

/// Idempotent charge against one backing record. `release()` is the normal path;
/// `deinit` is the fallback that keeps a dropped lease from stranding cost.
@MainActor package final class ResidencyRecordToken {
    package let backingID: UUID
    fileprivate weak var ledger: ImageResidencyLedger?
    private var charged = true
    fileprivate init(ledger: ImageResidencyLedger, backingID: UUID) {
        self.ledger = ledger
        self.backingID = backingID
    }

    package func release() {
        guard self.charged else { return }
        self.charged = false
        self.ledger?.release(self.backingID)
    }

    fileprivate var owningLedger: ImageResidencyLedger? {
        self.charged ? self.ledger : nil
    }

    isolated deinit { if charged { ledger?.release(backingID) } }
}

@MainActor package final class ImageOwnerLease: ResourceResidencyOwner {
    private let token: ResidencyRecordToken
    package let backing: ImageBacking
    package var backingID: UUID {
        self.backing.backingID
    }

    package var accountedPixelBytes: Int {
        self.backing.accountedPixelBytes
    }

    fileprivate init(token: ResidencyRecordToken, backing: ImageBacking) {
        self.token = token
        self.backing = backing
    }

    /// A publication owner is an independent charge, so the caller may release
    /// this lease without ever leaving the backing unowned.
    package func acquirePublication() -> ImageOwnerLease? {
        self.token.owningLedger?.acquire(self.backingID)
    }

    package func release() {
        self.token.release()
    }
}

/// Never a naked backing: promotion and cache hits both hand back an owner.
@MainActor package struct OwnedImage {
    package var backing: ImageBacking {
        self.inFlightOwner.backing
    }

    package let inFlightOwner: ImageOwnerLease
    package init(inFlightOwner: ImageOwnerLease) {
        self.inFlightOwner = inFlightOwner
    }
}

/// Pre-decode charge. Held from before the decode permit is requested until the
/// backing is promoted, so a waiter never owns a decode slot plus pixel bytes.
@MainActor package final class DecodedPixelReservation {
    private weak var ledger: ImageResidencyLedger?
    private let id: UUID
    package private(set) var reservedBytes: Int
    private var active = true
    fileprivate init(ledger: ImageResidencyLedger, id: UUID, bytes: Int) {
        self.ledger = ledger
        self.id = id
        self.reservedBytes = bytes
    }

    package func reconcile(actualBytes: Int) -> Bool {
        guard self.active, let ledger, ledger.reconcile(self.id, bytes: actualBytes) else { return false }
        self.reservedBytes = actualBytes
        return true
    }

    /// Materializes the platform image and atomically converts the reservation
    /// into one backing record plus its first owner.
    package func promote(_ decoded: DecodedImage, scale: Double = 1) -> OwnedImage? {
        guard self.active, let ledger,
              self.reconcile(actualBytes: decoded.backing.accountedPixelBytes),
              let image = RenderMaterializer.platformImage(from: decoded.backing, scale: scale)
        else {
            self.cancel()
            return nil
        }
        self.active = false
        return ledger.promote(
            self.id,
            backing: ImageBacking(backingID: decoded.backingID, image: image, accountedPixelBytes: self.reservedBytes)
        )
    }

    package func cancel() {
        guard self.active else { return }
        self.active = false
        self.ledger?.cancelReservation(self.id)
    }

    isolated deinit { if active { ledger?.cancelReservation(id) } }
}

/// Holds the new snapshot's owners across one synchronous MainActor install.
/// It never touches the outgoing snapshot's owners: those are released by the
/// old snapshot itself once the view has cleared and replaced its TextKit content.
@MainActor package final class SnapshotLeaseTransaction {
    package let session: RenderSessionID
    /// Diagnostic identity, deliberately not load-bearing: an earlier attempt to
    /// guard the install on it compared a value against itself, because nothing
    /// can suspend between capturing it and committing.
    package let oldSnapshotID: UUID?
    package let newSnapshotID: UUID
    private var owners: [any ResourceResidencyOwner]
    package var ownerCount: Int {
        self.owners.count
    }

    fileprivate init(session: RenderSessionID, oldSnapshotID: UUID?, newSnapshotID: UUID, owners: [any ResourceResidencyOwner]) {
        self.session = session
        self.oldSnapshotID = oldSnapshotID
        self.newSnapshotID = newSnapshotID
        self.owners = owners
    }

    /// `install` receives the new owners and reports, through `handOver`, which of
    /// them the new snapshot now retains. Whatever it does not take stays this
    /// transaction's to release — including on the success path, because a
    /// materializer legitimately declines owners it cannot display (a resource
    /// inside a blockquote resolves to nothing). Releasing all-or-nothing here
    /// would uncharge an image the installed snapshot is still showing.
    package func commit(_ install: (([any ResourceResidencyOwner]) -> Void, [any ResourceResidencyOwner]) throws -> Void) rethrows {
        let owners = self.owners
        var retained: Set<ObjectIdentifier> = []
        defer {
            for owner in owners where !retained.contains(ObjectIdentifier(owner)) {
                owner.release()
            }
            self.owners.removeAll()
        }
        try install({ handed in retained.formUnion(handed.map(ObjectIdentifier.init)) }, owners)
    }

    package func cancel() {
        for owner in self.owners {
            owner.release()
        }
        self.owners.removeAll()
    }

    isolated deinit { for owner in owners {
        owner.release()
    } }
}

@MainActor package final class ImageResidencyLedger {
    package static let shared: ImageResidencyLedger = {
        let ledger = ImageResidencyLedger()
        ledger.observeMemoryPressure()
        return ledger
    }()

    package static let negativeTTL = Duration.seconds(300)
    package static let negativeCapacity = 128

    private struct Record {
        let backing: ImageBacking
        var owners: Int
    }

    package let hardLimit: Int
    package let cacheLimit: Int
    private let clock: any RenderSessionClock
    private var pressureSource: (any DispatchSourceMemoryPressure)?
    private var reservations: [UUID: Int] = [:]
    private var records: [UUID: Record] = [:]
    private var cache: [ImageCacheKey: ImageOwnerLease] = [:]
    private var order: [ImageCacheKey] = []
    private var index: [ImageSourceKey: ImageCacheKey] = [:]
    private var negative: [ImageSourceKey: (expiry: Duration, category: MarkdownResourceError)] = [:]
    private var negativeOrder: [ImageSourceKey] = []
    package private(set) var accountedBytes = 0
    package var reservedBytes: Int {
        self.reservations.values.reduce(0, +)
    }

    package var recordCount: Int {
        self.records.count
    }

    package var cacheCount: Int {
        self.cache.count
    }

    package var negativeCount: Int {
        self.negative.count
    }

    package var cacheBytes: Int {
        Set(self.cache.values.map(\.backingID)).reduce(0) { $0 + (self.records[$1]?.backing.accountedPixelBytes ?? 0) }
    }

    /// Baseline means no charge, no reservation and no cached ownership.
    package var isAtBaseline: Bool {
        self.accountedBytes == 0 && self.reservations.isEmpty && self.records.isEmpty && self.cache.isEmpty
    }

    package init(
        hardLimit: Int = 192 << 20, cacheLimit: Int = 128 << 20,
        clock: any RenderSessionClock = ContinuousRenderSessionClock()
    ) {
        self.hardLimit = max(0, hardLimit)
        self.cacheLimit = max(0, min(hardLimit, cacheLimit))
        self.clock = clock
    }

    // MARK: Reservations

    private func makeRoom(_ additional: Int) -> Bool {
        guard additional >= 0, additional <= self.hardLimit else { return false }
        while self.accountedBytes > self.hardLimit - additional {
            guard let key = order.first(where: { key in
                guard let lease = cache[key] else { return false }
                return records[lease.backingID]?.owners == cache.values.count(where: { $0.backingID == lease.backingID })
            }) else { return false }
            self.evictCacheEntry(for: key)
        }
        return true
    }

    package func reserveDecodedPixelBytes(_ bytes: Int) -> DecodedPixelReservation? {
        guard bytes > 0, bytes <= ImageDecoder.perImageByteLimit, self.makeRoom(bytes) else { return nil }
        let id = UUID()
        self.reservations[id] = bytes
        self.accountedBytes += bytes
        return DecodedPixelReservation(ledger: self, id: id, bytes: bytes)
    }

    fileprivate func reconcile(_ id: UUID, bytes: Int) -> Bool {
        guard let previous = reservations[id], bytes > 0, bytes <= ImageDecoder.perImageByteLimit,
              bytes <= previous || self.makeRoom(bytes - previous) else { return false }
        self.accountedBytes += bytes - previous
        self.reservations[id] = bytes
        return true
    }

    fileprivate func cancelReservation(_ id: UUID) {
        if let bytes = reservations.removeValue(forKey: id) { self.accountedBytes -= bytes }
    }

    fileprivate func promote(_ id: UUID, backing: ImageBacking) -> OwnedImage? {
        guard self.reservations[id] == backing.accountedPixelBytes, self.records[backing.backingID] == nil else {
            self.cancelReservation(id)
            return nil
        }
        self.reservations[id] = nil
        self.records[backing.backingID] = Record(backing: backing, owners: 0)
        guard let owner = acquire(backing.backingID) else {
            self.records[backing.backingID] = nil
            self.accountedBytes -= backing.accountedPixelBytes
            return nil
        }
        return OwnedImage(inFlightOwner: owner)
    }

    // MARK: Records

    fileprivate func acquire(_ id: UUID) -> ImageOwnerLease? {
        guard let record = records[id] else { return nil }
        self.records[id]?.owners += 1
        return ImageOwnerLease(token: ResidencyRecordToken(ledger: self, backingID: id), backing: record.backing)
    }

    fileprivate func release(_ id: UUID) {
        guard var record = records[id] else { return }
        precondition(record.owners > 0)
        record.owners -= 1
        if record.owners == 0 {
            self.records[id] = nil
            self.accountedBytes -= record.backing.accountedPixelBytes
        } else {
            self.records[id] = record
        }
    }

    package func ownerCount(_ id: UUID) -> Int {
        self.records[id]?.owners ?? 0
    }

    // MARK: Completed cache

    package func insert(_ image: OwnedImage, for key: ImageCacheKey, indexedBy source: ImageSourceKey) {
        guard image.backing.accountedPixelBytes <= self.cacheLimit, let owner = acquire(image.backing.backingID) else { return }
        self.evictCacheEntry(for: key)
        self.cache[key] = owner
        self.order.append(key)
        self.index[source] = key
        while self.cacheBytes > self.cacheLimit, let oldest = order.first, oldest != key {
            self.evictCacheEntry(for: oldest)
        }
    }

    package func completedImage(for key: ImageCacheKey) -> OwnedImage? {
        guard let cached = cache[key], let owner = acquire(cached.backingID) else { return nil }
        self.order.removeAll { $0 == key }
        self.order.append(key)
        return OwnedImage(inFlightOwner: owner)
    }

    package func completedImage(for source: ImageSourceKey) -> OwnedImage? {
        guard let key = index[source] else { return nil }
        return self.completedImage(for: key)
    }

    package func evictCacheEntry(for key: ImageCacheKey) {
        guard let lease = cache.removeValue(forKey: key) else { return }
        self.order.removeAll { $0 == key }
        for (source, indexed) in self.index where indexed == key {
            self.index[source] = nil
        }
        lease.release()
    }

    /// Subscribes the process signal to cache-owner release. Only the shared
    /// instance does this; injected test ledgers stay inert and deterministic.
    package var observesMemoryPressure: Bool {
        self.pressureSource != nil
    }

    package func observeMemoryPressure() {
        guard self.pressureSource == nil else { return }
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.handleMemoryPressure() }
        }
        source.resume()
        self.pressureSource = source
    }

    /// Releases cache ownership only. Anything still published stays charged.
    package func handleMemoryPressure() {
        for key in self.order {
            self.evictCacheEntry(for: key)
        }
    }

    // MARK: Negative cache

    package func isNegative(_ key: ImageSourceKey) -> Bool {
        self.negativeCategory(key) != nil
    }

    /// Replays the original deterministic category so a suppressed refetch stays
    /// observationally identical to the failure it caches.
    package func negativeCategory(_ key: ImageSourceKey) -> MarkdownResourceError? {
        guard let entry = negative[key] else { return nil }
        self.negativeOrder.removeAll { $0 == key }
        guard self.clock.now() < entry.expiry else {
            self.negative[key] = nil
            return nil
        }
        self.negativeOrder.append(key)
        return entry.category
    }

    package func insertNegative(_ key: ImageSourceKey, category: MarkdownResourceError) {
        self.negative[key] = (self.clock.now() + Self.negativeTTL, category)
        self.negativeOrder.removeAll { $0 == key }
        self.negativeOrder.append(key)
        if self.negativeOrder.count > Self.negativeCapacity { self.negative[self.negativeOrder.removeFirst()] = nil }
    }

    // MARK: Snapshot replacement

    package func prepareSnapshotReplacement(
        session: RenderSessionID, oldSnapshotID: UUID?, newSnapshotID: UUID,
        owners: [any ResourceResidencyOwner]
    ) -> SnapshotLeaseTransaction {
        SnapshotLeaseTransaction(session: session, oldSnapshotID: oldSnapshotID, newSnapshotID: newSnapshotID, owners: owners)
    }

    /// Converts in-flight owners into publication owners without ever dropping to
    /// zero owners in between.
    package func prepareSnapshotReplacement(
        session: RenderSessionID = .init(rawValue: UUID()), oldSnapshotID: UUID? = nil,
        newSnapshotID: UUID = UUID(), images: [OwnedImage]
    ) -> SnapshotLeaseTransaction? {
        var owners: [any ResourceResidencyOwner] = []
        for image in images {
            guard let publication = image.inFlightOwner.acquirePublication() else {
                for owner in owners {
                    owner.release()
                }
                return nil
            }
            owners.append(publication)
        }
        for image in images {
            image.inFlightOwner.release()
        }
        return self.prepareSnapshotReplacement(
            session: session, oldSnapshotID: oldSnapshotID, newSnapshotID: newSnapshotID, owners: owners
        )
    }
}

/// Shared residency instances. Tests inject private ones so parallel suites do
/// not contend for the same process budgets.
@MainActor package struct ImageResidencyConfiguration {
    package var ledger: ImageResidencyLedger
    package var permits: ImageResourceCoordinator
    package var maxPixelSize: Int
    package static var shared: Self {
        Self()
    }

    package init(
        ledger: ImageResidencyLedger = .shared, permits: ImageResourceCoordinator = .shared,
        maxPixelSize: Int = ImageDecoder.maxOutputSide
    ) {
        self.ledger = ledger
        self.permits = permits
        self.maxPixelSize = maxPixelSize
    }
}

/// Test seam: session-level injection so a suite can keep its parse admission,
/// clock and residency budgets private instead of contending for the process-wide
/// ones. Production always uses the shared instances and the real clock.
@MainActor package struct RenderSessionOverrides {
    package var executor: ParseExecutor
    package var clock: any RenderSessionClock
    package var residency: ImageResidencyConfiguration
    package init(
        executor: ParseExecutor = .shared,
        clock: any RenderSessionClock = ContinuousRenderSessionClock(),
        residency: ImageResidencyConfiguration = .shared
    ) {
        self.executor = executor
        self.clock = clock
        self.residency = residency
    }
}

/// Session-owned image admission. Process budgets live in the shared coordinator
/// and ledger; this type owns only per-session tasks and completed hand-offs.
@MainActor package final class ImageLoadCoordinator {
    package enum Deferral: Equatable { case residency, admission }

    private enum Outcome {
        case owned(OwnedImage, ImageCacheKey, decodedPixelSize: Int)
        /// Residency or admission pressure: an accessible placeholder, no callback.
        case deferred(Deferral)
        /// `cacheable` is false for connectivity and timeout failures, which are
        /// reported to the host but must never suppress a later retry.
        case failed(MarkdownResourceError, cacheable: Bool)
        case cancelled
    }

    package let ledger: ImageResidencyLedger
    private let permits: ImageResourceCoordinator
    private let sessionID: RenderSessionID
    private let maxPixelSize: Int
    private var tasks: [ImageSourceKey: Task<Void, Never>] = [:]
    private var resolved: [ImageSourceKey: ImageOwnerLease] = [:]
    private var epoch: UInt64 = 0
    package private(set) var configuration: MarkdownImageConfiguration = .disabled
    /// Counts every finished resolution, whatever its outcome — published,
    /// deferred, failed, cancelled, or discarded by a replaced generation. Tests
    /// wait on this instead of counting actor turns; it cannot say which happened.
    package private(set) var settledResolutionCount = 0
    package var taskCount: Int {
        self.tasks.count
    }

    package var resolvedCount: Int {
        self.resolved.count
    }

    package init(sessionID: RenderSessionID, residency: ImageResidencyConfiguration = .shared) {
        self.sessionID = sessionID
        self.ledger = residency.ledger
        self.permits = residency.permits
        // The decoder clamps to its own ceiling, so a larger configured value would
        // make every result look downsized and silently disable the process cache.
        self.maxPixelSize = min(max(1, residency.maxPixelSize), ImageDecoder.maxOutputSide)
    }

    package func configure(_ configuration: MarkdownImageConfiguration) {
        self.cancelAll()
        self.configuration = configuration
    }

    /// Cancels in-flight work only. A width, style or append mutation must not drop
    /// a displayed image back to a placeholder and refetch it.
    package func cancelTasks() {
        self.epoch &+= 1
        let hadTasks = !self.tasks.isEmpty
        for task in self.tasks.values {
            task.cancel()
        }
        self.tasks.removeAll()
        // Every view mutation reaches here. Only a session that actually queued work
        // may touch the shared coordinator, which is otherwise a process-wide
        // serialization point for views that never load an image at all.
        guard hadTasks else { return }
        let permits = self.permits
        let sessionID = self.sessionID
        Task { await permits.cancelQueued(session: sessionID) }
    }

    /// Also drops this session's completed resolutions, for source, image
    /// configuration and teardown changes that invalidate what it resolved.
    package func cancelAll() {
        self.cancelTasks()
        for lease in self.resolved.values {
            lease.release()
        }
        self.resolved.removeAll()
    }

    private func sourceKey(_ source: URL) -> ImageSourceKey {
        ImageSourceKey(
            source: source, configurationID: self.configuration.configurationID,
            requestedPixelSize: self.maxPixelSize
        )
    }

    /// Releases resolutions the installed model no longer references, so a long
    /// streamed document cannot pin residency behind images it stopped showing.
    package func retainOnly(_ sources: Set<URL>) {
        let keys = Set(sources.map { self.sourceKey($0) })
        for (key, lease) in self.resolved where !keys.contains(key) {
            lease.release()
            self.resolved[key] = nil
        }
    }

    /// Hands out an independent publication owner. The session keeps its own
    /// resolution lease until cancellation, so re-materializing a snapshot cannot
    /// fall back to a placeholder — and refetch — merely because the shared
    /// completed cache evicted the entry in between.
    package func publication(for source: URL) -> ImageOwnerLease? {
        let key = self.sourceKey(source)
        if let publication = resolved[key]?.acquirePublication() { return publication }
        guard let hit = ledger.completedImage(for: key) else { return nil }
        self.resolved[key] = hit.inFlightOwner
        return hit.inFlightOwner.acquirePublication()
    }

    @discardableResult
    package func load(
        source: URL,
        isCurrent: @escaping @MainActor () -> Bool,
        completed: @escaping @MainActor () -> Void,
        failed: @escaping @MainActor (MarkdownResourceError?, Deferral?) -> Void
    ) -> Task<Void, Never>? {
        let key = self.sourceKey(source)
        guard let loader = configuration.loader, isCurrent() else { return nil }
        if let category = ledger.negativeCategory(key) {
            failed(category, nil)
            return nil
        }
        if self.resolved[key] != nil {
            completed()
            return nil
        }
        if let hit = ledger.completedImage(for: key) {
            self.resolved[key] = hit.inFlightOwner
            completed()
            return nil
        }
        if let task = tasks[key] { return task }
        let epoch = self.epoch
        let request = self.configuration.request(for: source)
        let task = Task { [weak self] in
            guard let start = self else { return }
            let outcome = await start.resolve(loader: loader, request: request, key: key)
            guard let self else {
                if case .owned(let owned, _, _) = outcome { owned.inFlightOwner.release() }
                return
            }
            self.settledResolutionCount &+= 1
            guard self.epoch == epoch else {
                if case .owned(let owned, _, _) = outcome { owned.inFlightOwner.release() }
                return
            }
            self.tasks[key] = nil
            guard !Task.isCancelled, isCurrent() else {
                if case .owned(let owned, _, _) = outcome { owned.inFlightOwner.release() }
                return
            }
            switch outcome {
            case .owned(let owned, let cacheKey, let decodedPixelSize):
                // A downsized decode stays session-local: publishing it to the
                // process cache would serve a degraded image to a later
                // full-extent requester. The decoder reports the extent it
                // actually used, because it can halve again on its own.
                if decodedPixelSize == self.maxPixelSize {
                    self.ledger.insert(owned, for: cacheKey, indexedBy: key)
                }
                self.resolved.removeValue(forKey: key)?.release()
                self.resolved[key] = owned.inFlightOwner
                completed()
            case .failed(let error, let cacheable):
                if cacheable { self.ledger.insertNegative(key, category: error) }
                failed(error, nil)
            case .deferred(let reason):
                failed(nil, reason)
            case .cancelled:
                break
            }
        }
        self.tasks[key] = task
        return task
    }

    /// Admission order is fixed: transfer slot plus the full encoded allowance
    /// together, then decoded pixel bytes, then the decode slot. Nothing waits
    /// while holding the next resource in that order, so the pipeline is acyclic.
    private func resolve(loader: any MarkdownImageLoading, request: MarkdownImageRequest, key: ImageSourceKey) async -> Outcome {
        let admission: ImageResourceCoordinator.TransferAdmission
        do { admission = try await self.permits.acquireTransfer(session: self.sessionID) }
        catch { return .cancelled }

        let encoded: MarkdownEncodedImage
        do {
            encoded = try await ValidatedImageFactory.load(loader, request: request)
            await admission.permit.release()
        } catch {
            await admission.permit.release()
            await admission.reservation.rejectAndRelease()
            let category = MarkdownResourceError.classify(error)
            switch category {
            case .cancelled: return .cancelled
            case .timedOut, .transport: return .failed(category, cacheable: false)
            default: return .failed(category, cacheable: true)
            }
        }

        // A replaced generation is already cancelled here, so its bytes never reach
        // the decoder, the ledger or either cache.
        if Task.isCancelled {
            await admission.reservation.rejectAndRelease()
            return .cancelled
        }

        let reserved: ReservedEncodedImage
        do { reserved = try await admission.reservation.attach(encoded) }
        catch {
            await admission.reservation.rejectAndRelease()
            return .failed(.encodedLimit, cacheable: true)
        }

        guard let full = ImageDecoder.reservationBytes(for: encoded.metadata, maxPixelSize: self.maxPixelSize) else {
            await reserved.reservation.rejectAndRelease()
            return .failed(.metadataLimit, cacheable: true)
        }
        var side = self.maxPixelSize
        var reservation = self.ledger.reserveDecodedPixelBytes(full)
        if reservation == nil, self.maxPixelSize > 1 {
            // One smaller attempt before giving up keeps the placeholder path rare
            // while the hard residency limit still holds.
            side = max(1, self.maxPixelSize / 2)
            if let smaller = ImageDecoder.reservationBytes(for: encoded.metadata, maxPixelSize: side) {
                reservation = self.ledger.reserveDecodedPixelBytes(smaller)
            }
        }
        guard let reservation else {
            await reserved.reservation.rejectAndRelease()
            return .deferred(.residency)
        }

        let decodePermit: ImageResourcePermit
        do { decodePermit = try await self.permits.acquireDecodePermit(session: self.sessionID) }
        catch {
            reservation.cancel()
            await reserved.reservation.rejectAndRelease()
            return .cancelled
        }

        let decoded: DecodedImage
        do {
            decoded = try await ImageDecoder.decode(
                reserved, maxPixelSize: side, permit: decodePermit,
                reconcile: { reservation.reconcile(actualBytes: $0) }
            )
        } catch {
            reservation.cancel()
            if let failure = error as? ImageDecodeFailure {
                return failure == .budgetDeferred ? .deferred(.residency) : .failed(.typeMismatch, cacheable: true)
            }
            return error is CancellationError ? .cancelled : .failed(.typeMismatch, cacheable: true)
        }

        guard let owned = reservation.promote(decoded) else { return .deferred(.residency) }
        guard let frame = decoded.backing.frames.first else {
            owned.inFlightOwner.release()
            return .failed(.typeMismatch, cacheable: true)
        }
        return .owned(owned, ImageCacheKey(
            source: request.url, pixelWidth: frame.width, pixelHeight: frame.height,
            configurationID: key.configurationID
        ), decodedPixelSize: decoded.decodedPixelSize)
    }

    isolated deinit {
        for task in tasks.values {
            task.cancel()
        }
        for lease in resolved.values {
            lease.release()
        }
    }
}

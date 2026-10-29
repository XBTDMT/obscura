// ObscuraSearch — the Spotlight index behind a protocol, so tests use a fake and never touch the Mac's real index.
import Foundation
import CoreSpotlight
import ObscuraSupport

/// Where items go. The app passes `CoreSpotlightIndex`; tests pass a recording fake.
public protocol SearchIndexing: Sendable {
    func index(_ items: [SearchItemContent]) async throws
    func delete(identifiers: [String]) async throws
    func deleteAll(domain: String) async throws
}

/// Core Spotlight: the app's own items, private to this Mac. Needs no entitlement in a non-sandboxed app.
public struct CoreSpotlightIndex: SearchIndexing {
    public static let indexName = AppIdentity.current.spotlightDomain

    public init() {}

    private var index: CSSearchableIndex { CSSearchableIndex(name: Self.indexName) }

    public func index(_ items: [SearchItemContent]) async throws {
        guard !items.isEmpty else { return }
        try await index.indexSearchableItems(items.map(Self.searchableItem))
    }

    public func delete(identifiers: [String]) async throws {
        guard !identifiers.isEmpty else { return }
        try await index.deleteSearchableItems(withIdentifiers: identifiers)
    }

    public func deleteAll(domain: String) async throws {
        try await index.deleteSearchableItems(withDomainIdentifiers: [domain])
    }

    /// The only place a `CSSearchableItem` is made: field for field from the pure content.
    static func searchableItem(_ content: SearchItemContent) -> CSSearchableItem {
        let attributes = CSSearchableItemAttributeSet(contentType: .image)
        attributes.title = content.title
        attributes.displayName = content.displayName
        attributes.contentDescription = content.contentDescription
        attributes.keywords = content.keywords
        attributes.contentCreationDate = content.contentCreationDate
        attributes.thumbnailData = content.thumbnailData
        let item = CSSearchableItem(uniqueIdentifier: content.uniqueIdentifier, domainIdentifier: content.domainIdentifier,
                                    attributeSet: attributes)
        item.expirationDate = .distantFuture   // the covered file's lifetime decides, not Spotlight's 30-day default
        return item
    }

    /// The identifiers of the items Obscura holds in Spotlight now, read back with a Core Spotlight query of the app's
    /// own items. For the debug report only (counts and ids); it needs the app's bundle, so it runs in the app.
    public static func heldIdentifiers(timeout: Duration = .seconds(10)) async throws -> [String] {
        let context = CSSearchQueryContext()
        context.fetchAttributes = []
        let query = CSSearchQuery(queryString: "title == \"*\"", queryContext: context)
        let box = IdentifierBox()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], any Error>) in
            query.foundItemsHandler = { items in box.add(items.filter { $0.domainIdentifier == SearchItemContent.domain }.map(\.uniqueIdentifier)) }
            query.completionHandler = { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume(returning: box.all) }
            }
            query.start()
        }
    }
}

/// Collects query results across the query's own serial callbacks.
private final class IdentifierBox: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: [String] = []
    func add(_ more: [String]) { lock.withLock { ids += more } }
    var all: [String] { lock.withLock { ids.sorted() } }
}

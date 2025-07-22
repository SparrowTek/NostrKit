import Foundation
import CoreNostr

/// Extensions to RelayPool for simplified subscription operations
extension RelayPool {
    
    /// Subscribes to events and collects them for a specified timeout
    /// - Parameters:
    ///   - filters: The filters to apply
    ///   - timeout: How long to wait for events
    /// - Returns: Array of collected events
    public func subscribe(
        filters: [Filter],
        timeout: TimeInterval
    ) async throws -> [NostrEvent] {
        let subscriptionId = UUID().uuidString
        let subscription = try await subscribe(filters: filters, id: subscriptionId)
        
        var events: [NostrEvent] = []
        
        // Create a task that collects events
        let collectTask = Task {
            for await event in await subscription.events {
                events.append(event)
            }
        }
        
        // Wait for timeout
        try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
        
        // Close subscription and cancel collection
        await closeSubscription(id: subscriptionId)
        collectTask.cancel()
        
        return events
    }
    
    /// Publishes an event to all connected relays
    /// - Parameter event: The event to publish
    public func publish(event: NostrEvent) async throws {
        let results = await publish(event)
        
        // Check if at least one relay accepted the event
        let successCount = results.filter { $0.success }.count
        if successCount == 0 {
            let errors = results.compactMap { $0.error }.map { $0.localizedDescription }.joined(separator: ", ")
            throw NostrError.networkError(
                operation: .send,
                reason: "Failed to publish to any relay: \(errors)"
            )
        }
    }
    
    /// Publishes an event to specific relays
    /// - Parameters:
    ///   - event: The event to publish
    ///   - relayURLs: The relay URLs to publish to
    public func publish(event: NostrEvent, to relayURLs: [String]) async throws {
        let results = await publish(event, to: relayURLs)
        
        // Check if at least one relay accepted the event
        let successCount = results.filter { $0.success }.count
        if successCount == 0 {
            let errors = results.compactMap { $0.error }.map { $0.localizedDescription }.joined(separator: ", ")
            throw NostrError.networkError(
                operation: .send,
                reason: "Failed to publish to any specified relay: \(errors)"
            )
        }
    }
}

/// Extension to add missing NostrError cases
extension NostrError {
    /// Configuration error
    public static func configurationError(message: String) -> NostrError {
        return .validationError(field: "configuration", reason: message)
    }
}

/// Extension to EventCache for simpler API

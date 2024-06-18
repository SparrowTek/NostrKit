//
//  Event.swift
//  
//
//  Created by Thomas Rademaker on 6/18/24.
//

import Foundation
import CryptoKit

public enum EventError: Error {
    case stringSerialization
}

public struct Event: Codable {
    public var id: String
    public let pubkey: String
    public let createdAt: Int
    public let kind: Int
    public let tags: [[String]]
    public let content: String
    public let sig: String
}

extension Event {
    private func toSerializedString() throws(EventError) -> String {
        let eventArray: [Any] = [0, pubkey, createdAt, kind, tags, content]
        guard let jsonData = try? JSONSerialization.data(withJSONObject: eventArray),
              let jsonString = String(data: jsonData, encoding: .utf8) else { throw .stringSerialization }
        return jsonString
    }
    
    private func calculateId() throws(EventError) -> String {
        let serializedString = try toSerializedString()
        let data = Data(serializedString.utf8)
        let hash = SHA256.hash(data: data)
        return hash.map { String(format: "%02x", $0) }.joined()
    }
    
    public func withCalculatedID() throws(EventError) -> Event {
        let id = try calculateId()
        return Event(id: id, pubkey: pubkey, createdAt: createdAt, kind: kind, tags: tags, content: content, sig: sig)
    }
}

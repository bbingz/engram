// macos/Engram/Models/IndexedMessage.swift
import Foundation

struct IndexedMessage: Identifiable {
    let id: UUID
    let message: ChatMessage
    let messageType: MessageType
    let typeIndex: Int

    init(message: ChatMessage, messageType: MessageType, typeIndex: Int) {
        self.id = message.id
        self.message = message
        self.messageType = messageType
        self.typeIndex = typeIndex
    }

    static func build(from messages: [ChatMessage]) -> (messages: [IndexedMessage], counts: [MessageType: Int]) {
        var counters: [MessageType: Int] = [:]
        for type in MessageType.allCases { counters[type] = 0 }

        let indexed = messages.map { msg in
            let type = MessageTypeClassifier.classify(msg)
            counters[type, default: 0] += 1
            return IndexedMessage(message: msg, messageType: type, typeIndex: counters[type]!)
        }
        return (indexed, counters)
    }
}

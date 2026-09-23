import Foundation
import SwiftData

@Model
final class VoiceTag {
    @Attribute(.unique) var id: UUID = UUID()
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
    var kindRaw: String = VoiceTagKind.activity.rawValue
    var name: String = ""
    var isBuiltIn: Bool = false
    var sortOrder: Int = 0

    init(id: UUID = UUID(), kind: VoiceTagKind, name: String, isBuiltIn: Bool = false, sortOrder: Int = 0) {
        self.id = id
        self.kindRaw = kind.rawValue
        self.name = name
        self.isBuiltIn = isBuiltIn
        self.sortOrder = sortOrder
    }

    var kind: VoiceTagKind {
        get { VoiceTagKind(rawValue: kindRaw) ?? .activity }
        set { kindRaw = newValue.rawValue }
    }
}

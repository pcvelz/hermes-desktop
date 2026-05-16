import Foundation

struct KanbanDispatcherStatus: Codable, Hashable, Sendable {
    let running: Bool?
    let message: String?
}

enum SkillFeatureBadge: String, Identifiable {
    case references
    case scripts
    case templates

    var id: String { rawValue }
}

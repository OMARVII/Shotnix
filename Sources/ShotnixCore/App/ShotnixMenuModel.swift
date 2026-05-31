import Foundation

enum ShotnixMenuRole: String {
    case normal
    case primary
    case destructive
}

struct ShotnixMenuAction: Identifiable {
    let id: String
    let title: String
    let subtitle: String?
    let symbolName: String
    let shortcut: String?
    let isEnabled: Bool
    let role: ShotnixMenuRole
    let handler: () -> Void

    init(
        id: String,
        title: String,
        subtitle: String? = nil,
        symbolName: String,
        shortcut: String? = nil,
        isEnabled: Bool = true,
        role: ShotnixMenuRole = .normal,
        handler: @escaping () -> Void = {}
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.symbolName = symbolName
        self.shortcut = shortcut
        self.isEnabled = isEnabled
        self.role = role
        self.handler = handler
    }
}

struct ShotnixMenuSection: Identifiable {
    let id: String
    let title: String
    let actions: [ShotnixMenuAction]

    init(id: String, title: String, actions: [ShotnixMenuAction]) {
        self.id = id
        self.title = title
        self.actions = actions
    }
}

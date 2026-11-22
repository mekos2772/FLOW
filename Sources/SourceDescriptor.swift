import Foundation

/// 源的自我描述。表现层的源选择界面只读这个结构，不读具体实现。
struct SourceDescriptor: Hashable, Codable, Sendable {
    enum SourceKind: String, Hashable, Codable, Sendable {
        case builtinLocal
        case standardServer
        case jsPlugin
        case jsonTemplate
        case builtinLegacy
        case mock
    }

    let id: SourceID
    let displayName: String
    let kind: SourceKind
    let requiresNetwork: Bool
    let supportsSearch: Bool
    let supportsLyrics: Bool
    let supportsDiscover: Bool
    let supportsAccount: Bool
    let supportsRelatedRadio: Bool
    let supportsQualitySelection: Bool
    let allowedDomains: [String]

    init(id: SourceID,
         displayName: String,
         kind: SourceKind = .builtinLegacy,
         requiresNetwork: Bool = false,
         supportsSearch: Bool = true,
         supportsLyrics: Bool = true,
         supportsDiscover: Bool = false,
         supportsAccount: Bool = false,
         supportsRelatedRadio: Bool = false,
         supportsQualitySelection: Bool = false,
         allowedDomains: [String] = []) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.requiresNetwork = requiresNetwork
        self.supportsSearch = supportsSearch
        self.supportsLyrics = supportsLyrics
        self.supportsDiscover = supportsDiscover
        self.supportsAccount = supportsAccount
        self.supportsRelatedRadio = supportsRelatedRadio
        self.supportsQualitySelection = supportsQualitySelection
        self.allowedDomains = allowedDomains
    }
}

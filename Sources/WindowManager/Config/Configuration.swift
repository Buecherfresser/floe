import Foundation

struct FocusFollowsMouseConfig: Codable, Equatable, Sendable {
    var enabled: Bool
    var delay: Int
    var ignoreApps: [String]

    static let `default` = FocusFollowsMouseConfig(
        enabled: true,
        delay: 10,
        ignoreApps: []
    )
}

struct Configuration: Codable, Equatable, Sendable {
    var focusFollowsMouse: FocusFollowsMouseConfig
    var debug: Bool

    static let `default` = Configuration(
        focusFollowsMouse: .default,
        debug: false
    )
}

import Foundation

struct FinderContext: Sendable {
    let currentDirectory: URL?
    let selectedFiles: [URL]
    let visibleFiles: [URL]
    let installedTools: [String]
    let timestamp: Date
}

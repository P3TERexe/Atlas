import Foundation

/// Canonical media file extensions shared across the parser, validators and plugins.
enum MediaFormats {
    static let image: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "tiff", "gif"]
    static let video: Set<String> = ["mp4", "mov", "m4v", "mkv", "avi", "webm", "flv", "wmv", "ts"]
    static let pdf: Set<String> = ["pdf"]
}

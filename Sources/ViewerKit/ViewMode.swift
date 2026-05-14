import Foundation

/// How a file is currently being displayed. Only meaningful for file types
/// that have multiple representations (markdown). Pure data.
public enum ViewMode: String, Equatable, Sendable, CaseIterable {
    case rendered
    case source
}

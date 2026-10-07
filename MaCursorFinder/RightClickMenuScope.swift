import Foundation

enum RightClickMenuScope {
    static let roots = ["/Users", "/Volumes"].map { URL(fileURLWithPath: $0, isDirectory: true) }
}

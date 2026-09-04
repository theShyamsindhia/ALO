import Foundation

public struct AppVersion: Comparable, Equatable, Sendable, CustomStringConvertible {
    public let components: [Int]
    public let prerelease: String?

    public init?(_ rawValue: String) {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.hasPrefix("v") ? String(trimmed.dropFirst()) : trimmed
        let versionAndBuild = value.split(separator: "+", maxSplits: 1, omittingEmptySubsequences: false)
        let versionAndPrerelease = versionAndBuild[0].split(
            separator: "-", maxSplits: 1, omittingEmptySubsequences: false
        )
        let fields = versionAndPrerelease[0].split(separator: ".", omittingEmptySubsequences: false)
        guard !fields.isEmpty, fields.count <= 4,
              fields.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              fields.compactMap({ Int($0) }).count == fields.count
        else { return nil }
        var parsed = fields.compactMap { Int($0) }
        while parsed.count > 1, parsed.last == 0 { parsed.removeLast() }
        components = parsed
        prerelease = versionAndPrerelease.count == 2 && !versionAndPrerelease[1].isEmpty
            ? String(versionAndPrerelease[1]) : nil
    }

    public var description: String {
        components.map(String.init).joined(separator: ".") + (prerelease.map { "-\($0)" } ?? "")
    }

    public static func < (lhs: AppVersion, rhs: AppVersion) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (.some, .none): return true
        case (.none, .some): return false
        case let (.some(left), .some(right)):
            return left.localizedStandardCompare(right) == .orderedAscending
        case (.none, .none): return false
        }
    }
}

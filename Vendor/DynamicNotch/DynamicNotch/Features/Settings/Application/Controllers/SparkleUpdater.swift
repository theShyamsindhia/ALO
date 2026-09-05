// ALO embedding adapter: feature code never initializes the upstream app updater.
import Combine

@MainActor
final class SparkleUpdater: ObservableObject {
    static let shared = SparkleUpdater()
    @Published var canCheckForUpdates = false
    @Published var automaticallyChecksForUpdates = false
    @Published var automaticallyDownloadsUpdates = false
    @Published var isUpdateAvailable = false
    @Published var latestVersionString = ""
    func checkForUpdates() {} // ALO owns application updates.
}

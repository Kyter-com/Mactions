import SwiftUI

#if canImport(Sparkle)
import Combine
import Sparkle

@MainActor
final class AppUpdater {
  static let shared = AppUpdater()

  let updaterController: SPUStandardUpdaterController?

  var updater: SPUUpdater? { updaterController?.updater }

  private init() {
    guard Self.hasSparkleConfiguration else {
      updaterController = nil
      return
    }
    updaterController = SPUStandardUpdaterController(
      startingUpdater: true,
      updaterDelegate: nil,
      userDriverDelegate: nil)
  }

  private static var hasSparkleConfiguration: Bool {
    guard
      let feedURL = Bundle.main.object(forInfoDictionaryKey: "SUFeedURL") as? String,
      let publicKey = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String
    else {
      return false
    }

    return !feedURL.isEmpty
      && !publicKey.isEmpty
      && !publicKey.contains("$(")
  }
}

@MainActor
final class CheckForUpdatesViewModel: ObservableObject {
  @Published var canCheckForUpdates = false

  private var cancellable: AnyCancellable?

  init(updater: SPUUpdater?) {
    guard let updater else { return }
    canCheckForUpdates = updater.canCheckForUpdates
    cancellable = updater.publisher(for: \.canCheckForUpdates)
      .receive(on: RunLoop.main)
      .sink { [weak self] value in
        self?.canCheckForUpdates = value
      }
  }
}

struct CheckForUpdatesCommand: View {
  @ObservedObject private var viewModel: CheckForUpdatesViewModel

  private let updater: SPUUpdater?

  init(updater: SPUUpdater? = AppUpdater.shared.updater) {
    self.updater = updater
    _viewModel = ObservedObject(wrappedValue: CheckForUpdatesViewModel(updater: updater))
  }

  var body: some View {
    if let updater {
      Button("Check for Updates...", action: updater.checkForUpdates)
        .disabled(!viewModel.canCheckForUpdates)
    }
  }
}
#else
@MainActor
final class AppUpdater {
  static let shared = AppUpdater()

  private init() {}
}

struct CheckForUpdatesCommand: View {
  var body: some View { EmptyView() }
}
#endif

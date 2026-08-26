import Combine
import Foundation
import MouseGestureCore

@MainActor
final class SettingsStore: ObservableObject {
    private static let defaultsKey = "gestureConfiguration"
    private let defaults: UserDefaults

    @Published var configuration: GestureConfiguration {
        didSet { persist() }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: Self.defaultsKey),
            let decoded = try? JSONDecoder().decode(GestureConfiguration.self, from: data)
        {
            configuration = decoded
        } else {
            configuration = GestureConfiguration()
        }
    }

    func action(for direction: GestureDirection) -> GestureAction {
        configuration.actions[direction] ?? GestureAction(kind: .none)
    }

    func setAction(_ action: GestureAction, for direction: GestureDirection) {
        configuration.actions[direction] = action
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(configuration) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

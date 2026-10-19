import Foundation
import Testing
@testable import MouseGestureCore

struct ConfigurationTests {
    @Test func legacyConfigurationGetsNewDefaults() throws {
        let legacy = #"{"enabled":false,"threshold":8,"actions":["up",{"kind":"copy"}]}"#
        let decoded = try JSONDecoder().decode(GestureConfiguration.self, from: Data(legacy.utf8))
        #expect(!decoded.enabled)
        #expect(decoded.threshold == 8)
        #expect(decoded.actions[.up] == GestureAction(kind: .copy))
        #expect(decoded.showsFeedback)
        #expect(decoded.toggleShortcut == GestureConfiguration.defaultToggleShortcut)
        #expect(decoded.excludedBundleIdentifiers.isEmpty)
    }

    @Test func newFieldsRoundTrip() throws {
        let shortcut = RecordedShortcut(keyCode: 3, modifierRawValue: 1 << 20)
        let original = GestureConfiguration(showsFeedback: false, toggleShortcut: shortcut,
                                            excludedBundleIdentifiers: ["com.example.Paint"])
        let data = try JSONEncoder().encode(original)
        #expect(try JSONDecoder().decode(GestureConfiguration.self, from: data) == original)
    }

    @Test func exclusionToggleKeepsOneEntryPerApplication() {
        var configuration = GestureConfiguration()
        #expect(!configuration.excludes(bundleIdentifier: "com.example.Paint"))
        #expect(!configuration.excludes(bundleIdentifier: nil))
        configuration.setExcluded(true, bundleIdentifier: "com.example.Paint")
        configuration.setExcluded(true, bundleIdentifier: "com.example.Paint")
        #expect(configuration.excludedBundleIdentifiers == ["com.example.Paint"])
        #expect(configuration.excludes(bundleIdentifier: "com.example.Paint"))
        configuration.setExcluded(false, bundleIdentifier: "com.example.Paint")
        #expect(configuration.excludedBundleIdentifiers.isEmpty)
    }
}

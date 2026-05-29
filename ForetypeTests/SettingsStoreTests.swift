import Testing
import Foundation
@testable import Foretype

@MainActor
struct SettingsStoreTests {
    /// A fresh, isolated in-memory UserDefaults suite for each test.
    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "test.foretype.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return (defaults, suiteName)
    }

    private let storageKey = "com.foretype.settings"

    @Test func startsFromDefaultsWhenEmpty() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        #expect(store.current == .default)
    }

    @Test func setFieldPersistsAndReDecodes() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.setEnabled(false)
        store.setBackend(.openAICompatible)
        store.setLengthPreset(.long)
        store.setGhostTextColorHex("#FF8800")

        #expect(store.current.isEnabled == false)
        #expect(store.current.backend == .openAICompatible)
        #expect(store.current.lengthPreset == .long)

        // Re-read through a brand new store backed by the same defaults: the
        // values must decode from the persisted JSON.
        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.current.isEnabled == false)
        #expect(reloaded.current.backend == .openAICompatible)
        #expect(reloaded.current.lengthPreset == .long)
        #expect(reloaded.current.ghostTextColorHex == "#FF8800")
    }

    @Test func openAIAndAppRulesRoundTrip() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.setOpenAI(OpenAISettings(baseURL: "http://example.com", model: "m1"))
        store.addAppRule(AppRule(bundleID: "com.acme.app", mode: .block))

        let reloaded = SettingsStore(defaults: defaults)
        #expect(reloaded.current.openAI.baseURL == "http://example.com")
        #expect(reloaded.current.openAI.model == "m1")
        #expect(reloaded.current.appRules == [AppRule(bundleID: "com.acme.app", mode: .block)])
    }

    @Test func addAppRuleReplacesSameBundle() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.addAppRule(AppRule(bundleID: "com.acme.app", mode: .block))
        store.addAppRule(AppRule(bundleID: "com.acme.app", mode: .allow))

        #expect(store.current.appRules == [AppRule(bundleID: "com.acme.app", mode: .allow)])
    }

    @Test func removeAppRule() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.addAppRule(AppRule(bundleID: "a", mode: .block))
        store.addAppRule(AppRule(bundleID: "b", mode: .block))
        store.removeAppRule(bundleID: "a")

        #expect(store.current.appRules == [AppRule(bundleID: "b", mode: .block)])
    }

    @Test func timingFieldsAreClampedOnWrite() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        store.setDebounceMilliseconds(99999)
        store.setFocusPollMilliseconds(1)

        #expect(store.current.debounceMilliseconds == 500)
        #expect(store.current.focusPollMilliseconds == 10)
    }

    @Test func changesStreamEmitsOnMutation() async {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        let store = SettingsStore(defaults: defaults)
        var iterator = store.changes.makeAsyncIterator()

        store.setEnabled(false)

        let emitted = await iterator.next()
        #expect(emitted?.isEnabled == false)
    }

    @Test func setAPIKeyDoesNotTouchUserDefaults() {
        let (defaults, name) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: name) }

        // No real Keychain access: inject a fake KeychainStore subclass-free by
        // verifying nothing about the API key reaches UserDefaults. We avoid
        // exercising the system Keychain (unavailable in CI), so we only check
        // that the suite's persistent domain never contains the secret.
        let store = SettingsStore(defaults: defaults, keychain: NoopKeychain())
        store.setAPIKey("super-secret-key-123")

        let domain = defaults.persistentDomain(forName: name) ?? [:]
        // The settings blob (if any) must not contain the API key string.
        if let data = domain[storageKey] as? Data {
            let json = String(data: data, encoding: .utf8) ?? ""
            #expect(!json.contains("super-secret-key-123"))
        }
        // And no key in the suite should carry the secret value.
        for (_, value) in domain {
            if let str = value as? String {
                #expect(str != "super-secret-key-123")
            }
        }
    }
}

/// A Keychain stand-in that holds the key in memory, so tests never touch the
/// system Keychain (which may be unavailable in CI).
private final class NoopKeychain: KeychainStore {
    private var stored: String?
    override func read() -> String? { stored }
    override func set(_ value: String?) { stored = value }
}

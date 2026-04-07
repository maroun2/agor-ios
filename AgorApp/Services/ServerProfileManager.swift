import Foundation

@Observable
final class ServerProfileManager {
    static let shared = ServerProfileManager()

    private static let storageKey = "agor.serverProfiles"
    private static let activeKey = "agor.activeServerId"

    var profiles: [ServerProfile] = []
    var activeProfileId: UUID?

    var activeProfile: ServerProfile? {
        profiles.first { $0.id == activeProfileId }
    }

    private init() {
        loadProfiles()
    }

    // MARK: - Persistence

    private func loadProfiles() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let decoded = try? JSONDecoder().decode([ServerProfile].self, from: data) {
            profiles = decoded
        }
        if let idString = UserDefaults.standard.string(forKey: Self.activeKey),
           let id = UUID(uuidString: idString) {
            activeProfileId = id
        }
    }

    private func saveProfiles() {
        if let data = try? JSONEncoder().encode(profiles) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }

    private func saveActiveId() {
        UserDefaults.standard.set(activeProfileId?.uuidString, forKey: Self.activeKey)
    }

    // MARK: - CRUD

    func addProfile(_ profile: ServerProfile) {
        var newProfile = profile
        if profiles.isEmpty {
            newProfile.isDefault = true
        }
        profiles.append(newProfile)
        saveProfiles()
    }

    func updateProfile(_ profile: ServerProfile) {
        if let idx = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[idx] = profile
            saveProfiles()
        }
    }

    func deleteProfile(_ id: UUID) {
        profiles.removeAll { $0.id == id }
        if activeProfileId == id {
            activeProfileId = profiles.first?.id
            saveActiveId()
        }
        // If we removed the default, make the first one default
        if !profiles.contains(where: { $0.isDefault }), !profiles.isEmpty {
            profiles[0].isDefault = true
        }
        saveProfiles()
    }

    func setActive(_ id: UUID) {
        activeProfileId = id
        saveActiveId()
    }

    func setDefault(_ id: UUID) {
        for i in profiles.indices {
            profiles[i].isDefault = (profiles[i].id == id)
        }
        saveProfiles()
    }

    // MARK: - Migration

    /// Called on first launch to create a profile from existing keychain URL
    func migrateFromKeychain(url: String, name: String = "Default") {
        guard profiles.isEmpty, !url.isEmpty else { return }
        let profile = ServerProfile(name: name, url: url, isDefault: true)
        profiles.append(profile)
        activeProfileId = profile.id
        saveProfiles()
        saveActiveId()
        AppLogger.shared.log("[ServerProfile] migrated existing URL as '\(name)' profile", level: .info, category: "Auth")
    }

    // MARK: - Per-Server Keychain Keys

    func keychainKey(for profileId: UUID, key: KeychainHelper.Key) -> String {
        "\(key.rawValue)_\(profileId.uuidString)"
    }

    func saveToken(_ token: String, key: KeychainHelper.Key, profileId: UUID) {
        let fullKey = keychainKey(for: profileId, key: key)
        KeychainHelper.saveRaw(token, for: fullKey)
    }

    func loadToken(key: KeychainHelper.Key, profileId: UUID) -> String? {
        let fullKey = keychainKey(for: profileId, key: key)
        return KeychainHelper.loadRaw(fullKey)
    }

    func deleteTokens(profileId: UUID) {
        for key in [KeychainHelper.Key.accessToken, .refreshToken] {
            let fullKey = keychainKey(for: profileId, key: key)
            KeychainHelper.deleteRaw(fullKey)
        }
    }
}

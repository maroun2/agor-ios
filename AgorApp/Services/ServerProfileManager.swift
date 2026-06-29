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
    func migrateFromKeychain(url: String, email: String = "", name: String = "Default") {
        guard profiles.isEmpty, !url.isEmpty else { return }
        let profile = ServerProfile(name: name, url: url, email: email, isDefault: true)
        profiles.append(profile)
        activeProfileId = profile.id
        if let token = KeychainHelper.load(.accessToken) {
            saveToken(token, key: .accessToken, profileId: profile.id)
        }
        if let refresh = KeychainHelper.load(.refreshToken) {
            saveToken(refresh, key: .refreshToken, profileId: profile.id)
        }
        if let userId = KeychainHelper.load(.userId) {
            saveToken(userId, key: .userId, profileId: profile.id)
        }
        if let userEmail = KeychainHelper.load(.userEmail) {
            saveToken(userEmail, key: .userEmail, profileId: profile.id)
        }
        saveProfiles()
        saveActiveId()
        AppLogger.shared.log("[ServerProfile] migrated existing URL as '\(name)' profile (email: \(email))", level: .info, category: "Auth")
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
        for key in KeychainHelper.Key.allCases {
            KeychainHelper.deleteRaw(keychainKey(for: profileId, key: key))
        }
    }

    /// Find a stored password for the given email across all profiles (shared credentials
    /// for the same account, so switching servers doesn't force a re-login).
    func sharedPassword(forEmail email: String?) -> String? {
        guard let email, !email.isEmpty else { return nil }
        for profile in profiles {
            let profileEmail = loadToken(key: .userEmail, profileId: profile.id) ?? profile.email
            guard profileEmail == email else { continue }
            if let pw = loadToken(key: .password, profileId: profile.id), !pw.isEmpty { return pw }
        }
        return nil
    }
}

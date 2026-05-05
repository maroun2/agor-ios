import SwiftUI

struct ConnectionSetupView: View {
    let appViewModel: AppViewModel

    @State private var profileName: String = ""
    @State private var daemonURL: String = ""
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var errorMessage: String?
    @State private var isConnecting = false

    private var profileManager: ServerProfileManager { .shared }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // Logo / Title
                    VStack(spacing: 8) {
                        Text("Agor")
                            .font(.system(size: 48, weight: .bold, design: .rounded))

                        Text("Connect to your Agor daemon")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.top, 40)

                    // Saved servers
                    if !profileManager.profiles.isEmpty {
                        savedServersSection
                    }

                    // Form
                    VStack(spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Server Name")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            TextField("e.g. Home, Work", text: $profileName)
                                .textFieldStyle(.roundedBorder)
                                .textInputAutocapitalization(.words)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Daemon URL")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            TextField("http://192.168.1.100:3030", text: $daemonURL)
                                .textFieldStyle(.roundedBorder)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Email")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            TextField("email@example.com", text: $email)
                                .textFieldStyle(.roundedBorder)
                                .keyboardType(.emailAddress)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .textContentType(.username)
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Password")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            SecureField("Password", text: $password)
                                .textFieldStyle(.roundedBorder)
                                .textContentType(.password)
                        }
                    }
                    .padding(.horizontal)

                    // Error
                    if let errorMessage {
                        Text(verbatim: errorMessage)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                    }

                    // Connect Button
                    Button {
                        connect()
                    } label: {
                        if isConnecting {
                            ProgressView()
                                .tint(.white)
                                .frame(maxWidth: .infinity)
                        } else {
                            Text("Connect")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(isConnecting || daemonURL.isEmpty || email.isEmpty || password.isEmpty)
                    .padding(.horizontal)

                    Spacer()
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .task {
                // Pre-fill from active profile or flat keychain
                if let profile = profileManager.activeProfile {
                    if daemonURL.isEmpty { daemonURL = profile.url }
                    if email.isEmpty { email = profile.email }
                    if profileName.isEmpty { profileName = profile.name }
                } else {
                    if daemonURL.isEmpty, let url = KeychainHelper.load(.daemonURL) { daemonURL = url }
                    if email.isEmpty, let savedEmail = KeychainHelper.load(.userEmail) { email = savedEmail }
                }
            }
        }
    }

    // MARK: - Saved Servers

    private var savedServersSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Saved Servers")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            ForEach(profileManager.profiles) { profile in
                Button {
                    daemonURL = profile.url
                    email = profile.email
                    profileName = profile.name
                    password = ""
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: profile.name)
                                .font(.subheadline.weight(.medium))
                            Text(verbatim: profile.url)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if !profile.email.isEmpty {
                                Text(verbatim: profile.email)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Spacer()
                        Image(systemName: "chevron.right")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal)
                    .padding(.vertical, 8)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
            }
        }
    }

    // MARK: - Connect

    private func connect() {
        isConnecting = true
        errorMessage = nil

        Task {
            do {
                try await appViewModel.loginToProfile(
                    url: daemonURL,
                    email: email,
                    password: password,
                    profileName: profileName
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            isConnecting = false
        }
    }
}

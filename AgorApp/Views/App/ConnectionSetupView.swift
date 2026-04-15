import SwiftUI

struct ConnectionSetupView: View {
    let authService: AuthService

    @State private var daemonURL: String = ""
    @State private var email: String = ""
    @State private var password: String = ""
    @State private var errorMessage: String?
    @State private var isConnecting = false

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

                    // Form
                    VStack(spacing: 16) {
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
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Password")
                                .font(.caption)
                                .foregroundStyle(.secondary)

                            SecureField("Password", text: $password)
                                .textFieldStyle(.roundedBorder)
                        }
                    }
                    .padding(.horizontal)

                    // Error
                    if let errorMessage {
                        Text(errorMessage)
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
            if daemonURL.isEmpty, let url = KeychainHelper.load(.daemonURL) { daemonURL = url }
            if email.isEmpty, let savedEmail = KeychainHelper.load(.userEmail) { email = savedEmail }
        }
        }
    }

    private func connect() {
        isConnecting = true
        errorMessage = nil

        Task {
            do {
                try await authService.login(
                    daemonURL: daemonURL,
                    email: email,
                    password: password
                )
            } catch {
                errorMessage = error.localizedDescription
            }
            isConnecting = false
        }
    }
}

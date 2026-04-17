import SwiftUI

struct ServerListView: View {
    let profileManager: ServerProfileManager
    let onSwitch: (ServerProfile) -> Void

    @State private var showAddServer = false
    @State private var editingProfile: ServerProfile?

    var body: some View {
        List {
            ForEach(profileManager.profiles) { profile in
                let isActive = profile.id == profileManager.activeProfileId

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(profile.name)
                                .font(.subheadline.weight(isActive ? .semibold : .regular))
                            if profile.isDefault {
                                Text("Default")
                                    .font(.caption2)
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 1)
                                    .background(.blue.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
                                    .foregroundStyle(.blue)
                            }
                        }
                        Text(profile.url)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        if !profile.email.isEmpty {
                            Text(profile.email)
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }

                    Spacer()

                    if isActive {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    if !isActive {
                        onSwitch(profile)
                    }
                }
                .contextMenu {
                    if !isActive {
                        Button {
                            onSwitch(profile)
                        } label: {
                            Label("Connect", systemImage: "link")
                        }
                    }

                    Button {
                        editingProfile = profile
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }

                    if !profile.isDefault {
                        Button {
                            profileManager.setDefault(profile.id)
                        } label: {
                            Label("Set as Default", systemImage: "star")
                        }
                    }

                    Divider()

                    if profileManager.profiles.count > 1 {
                        Button(role: .destructive) {
                            profileManager.deleteProfile(profile.id)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }

            Button {
                showAddServer = true
            } label: {
                Label("Add Server", systemImage: "plus")
            }
        }
        .navigationTitle("Servers")
        .sheet(isPresented: $showAddServer) {
            ServerEditView(profileManager: profileManager)
        }
        .sheet(item: $editingProfile) { profile in
            ServerEditView(profileManager: profileManager, existingProfile: profile)
        }
    }
}

struct ServerEditView: View {
    let profileManager: ServerProfileManager
    var existingProfile: ServerProfile?

    @Environment(\.dismiss) private var dismiss
    @State private var name: String = ""
    @State private var url: String = ""
    @State private var email: String = ""

    var isEditing: Bool { existingProfile != nil }

    var body: some View {
        NavigationStack {
            Form {
                Section("Server Details") {
                    TextField("Name (e.g. Home, Work)", text: $name)
                    TextField("URL (e.g. https://agor.example.com)", text: $url)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    TextField("Email", text: $email)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                }
            }
            .navigationTitle(isEditing ? "Edit Server" : "Add Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(isEditing ? "Save" : "Add") {
                        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
                        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !trimmedName.isEmpty, !trimmedURL.isEmpty else { return }

                        if var profile = existingProfile {
                            profile.name = trimmedName
                            profile.url = trimmedURL
                            profile.email = trimmedEmail
                            profileManager.updateProfile(profile)
                        } else {
                            let profile = ServerProfile(name: trimmedName, url: trimmedURL, email: trimmedEmail)
                            profileManager.addProfile(profile)
                        }
                        dismiss()
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                              url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear {
                if let profile = existingProfile {
                    name = profile.name
                    url = profile.url
                    email = profile.email
                }
            }
        }
    }
}

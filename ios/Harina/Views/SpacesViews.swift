// SPDX-License-Identifier: MPL-2.0
import HarinaKit
import SwiftUI

/// Switches the space the app shows (docs/design/people-and-spaces.md). Hidden with a single space.
struct SpacePicker: View {
    @EnvironmentObject private var sync: SyncService
    @AppStorage("space") private var space = ""

    var body: some View {
        if sync.spaces.count > 1 {
            Menu {
                ForEach(sync.spaces) { sp in
                    let local = Spaces.local(sp.id)
                    Button {
                        space = local
                    } label: {
                        if Spaces.valid(space) == local {
                            Label(Spaces.name(local), systemImage: "checkmark")
                        } else {
                            Text(verbatim: Spaces.name(local))
                        }
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: Spaces.valid(space).isEmpty ? "person.fill" : "person.2.fill")
                    Text(verbatim: Spaces.name(Spaces.valid(space)))
                    Image(systemName: "chevron.down").font(.caption2.weight(.bold))
                }
                .font(.subheadline.weight(.semibold))
            }
            .accessibilityLabel(Text("spaces.current"))
        }
    }
}

/// Personal and shared spaces: members, invitations, joining and leaving.
struct SpacesView: View {
    @EnvironmentObject private var sync: SyncService
    @AppStorage("space") private var space = ""
    @State private var myName = ""
    @State private var newSpace = ""
    @State private var joinCode = ""
    @State private var invite: (space: SpaceInfo, code: String)?
    @State private var confirmLeave: SpaceInfo?
    @State private var renaming: SpaceInfo?
    @State private var renameText = ""
    @State private var failed: LocalizedStringKey?
    @State private var working = false

    private var me: SpaceInfo.Member? { sync.spaces.first?.members.first(where: \.me) }

    var body: some View {
        Form {
            Section {
                TextField("spaces.myName", text: $myName)
                    .onSubmit { run { try await sync.setMyName(myName) } }
            } footer: {
                Text("spaces.myNameHint")
            }
            Section {
                ForEach(sync.spaces) { sp in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Image(systemName: sp.isPersonal ? "person.fill" : "person.2.fill").foregroundStyle(sp.isPersonal ? Color(hex: 0x8B5CF6) : Theme.earn)
                            Text(verbatim: Spaces.name(Spaces.local(sp.id))).font(.body.weight(.semibold))
                            Spacer()
                            if !sp.isPersonal {
                                Button("spaces.invite") { run { invite = (sp, try await sync.invite(to: sp.id)) } }
                                    .buttonStyle(.bordered)
                            }
                        }
                        Text(verbatim: sp.isPersonal ? L("spaces.personalHint") : members(sp)).font(.caption).foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        if !sp.isPersonal {
                            Button(sp.role == "owner" ? L("spaces.delete") : L("spaces.leave"), role: .destructive) { confirmLeave = sp }
                            if sp.role == "owner" {
                                Button(L("spaces.rename")) { renameText = sp.name ?? ""; renaming = sp }
                            }
                        }
                    }
                }
            } header: {
                Text("spaces.title")
            } footer: {
                Text("spaces.hint")
            }
            Section("spaces.createTitle") {
                TextField("spaces.newName", text: $newSpace)
                Button("spaces.create") {
                    let name = newSpace.trimmingCharacters(in: .whitespaces)
                    run {
                        space = try await sync.createSpace(name: name)
                        newSpace = ""
                    }
                }
                .disabled(newSpace.trimmingCharacters(in: .whitespaces).isEmpty || working)
            }
            Section("spaces.joinTitle") {
                TextField("spaces.joinCode", text: $joinCode).textInputAutocapitalization(.characters).autocorrectionDisabled()
                Button("spaces.join") {
                    run {
                        space = try await sync.join(code: joinCode)
                        joinCode = ""
                    }
                }
                .disabled(joinCode.count < 8 || working)
            }
            if let failed { Text(failed).foregroundStyle(.red) }
        }
        .navigationTitle("spaces.title")
        .onAppear { myName = me?.name ?? "" }
        .task { try? await sync.refreshSpaces() }
        .sheet(isPresented: Binding(get: { invite != nil }, set: { if !$0 { invite = nil } })) {
            if let invite { InviteSheet(space: invite.space, code: invite.code) }
        }
        .confirmationDialog(Text(verbatim: confirmLeave.map { $0.role == "owner" ? String(localized: "spaces.confirmDelete \($0.name ?? "")") : String(localized: "spaces.confirmLeave \($0.name ?? "")") } ?? ""),
                            isPresented: Binding(get: { confirmLeave != nil }, set: { if !$0 { confirmLeave = nil } }), titleVisibility: .visible) {
            if let sp = confirmLeave {
                Button(sp.role == "owner" ? L("spaces.delete") : L("spaces.leave"), role: .destructive) {
                    run { if sp.role == "owner" { try await sync.deleteSpace(sp.id) } else { try await sync.leave(sp.id) } }
                }
            }
        }
        .alert("spaces.rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("spaces.newName", text: $renameText)
            Button("spaces.save") { if let sp = renaming { run { try await sync.renameSpace(sp.id, name: renameText) } } }
            Button("app.cancel", role: .cancel) {}
        }
    }

    private func members(_ sp: SpaceInfo) -> String {
        sp.members.map { $0.me ? L("spaces.you") : ($0.name ?? L("spaces.someone")) }.joined(separator: ", ")
    }

    private func run(_ work: @escaping () async throws -> Void) {
        working = true
        failed = nil
        Task {
            do { try await work() } catch SyncError.server(400) { failed = "spaces.failedCode" } catch { failed = "spaces.failed" }
            working = false
        }
    }
}

/// The invitation: a code to type and a link to send (it opens the web for people without the app).
struct InviteSheet: View {
    let space: SpaceInfo
    let code: String
    @Environment(\.dismiss) private var dismiss

    private var link: URL? {
        AppSettings.serverURL.flatMap { URL(string: "\($0.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")))/#/unirme/\(code)") }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Image(systemName: "person.2.fill").font(.system(size: 40)).foregroundStyle(Theme.earn)
                Text("spaces.inviteTitle \(space.name ?? "")").font(.title2.weight(.heavy)).multilineTextAlignment(.center)
                Text(verbatim: code).font(.system(.largeTitle, design: .monospaced).weight(.bold)).textSelection(.enabled)
                Text("spaces.inviteHelp").font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if let link {
                    ShareLink(item: link, message: Text("spaces.inviteMessage \(space.name ?? "") \(code)")) {
                        Label("spaces.share", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(BrandButtonStyle())
                }
                Spacer()
            }
            .padding(24)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("app.done") { dismiss() } } }
        }
    }
}

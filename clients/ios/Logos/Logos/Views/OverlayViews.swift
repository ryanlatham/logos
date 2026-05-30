import SwiftUI

/// The project switcher dropdown, extracted from `ContentView` (WS1 PR4b). Owns the switcher-only
/// `@State` whose reads/writes are entirely contained in the switcher UI (`switcherSearch`,
/// `isCreatingProject`, `newProjectTitle`, `createSource`) and its own `@FocusState` for the
/// search / new-project-title fields. The visibility flag (`showProjectSwitcher`) stays in
/// ContentView and is handed in as `isPresented`; `justCreatedProject` is cross-cutting (read by
/// ContentView's nav-bar status chip) so it stays there and arrives as a binding via the
/// `onProjectCreated` callback, which also runs the delayed-reset Task that must outlive this
/// overlay's dismissal.
struct ProjectSwitcherOverlay: View {
    @Environment(LogosClient.self) private var client

    @Binding var isPresented: Bool
    let onProjectCreated: (String) -> Void

    @State private var switcherSearch = ""
    @State private var isCreatingProject = false
    @State private var newProjectTitle = ""
    @State private var createSource: ProjectCreateSource = .blank

    @FocusState private var focusedField: FocusedField?

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .top) {
                Color.black.opacity(0.36)
                    .ignoresSafeArea()
                    .onTapGesture {
                        closeProjectSwitcher()
                    }

                switcherDropdown(screenHeight: proxy.size.height)
                    .padding(.top, 66)
                    .padding(.horizontal, 12)
            }
        }
    }

    private func switcherDropdown(screenHeight: CGFloat) -> some View {
        let dropdownMaxHeight = ProjectSwitcherLayout.dropdownMaxHeight(for: screenHeight)
        let projectListMaxHeight = ProjectSwitcherLayout.projectListMaxHeight(
            for: screenHeight,
            projectCount: displayedProjects.count,
            isCreatingProject: isCreatingProject
        )

        return VStack(alignment: .leading, spacing: 12) {
            if isCreatingProject == false {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.logosLabel3)
                    TextField("Search projects", text: $switcherSearch)
                        .focused($focusedField, equals: .switcherSearch)
                        .font(.system(size: 15))
                        .foregroundStyle(Color.logosLabel)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Text("⌘K")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.logosLabel3)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 4)
                        .background(Color.logosBG3, in: RoundedRectangle(cornerRadius: 7))
                }
                .padding(12)
                .background(Color.logosBG2.opacity(0.78), in: RoundedRectangle(cornerRadius: 14))
            }

            ScrollView(.vertical, showsIndicators: true) {
                LazyVStack(spacing: ProjectSwitcherLayout.projectRowSpacing) {
                    ForEach(displayedProjects) { project in
                        Button {
                            Task { @MainActor in await client.switchProject(project.projectKey) }
                            closeProjectSwitcher()
                        } label: {
                            ProjectRowView(
                                project: project,
                                isSelected: project.projectKey == client.activeProjectKey
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(client.connectionState != .connected && project.projectKey != client.activeProjectKey)
                    }
                }
                .padding(.vertical, 1)
            }
            .frame(maxHeight: projectListMaxHeight, alignment: .top)
            .scrollBounceBehavior(.basedOnSize)
            .accessibilityIdentifier("projectSwitcherList")

            Divider().overlay(Color.logosHairline)

            if isCreatingProject {
                createProjectCard
            } else {
                Button {
                    withAnimation(.easeOut(duration: 0.18)) {
                        isCreatingProject = true
                        switcherSearch = ""
                    }
                    focusedField = .newProjectTitle
                } label: {
                    Label("New project", systemImage: "plus")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.logosAmber)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: dropdownMaxHeight, alignment: .top)
        .background(Color.logosGlass)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.logosHairline, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.42), radius: 24, x: 0, y: 14)
    }

    private var createProjectCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Project title", text: $newProjectTitle)
                .accessibilityIdentifier("newProjectTitleField")
                .focused($focusedField, equals: .newProjectTitle)
                .font(.system(size: 15, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.logosLabel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textContentType(.none)
                .submitLabel(.done)
                .onSubmit { createProjectFromTitleField() }
                .padding(.horizontal, 12)
                .frame(height: 42)
                .background(Color.black.opacity(0.34), in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.logosAmber, lineWidth: 1))

            VStack(alignment: .leading, spacing: 8) {
                Text("Start from")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.logosLabel3)
                    .textCase(.uppercase)
                HStack(spacing: 6) {
                    ForEach(ProjectCreateSource.allCases) { source in
                        Button {
                            createSource = source
                        } label: {
                            Text(source.title)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(createSource == source ? Color.logosAmberOn : Color.logosLabel2)
                                .padding(.horizontal, 9)
                                .padding(.vertical, 7)
                                .background(createSource == source ? Color.logosAmber : Color.logosBG2.opacity(0.8), in: Capsule())
                                .overlay(Capsule().stroke(createSource == source ? Color.clear : Color.logosHairline, lineWidth: 0.5))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }

            HStack(spacing: 10) {
                Button("Cancel") {
                    withAnimation(.easeOut(duration: 0.18)) {
                        isCreatingProject = false
                        newProjectTitle = ""
                    }
                }
                .buttonStyle(SecondaryPillButtonStyle())

                Button("Create & open") {
                    createProjectFromTitleField()
                }
                .buttonStyle(AmberPillButtonStyle())
                .accessibilityIdentifier("createProjectButton")
                .disabled(client.connectionState != .connected || newProjectTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
        .background(Color.logosBG1.opacity(0.86), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.logosHairline, lineWidth: 0.5))
    }

    private var allProjects: [LogosProject] {
        if client.projects.isEmpty {
            return [LogosProject(projectKey: client.activeProjectKey, title: client.activeProjectKey, currentSessionID: nil, lastPreview: "Current session")]
        }
        if client.projects.contains(where: { $0.projectKey == client.activeProjectKey }) {
            return client.projects
        }
        return [LogosProject(projectKey: client.activeProjectKey, title: client.activeProjectKey, currentSessionID: nil, lastPreview: "Current session")] + client.projects
    }

    private var displayedProjects: [LogosProject] {
        let base = isCreatingProject ? Array(allProjects.prefix(3)) : allProjects
        let query = switcherSearch.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard query.isEmpty == false, isCreatingProject == false else { return base }
        return base.filter { project in
            project.title.lowercased().contains(query)
                || project.projectKey.lowercased().contains(query)
                || (project.lastPreview?.lowercased().contains(query) ?? false)
        }
    }

    private func createProjectFromTitleField() {
        let pendingTitle = newProjectTitle
        Task { @MainActor in
            if await client.createProject(title: pendingTitle) {
                newProjectTitle = ""
                isCreatingProject = false
                closeProjectSwitcher()
                // ContentView owns the `justCreatedProject` status-chip flag and its delayed reset,
                // which must outlive this overlay's dismissal.
                onProjectCreated(pendingTitle)
            }
        }
    }

    private func closeProjectSwitcher() {
        withAnimation(.timingCurve(0.2, 0.85, 0.25, 1, duration: 0.24)) {
            isPresented = false
            isCreatingProject = false
            switcherSearch = ""
        }
        focusedField = nil
    }
}

/// The "Attach to message" bottom sheet, extracted from `ContentView` (WS1 PR4b). It carries no
/// own state: the backdrop tap toggles the `isPresented` flag that stays in ContentView, and the
/// "Commands" row invokes `onSelectCommands` so ContentView keeps ownership of the composer
/// mutations (`composerMode`/`draft`/`slashCommandDismissedDraft`/`focusedField`).
struct AttachSheetOverlay: View {
    @Binding var isPresented: Bool
    let onSelectCommands: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Color.black.opacity(0.30)
                .ignoresSafeArea()
                .onTapGesture { isPresented = false }

            VStack(alignment: .leading, spacing: 16) {
                SectionHead(title: "Attach to message")
                VStack(spacing: 0) {
                    AttachRow(icon: "photo.on.rectangle", title: "Photo Library", detail: "Stubbed until attachments ship")
                    AttachRow(icon: "camera", title: "Take Photo", detail: "Stubbed until camera capture ships")
                    AttachRow(icon: "doc", title: "Files", detail: "Stubbed until file upload ships")
                    Button {
                        onSelectCommands()
                    } label: {
                        AttachRow(icon: "terminal", title: "Commands", detail: "Browse Hermes slash commands")
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("commandsAttachRow")
                    AttachRow(icon: "curlybraces", title: "Paste code", detail: "Stubbed until rich snippets ship", isLast: true)
                }
                .background(Color.logosBG2, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18).stroke(Color.logosHairline, lineWidth: 0.5))
            }
            .padding(14)
            .background(Color.logosGlass)
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22).stroke(Color.logosHairline, lineWidth: 0.5))
            .padding(.horizontal, 12)
            .padding(.bottom, 106)
            .shadow(color: .black.opacity(0.45), radius: 24, x: 0, y: 12)
        }
    }
}

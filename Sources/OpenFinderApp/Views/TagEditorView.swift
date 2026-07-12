import OpenFinderCore
import SwiftUI

struct TagEditorView: View {
    @ObservedObject var context: TagEditorContext
    let onApply: (FileTagChangeSet) async -> Void
    let onRetry: () async -> Void
    let onManage: (FileTagCatalogMutation) async -> Void
    let onDismiss: () -> Void

    @State private var assignment = TagEditorAssignmentState()
    @State private var showingManagement = false
    @FocusState private var searchIsFocused: Bool

    var body: some View {
        NavigationStack {
            if showingManagement {
                TagCatalogManagementView(
                    context: context,
                    onMutation: performCatalogMutation,
                    onSelectCreated: { assignment.selectCreatedTag($0) },
                    onDone: { showingManagement = false }
                )
            } else {
                assignmentView
            }
        }
        .frame(minWidth: 440, idealWidth: 480, minHeight: 430, idealHeight: 520)
        .interactiveDismissDisabled(context.operationState != .idle)
    }

    private var assignmentView: some View {
        VStack(spacing: 0) {
            header
            Divider()
            tagList
            Divider()
            statusAndActions
        }
        .navigationTitle("标签")
        .searchable(text: $assignment.searchText, placement: .toolbar, prompt: "搜索或创建标签")
        .focused($searchIsFocused)
        .onAppear { searchIsFocused = true }
        .onExitCommand {
            if context.operationState == .idle { onDismiss() }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text("为所选项目分配标签")
                    .font(.headline)
                Text("已选 \(context.selectedItems.count) 项")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !TagEditorPresentation.manageableScopes(in: context.catalog).isEmpty {
                Button("管理…") { showingManagement = true }
                    .disabled(!context.canManageCatalog)
                    .accessibilityHint("打开标签目录管理页面")
            }
        }
        .padding(16)
    }

    private var tagList: some View {
        List {
            ForEach(assignmentSections, id: \.scope.id) { section in
                Section(section.scope.displayName) {
                    if section.tags.isEmpty {
                        Text("此范围暂无标签")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(section.tags, id: \.self) { tag in
                            tagRow(tag, scope: section.scope)
                        }
                    }
                }
            }

            let creationScopes = TagEditorPresentation.creationScopes(
                in: context.catalog,
                searchText: assignment.searchText,
                pendingAdditions: assignment.pendingChanges.additions
            )
            if !creationScopes.isEmpty {
                Section("创建") {
                    ForEach(creationScopes) { scope in
                        Button {
                            Task { await createTag(named: assignment.searchText, in: scope) }
                        } label: {
                            Label("在“\(scope.displayName)”中创建“\(trimmedSearchText)”", systemImage: "plus")
                        }
                        .disabled(context.operationState != .idle || context.isReadOnly)
                        .accessibilityHint(scope.kind == .local ? "创建并分配 Finder 标签" : "创建服务端标签后分配")
                    }
                }
            }
        }
        .listStyle(.inset)
        .overlay {
            if context.operationState == .loadingCatalog {
                ProgressView("正在加载标签…")
                    .padding(16)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            } else if assignmentSections.isEmpty,
                      creationScopesAreEmpty
            {
                ContentUnavailableView.search(text: assignment.searchText)
            }
        }
    }

    private func tagRow(_ tag: FileTag, scope: FileTagScope) -> some View {
        let baseState = context.selectionState(for: tag)
        let state = assignment.effectiveSelectionState(for: tag, baseState: baseState)
        return Button {
            assignment.toggle(tag, baseState: baseState)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: selectionSymbol(for: state))
                    .foregroundStyle(state == .empty ? Color.secondary : Color.accentColor)
                    .frame(width: 18)
                TagColorMarker(color: tag.color)
                Text(tag.name)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Spacer()
                if state == .mixed {
                    Text("部分")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!context.canAssociateTags)
        .accessibilityLabel("\(scope.displayName)，\(tag.name)，\(accessibilityColorName(tag.color))")
        .accessibilityValue(accessibilitySelectionName(state))
        .accessibilityHint("切换此标签在所选项目上的分配状态")
    }

    private var statusAndActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let message = context.errorMessage {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .accessibilityLabel("标签操作错误：\(message)")
            } else if let result = context.applyResult, result.hasFailures {
                Text("部分项目未能更新。已成功更新 \(result.appliedItemIDs.count) 项。")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            HStack {
                if context.canRetryCatalog {
                    Button("重试") { Task { await onRetry() } }
                        .accessibilityHint("重新加载标签目录")
                }
                if context.operationState != .idle {
                    ProgressView()
                        .controlSize(.small)
                    Text(operationLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消", role: .cancel) { onDismiss() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(context.operationState != .idle)
                Button("应用") { Task { await apply() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        assignment.pendingChanges.isEmpty
                            || !context.canAssociateTags
                            || context.operationState != .idle
                    )
            }
        }
        .padding(16)
    }

    private var trimmedSearchText: String {
        assignment.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var creationScopesAreEmpty: Bool {
        TagEditorPresentation.creationScopes(
            in: context.catalog,
            searchText: assignment.searchText,
            pendingAdditions: assignment.pendingChanges.additions
        ).isEmpty
    }

    private var assignmentSections: [TagEditorScopeSection] {
        TagEditorPresentation.sections(
            in: context.catalog,
            searchText: assignment.searchText,
            pendingAdditions: assignment.pendingChanges.additions
        )
    }

    private var operationLabel: String {
        switch context.operationState {
        case .idle: ""
        case .loadingCatalog: "正在加载…"
        case .applyingChanges: "正在应用…"
        case .mutatingCatalog: "正在保存目录…"
        }
    }

    private func apply() async {
        await onApply(assignment.pendingChanges)
        guard context.errorMessage == nil else { return }
        assignment.clear()
        onDismiss()
    }

    private func createTag(named rawName: String, in scope: FileTagScope) async {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if scope.kind == .local {
            assignment.selectCreatedTag(.local(name: name))
            assignment.searchText = ""
            return
        }

        let existingTags = Set(context.catalog.tags)
        await onManage(.createTag(name: name, groupID: nil))
        guard context.errorMessage == nil,
              let created = TagEditorPresentation.newlyCreatedTag(
                  in: context.catalog,
                  previously: existingTags,
                  scopeID: scope.id,
                  name: name
              )
        else {
            return
        }
        assignment.selectCreatedTag(created)
        assignment.searchText = ""
    }

    private func performCatalogMutation(_ mutation: FileTagCatalogMutation) async -> FileTag? {
        let existingTags = Set(context.catalog.tags)
        let deletedTag: FileTag?
        if case .deleteTag(let id) = mutation {
            deletedTag = context.catalog.tags.first {
                $0.scopeID == context.commonEditableScope.id && $0.id == id
            }
        } else {
            deletedTag = nil
        }
        await onManage(mutation)
        guard context.errorMessage == nil else { return nil }
        if let deletedTag {
            assignment.reconcileCatalogDeletion(of: deletedTag)
        }
        if case .createTag(let name, _) = mutation {
            return TagEditorPresentation.newlyCreatedTag(
                in: context.catalog,
                previously: existingTags,
                scopeID: context.commonEditableScope.id,
                name: name
            )
        }
        return nil
    }

    private func selectionSymbol(for state: TagSelectionState) -> String {
        switch state {
        case .empty: "circle"
        case .mixed: "minus.circle.fill"
        case .checked: "checkmark.circle.fill"
        }
    }

    private func accessibilitySelectionName(_ state: TagSelectionState) -> String {
        switch state {
        case .empty: "未选择"
        case .mixed: "部分项目已选择"
        case .checked: "全部项目已选择"
        }
    }
}

struct TagCatalogManagementView: View {
    @ObservedObject var context: TagEditorContext
    let onMutation: (FileTagCatalogMutation) async -> FileTag?
    let onSelectCreated: (FileTag) -> Void
    let onDone: () -> Void

    @State private var state: TagCatalogManagementState
    @State private var selectedTagID: String?
    @State private var selectedColor: FileTagColor = .none
    @State private var selectedGroupID = ""
    @State private var tagPendingDeletion: FileTag?

    init(
        context: TagEditorContext,
        onMutation: @escaping (FileTagCatalogMutation) async -> FileTag?,
        onSelectCreated: @escaping (FileTag) -> Void,
        onDone: @escaping () -> Void
    ) {
        self.context = context
        self.onMutation = onMutation
        self.onSelectCreated = onSelectCreated
        self.onDone = onDone
        _state = State(initialValue: .init(
            scopeID: TagEditorPresentation.manageableScopes(in: context.catalog).first?.id
                ?? context.commonEditableScope.id
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            managementHeader
            Divider()
            HSplitView {
                tagSidebar
                    .frame(minWidth: 165, idealWidth: 190)
                editor
                    .frame(minWidth: 245)
            }
            .disabled(!context.canManageCatalog)
            Divider()
            HStack {
                if context.operationState != .idle {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在保存…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let error = context.errorMessage {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
                Spacer()
                Button("完成") { onDone() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(context.operationState != .idle)
            }
            .padding(12)
        }
        .navigationTitle("管理标签")
        .alert("删除团队公共标签？", isPresented: Binding(
            get: { tagPendingDeletion.map { scopeKind($0.scopeID) } == .team },
            set: { if !$0 { tagPendingDeletion = nil } }
        )) {
            Button("删除", role: .destructive) { performConfirmedDeletion() }
                .disabled(!context.canManageCatalog)
            Button("取消", role: .cancel) { tagPendingDeletion = nil }
        } message: {
            Text("删除团队公共标签会移除该团队中此标签的所有文件关联。此操作无法撤销。")
        }
        .alert("删除标签？", isPresented: Binding(
            get: { tagPendingDeletion != nil && tagPendingDeletion.map { scopeKind($0.scopeID) } != .team },
            set: { if !$0 { tagPendingDeletion = nil } }
        )) {
            Button("删除", role: .destructive) { performConfirmedDeletion() }
                .disabled(!context.canManageCatalog)
            Button("取消", role: .cancel) { tagPendingDeletion = nil }
        } message: {
            Text("此操作无法撤销。")
        }
    }

    private var managementHeader: some View {
        HStack {
            Button { onDone() } label: {
                Label("返回分配", systemImage: "chevron.left")
            }
            Spacer()
            Picker("范围", selection: $state.scopeID) {
                ForEach(manageableScopes) { scope in
                    Text(scope.displayName).tag(scope.id)
                }
            }
            .frame(maxWidth: 240)
            .disabled(!context.canManageCatalog)
            .onChange(of: state.scopeID) { _, _ in beginCreate() }
        }
        .padding(12)
    }

    private var tagSidebar: some View {
        VStack(spacing: 8) {
            List(tagsInSelectedScope, id: \.self, selection: $selectedTagID) { tag in
                HStack(spacing: 8) {
                    TagColorMarker(color: tag.color)
                    Text(tag.name)
                        .lineLimit(1)
                }
                .tag(tag.id)
                .accessibilityLabel("\(tag.name)，\(accessibilityColorName(tag.color))")
            }
            .onChange(of: selectedTagID) { _, id in
                guard let tag = tagsInSelectedScope.first(where: { $0.id == id }) else { return }
                select(tag)
            }
            if selectedScope?.capabilities.canCreate == true {
                Button { beginCreate() } label: {
                    Label("新建标签", systemImage: "plus")
                }
                .disabled(context.operationState != .idle)
            }
        }
        .padding(8)
    }

    private var editor: some View {
        Form {
            TextField("名称", text: $state.name)
                .accessibilityLabel("标签名称")

            if selectedScope?.capabilities.canUpdateStyle == true, selectedTag != nil {
                Picker("颜色", selection: $selectedColor) {
                    ForEach(FileTagColor.allCases, id: \.self) { color in
                        Text(accessibilityColorName(color)).tag(color)
                    }
                }
                Button("更新颜色") {
                    guard let selectedTag else { return }
                    Task { _ = await onMutation(.updateTagStyle(id: selectedTag.id, color: selectedColor)) }
                }
                .disabled(context.operationState != .idle || selectedColor == selectedTag?.color)
            }

            if selectedScope?.kind == .team,
               selectedScope?.capabilities.canOrganizeGroups == true,
               selectedTag != nil
            {
                Picker("分组", selection: $selectedGroupID) {
                    Text("无分组").tag("")
                    ForEach(groupsInSelectedScope) { group in
                        Text(group.name).tag(group.id)
                    }
                }
                Button("移动到所选分组") {
                    guard let selectedTag else { return }
                    Task {
                        _ = await onMutation(.moveTag(
                            id: selectedTag.id,
                            groupID: selectedGroupID.isEmpty ? nil : selectedGroupID
                        ))
                    }
                }
                .disabled(context.operationState != .idle || selectedGroupID == (selectedTag?.groupID ?? ""))
            }

            HStack {
                Button(state.mode.isCreate ? "创建" : "保存名称") {
                    Task { await savePrimaryMutation() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(primaryMutation == nil || context.operationState != .idle || !primaryCapabilityAllowsMutation)

                Spacer()

                if let selectedTag, selectedScope?.capabilities.canDelete == true {
                    Button("删除", role: .destructive) { tagPendingDeletion = selectedTag }
                        .disabled(context.operationState != .idle)
                }
            }
        }
        .formStyle(.grouped)
        .padding(8)
    }

    private var manageableScopes: [FileTagScope] {
        TagEditorPresentation.manageableScopes(in: context.catalog)
    }

    private var selectedScope: FileTagScope? {
        manageableScopes.first { $0.id == state.scopeID }
    }

    private var tagsInSelectedScope: [FileTag] {
        context.catalog.tags.filter { $0.scopeID == state.scopeID }
    }

    private var groupsInSelectedScope: [FileTagGroup] {
        context.catalog.groups.filter { $0.scopeID == state.scopeID }
    }

    private var selectedTag: FileTag? {
        guard let selectedTagID else { return nil }
        return tagsInSelectedScope.first { $0.id == selectedTagID }
    }

    private var primaryMutation: FileTagCatalogMutation? {
        guard var mutation = state.mutation else { return nil }
        if case .createTag(let name, _) = mutation,
           selectedScope?.kind == .team
        {
            mutation = .createTag(name: name, groupID: selectedGroupID.isEmpty ? nil : selectedGroupID)
        }
        return mutation
    }

    private var primaryCapabilityAllowsMutation: Bool {
        guard let selectedScope else { return false }
        return state.mode.isCreate ? selectedScope.capabilities.canCreate : selectedScope.capabilities.canRename
    }

    private func beginCreate() {
        guard let selectedScope else { return }
        state.beginCreate(in: selectedScope)
        selectedTagID = nil
        selectedColor = .none
        selectedGroupID = ""
    }

    private func select(_ tag: FileTag) {
        state.beginRename(tag: tag)
        selectedColor = tag.color
        selectedGroupID = tag.groupID ?? ""
    }

    private func savePrimaryMutation() async {
        guard let mutation = primaryMutation else { return }
        let created = await onMutation(mutation)
        if let created {
            onSelectCreated(created)
            onDone()
        }
    }

    private func performConfirmedDeletion() {
        guard let tag = tagPendingDeletion else { return }
        tagPendingDeletion = nil
        Task {
            _ = await onMutation(.deleteTag(id: tag.id))
            if context.errorMessage == nil { beginCreate() }
        }
    }

    private func scopeKind(_ scopeID: String) -> FileTagScopeKind? {
        context.catalog.scopes.first { $0.id == scopeID }?.kind
    }
}

private struct TagColorMarker: View {
    let color: FileTagColor

    var body: some View {
        Circle()
            .fill(swiftUIColor(color))
            .frame(width: 9, height: 9)
            .overlay(Circle().stroke(.separator, lineWidth: color == .none ? 1 : 0))
            .accessibilityHidden(true)
    }
}

private extension TagCatalogManagementState.Mode {
    var isCreate: Bool {
        if case .create = self { return true }
        return false
    }
}

private func swiftUIColor(_ color: FileTagColor) -> Color {
    switch color {
    case .none: .secondary
    case .red: .red
    case .orange: .orange
    case .yellow: .yellow
    case .green: .green
    case .blue: .blue
    case .purple: .purple
    case .gray: .gray
    }
}

private func accessibilityColorName(_ color: FileTagColor) -> String {
    switch color {
    case .none: "无颜色"
    case .red: "红色"
    case .orange: "橙色"
    case .yellow: "黄色"
    case .green: "绿色"
    case .blue: "蓝色"
    case .purple: "紫色"
    case .gray: "灰色"
    }
}

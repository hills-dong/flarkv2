import SwiftUI

@main
struct FlarkApp: App {
    @State private var model = AppModel()
    /// App-scope flight host so the topic list's reaction bars also
    /// have a place to register their chip + tail anchors. The detail
    /// page overrides this with its own scoped instance (so the
    /// detail-only easter-egg overlay doesn't share state with the
    /// list); the list page reads only via `\.optionalEmojiFlightHost`.
    @State private var listFlightHost = EmojiFlightHost()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(\.optionalEmojiFlightHost, listFlightHost)
                .task { model.bootstrap() }
                .tint(.accentColor)
        }
        .onChange(of: scenePhase) { _, phase in
            // Drain pending writes + persist projection cache before suspend.
            // With manual-only pull, this is the last guaranteed chance to
            // push any locally-staged events to WebDAV.
            if phase != .active { model.persistOnBackground() }
        }
        #if os(macOS)
        .defaultSize(width: 1000, height: 760)
        #endif
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        stageContent
            .onOpenURL { model.handleInviteURL($0) }
            .sheet(item: $model.pendingInvite) { invite in
                InviteConfirmView(payload: invite)
            }
            .alert("邀请链接无效",
                   isPresented: Binding(get: { model.inviteError != nil },
                                         set: { if !$0 { model.clearInviteError() } })) {
                Button("好的", role: .cancel) { model.clearInviteError() }
            } message: {
                Text(model.inviteError ?? "")
            }
    }

    @ViewBuilder private var stageContent: some View {
        switch model.stage {
        case .loading:
            ProgressView().controlSize(.large)
        case .onboarding:
            OnboardingView()
        case .accountPicker:
            AccountPickerView()
        case .noSpace:
            SpaceSetupView()
        case .ready:
            TopicShell()
        }
    }
}

/// Adaptive shell: a split view on iPad/Mac (list ‖ detail); on iPhone it
/// automatically collapses into a push-navigation stack.
struct TopicShell: View {
    @Environment(AppModel.self) private var model
    @State private var selection: String?

    var body: some View {
        NavigationSplitView {
            TopicListView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 320, ideal: 380)
        } detail: {
            NavigationStack {
                if let id = selection, model.projection.topics[id] != nil {
                    TopicDetailView(topicID: id)
                } else {
                    ContentUnavailableView("选择一个话题", systemImage: "bubble.left.and.bubble.right")
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
    }
}

import SwiftUI

@main
struct FlarkApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
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

import LinenKit
import SwiftUI

@main
struct LinenApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var phase

    init() {
        Tok.registerFaces()
        Tok.styleNativeBars()
        _model = State(initialValue: AppModel.standard())
    }

    var body: some Scene {
        WindowGroup {
            Root()
                .environment(model)
                .task { await model.start() }
                .onOpenURL { model.handle($0) }
                .onChange(of: phase) { _, p in
                    if p == .background { model.enteredBackground() }
                    if p == .active { Task { await model.refresh() } }
                }
        }
    }
}

/// Paper or Night from the appearance setting (IOS-5): following the system, or fixed.
struct Root: View {
    @Environment(\.colorScheme) private var scheme
    @AppStorage("appearance") private var appearance = "system"

    var body: some View {
        let night = appearance == "night" || (appearance == "system" && scheme == .dark)
        let palette: Palette = night ? .night : .paper
        LibraryScreen()
            .environment(\.palette, palette)
            .tint(palette.head)
            .preferredColorScheme(appearance == "paper" ? .light : appearance == "night" ? .dark : nil)
    }
}

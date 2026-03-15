//
//  nexawalApp.swift
//  nexawal
//
//  Created by steve on 12/1/25.
//

import SwiftUI
import UIKit

@main
struct nexawalApp: App {
    @Environment(\.scenePhase) private var scenePhase

    // Single wallet instance for the app lifecycle so we can snapshot on background.
    @StateObject private var viewModel = WalletViewModel()

    // Debounce snapshots so we don't export twice when .inactive immediately transitions to .background.
    @State private var lastSnapshotAt: Date = .distantPast
    private let snapshotDebounceSeconds: TimeInterval = 3.0

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
                    viewModel.markNeedsRefreshRetryIfInitialSyncInterrupted()
                }
                .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                    viewModel.resumeOnDidBecomeActive()
                }
        }
        .onChange(of: scenePhase) {
            if scenePhase == .active {
                viewModel.resumeOnForeground()
                return
            }

            // Snapshot on either inactive or background, then resume on foreground.
            // We don't attempt to keep scanning in background; this is best-effort persistence only.
            guard scenePhase == .inactive || scenePhase == .background else { return }

            let now = Date()
            guard now.timeIntervalSince(lastSnapshotAt) >= snapshotDebounceSeconds else { return }
            lastSnapshotAt = now

            // Best-effort: iOS gives a short window to finish work when transitioning away.
            // Use it to snapshot wallet state for fast resume (cache export).
            let taskID = UIApplication.shared.beginBackgroundTask(withName: "wallet_snapshot") {}
            viewModel.snapshotForBackground()
            UIApplication.shared.endBackgroundTask(taskID)
        }
    }
}

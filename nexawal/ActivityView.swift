import SwiftUI
import UIKit

/// A SwiftUI wrapper around `UIActivityViewController` for sharing content.
///
/// Usage:
/// ```swift
/// ActivityView(activityItems: [moneroURI])
/// ```
///
/// You can optionally provide a list of excluded activity types or a completion handler.
struct ActivityView: UIViewControllerRepresentable {
    typealias CompletionHandler = UIActivityViewController.CompletionWithItemsHandler

    let activityItems: [Any]
    var applicationActivities: [UIActivity]? = nil
    var excludedActivityTypes: [UIActivity.ActivityType]? = nil
    var completion: CompletionHandler? = nil

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: activityItems,
            applicationActivities: applicationActivities
        )
        controller.excludedActivityTypes = excludedActivityTypes
        controller.completionWithItemsHandler = completion
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // No state to update; UIActivityViewController is presented once.
    }
}

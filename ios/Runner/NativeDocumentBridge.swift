import Flutter
import UIKit

final class NativeDocumentBridge: NSObject, ConduitBridge, NativeDocumentHostApi, UIDocumentInteractionControllerDelegate {
    static let shared = NativeDocumentBridge()
    private var host: ConduitBridgeHost?
    private weak var previewPresenter: UIViewController?
    private var document: UIDocumentInteractionController?

    func attach(to host: ConduitBridgeHost) {
        self.host = host
        NativeDocumentHostApiSetup.setUp(binaryMessenger: host.messenger, api: self)
    }

    func documentInteractionControllerViewControllerForPreview(
        _ controller: UIDocumentInteractionController
    ) -> UIViewController {
        previewPresenter ?? UIViewController()
    }

    func openFile(path: String, mimeType: String) throws -> Bool {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("open-with").resolvingSymlinksInPath()
        guard url.path.hasPrefix(root.path + "/"),
              FileManager.default.fileExists(atPath: url.path),
              var presenter = host?.presentingViewController else { return false }
        while let presented = presenter.presentedViewController {
            presenter = presented
        }
        let controller = UIDocumentInteractionController(url: url)
        controller.delegate = self
        previewPresenter = presenter
        document = controller
        return controller.presentOptionsMenu(
            from: CGRect(x: presenter.view.bounds.midX, y: presenter.view.bounds.midY, width: 1, height: 1),
            in: presenter.view,
            animated: true
        )
    }
}

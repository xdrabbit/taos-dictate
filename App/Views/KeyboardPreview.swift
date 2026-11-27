#if DEBUG
import SwiftUI
import UIKit

/// Simulator-only: shows the real TAOS keyboard view (compiled into the app for DEBUG)
/// at keyboard size with a sample decoded message, so its layout can be checked
/// without installing the keyboard. Launch with -kbPreview.
struct KeyboardPreview: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIViewController {
        KeyboardViewController.previewDecoded = ProcessInfo.processInfo.arguments.contains("-idle") ? nil : DecodedMessage(
            translation: "Hi, love. I just got out of work. I'll get there around 7 or 7:30. What do you want me to buy?",
            cleaned: "Hola amor, ya salí del trabajo. Llego tipo 7 o 7:30. ¿Qué quieres que compre?",
            notes: ["\"Tipo 7\" means \"around 7\"."],
            sourceLanguage: "Spanish")
        let host = UIViewController()
        let kb = KeyboardViewController()
        host.addChild(kb)
        kb.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.addSubview(kb.view)
        NSLayoutConstraint.activate([
            kb.view.leadingAnchor.constraint(equalTo: host.view.leadingAnchor),
            kb.view.trailingAnchor.constraint(equalTo: host.view.trailingAnchor),
            kb.view.bottomAnchor.constraint(equalTo: host.view.bottomAnchor),
        ])
        kb.didMove(toParent: host)
        return host
    }
    func updateUIViewController(_ vc: UIViewController, context: Context) {}
}
#endif

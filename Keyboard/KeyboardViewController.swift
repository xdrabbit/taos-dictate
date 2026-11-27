import UIKit

/// TAOS keyboard, v1: no microphone (iOS keyboard extensions can't use it).
/// Insert types the last dictation from the App Group; a button opens the app to dictate;
/// plus globe, space, delete, return.
final class KeyboardViewController: UIInputViewController {
    private let preview = UILabel()
    private let insertButton = UIButton(type: .system)
    private var globeButton: UIButton?
    private var deleteTimer: Timer?

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        globeButton?.isHidden = !needsInputModeSwitchKey
    }

    // MARK: UI

    private func buildUI() {
        guard let root = inputView else { return }

        preview.font = .preferredFont(forTextStyle: .footnote)
        preview.textColor = .secondaryLabel
        preview.numberOfLines = 2
        preview.lineBreakMode = .byTruncatingTail

        var insertConfig = UIButton.Configuration.filled()
        insertConfig.baseBackgroundColor = UIColor(red: 0.86, green: 0.38, blue: 0.20, alpha: 1)
        insertConfig.image = UIImage(systemName: "text.insert")
        insertConfig.imagePadding = 8
        insertConfig.title = L("keyboard.insert")
        insertConfig.cornerStyle = .large
        insertButton.configuration = insertConfig
        insertButton.addTarget(self, action: #selector(insertTapped), for: .touchUpInside)

        let open = key(L("keyboard.dictate"), symbol: "mic.fill", action: #selector(openApp))

        let globe = key(nil, symbol: "globe", action: nil)
        globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        globeButton = globe

        let space = key(L("keyboard.space"), symbol: nil, action: #selector(spaceTapped))
        let delete = key(nil, symbol: "delete.left", action: nil)
        delete.addTarget(self, action: #selector(deleteDown), for: .touchDown)
        delete.addTarget(self, action: #selector(deleteUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        let ret = key(nil, symbol: "return", action: #selector(returnTapped))

        let topRow = UIStackView(arrangedSubviews: [insertButton, open])
        topRow.spacing = 8
        topRow.distribution = .fill
        insertButton.setContentHuggingPriority(.defaultLow, for: .horizontal)
        open.setContentHuggingPriority(.required, for: .horizontal)

        let bottomRow = UIStackView(arrangedSubviews: [globe, space, delete, ret])
        bottomRow.spacing = 6
        space.widthAnchor.constraint(greaterThanOrEqualTo: bottomRow.widthAnchor, multiplier: 0.45).isActive = true

        let stack = UIStackView(arrangedSubviews: [preview, topRow, bottomRow])
        stack.axis = .vertical
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 8),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -8),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            topRow.heightAnchor.constraint(equalToConstant: 64),
            bottomRow.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func key(_ title: String?, symbol: String?, action: Selector?) -> UIButton {
        var c = UIButton.Configuration.gray()
        c.title = title
        c.image = symbol.flatMap { UIImage(systemName: $0) }
        c.imagePadding = 6
        c.baseForegroundColor = .label
        c.cornerStyle = .medium
        let b = UIButton(configuration: c)
        if let action { b.addTarget(self, action: action, for: .touchUpInside) }
        return b
    }

    private func refresh() {
        // Reading the App Group container needs Full Access.
        guard hasFullAccess else {
            preview.text = L("keyboard.need_full_access")
            insertButton.isEnabled = false
            return
        }
        if let last = SharedResult.load() {
            preview.text = last.text
            insertButton.isEnabled = true
        } else {
            preview.text = L("keyboard.nothing_yet")
            insertButton.isEnabled = false
        }
    }

    // MARK: Actions

    @objc private func insertTapped() {
        guard let text = SharedResult.load()?.text else { return }
        textDocumentProxy.insertText(text)
    }

    @objc private func spaceTapped() { textDocumentProxy.insertText(" ") }
    @objc private func returnTapped() { textDocumentProxy.insertText("\n") }

    @objc private func deleteDown() {
        textDocumentProxy.deleteBackward()
        deleteTimer?.invalidate()
        deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { [weak self] _ in
            self?.deleteTimer = Timer.scheduledTimer(withTimeInterval: 0.08, repeats: true) { _ in
                self?.textDocumentProxy.deleteBackward()
            }
        }
    }

    @objc private func deleteUp() {
        deleteTimer?.invalidate()
        deleteTimer = nil
    }

    /// Keyboards get no public "open my app" call (extensionContext.open is for Today widgets).
    /// This walks the responder chain to the host UIApplication and calls its public
    /// open(_:options:completionHandler:). Not private API, but Apple could stop it working;
    /// if it does, the preview tells the user to switch to the app themselves.
    @objc private func openApp() {
        var responder: UIResponder? = self
        while let r = responder {
            if let app = r as? UIApplication {
                app.open(TaosConfig.speakURL, options: [:], completionHandler: nil)
                return
            }
            responder = r.next
        }
        preview.text = L("keyboard.open_manually")
    }
}

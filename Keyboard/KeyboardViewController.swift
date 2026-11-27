import UIKit

/// TAOS keyboard: tap the mic, talk, tap again — the text is typed into the field.
///
/// iOS keyboards can't use the microphone, so the TAOS app records for us. The first
/// tap of a session opens the app (it starts listening at once); the user taps ◀ in the
/// status bar to come back and keeps talking. While the session is open, later taps
/// start and stop the app's recording directly. See KeyboardBridge.
final class KeyboardViewController: UIInputViewController {
    private let status = UILabel()
    private let mic = UIButton(type: .custom)
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let stylePill = UIButton(type: .system)
    private let translatePill = UIButton(type: .system)
    private var globeButton: UIButton?
    private var deleteTimer: Timer?
    private var poll: Timer?
    /// We asked the app to stop and are waiting for text.
    private var waiting = false

    private static let accent = UIColor(red: 0.86, green: 0.38, blue: 0.20, alpha: 1)
    private static let styles = ["formal", "professional", "conversational", "casual"]

    override func viewDidLoad() {
        super.viewDidLoad()
        buildUI()
        DarwinNotify.observe(KeyboardBridge.Note.state) { [weak self] in self?.refresh() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refresh()
        // Belt and braces: Darwin notifications can be missed while we're off screen.
        poll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.refresh() }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        poll?.invalidate(); poll = nil
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        globeButton?.isHidden = !needsInputModeSwitchKey
    }

    // MARK: UI

    private func buildUI() {
        guard let root = inputView else { return }

        status.font = .preferredFont(forTextStyle: .footnote)
        status.textColor = .secondaryLabel
        status.textAlignment = .center
        status.numberOfLines = 2
        status.adjustsFontSizeToFitWidth = true

        mic.layer.cornerRadius = 40
        mic.backgroundColor = Self.accent
        mic.tintColor = .white
        mic.setImage(UIImage(systemName: "mic.fill",
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)), for: .normal)
        mic.addTarget(self, action: #selector(micTapped), for: .touchUpInside)
        mic.accessibilityLabel = L("speak.start")
        mic.translatesAutoresizingMaskIntoConstraints = false
        spinner.color = .white
        spinner.translatesAutoresizingMaskIntoConstraints = false
        mic.addSubview(spinner)

        for pill in [stylePill, translatePill] {
            var c = UIButton.Configuration.gray()
            c.cornerStyle = .capsule
            c.baseForegroundColor = .label
            c.titleLineBreakMode = .byTruncatingTail
            pill.configuration = c
        }
        stylePill.addTarget(self, action: #selector(cycleStyle), for: .touchUpInside)
        translatePill.addTarget(self, action: #selector(toggleTranslate), for: .touchUpInside)

        let micRow = UIStackView(arrangedSubviews: [stylePill, mic, translatePill])
        micRow.alignment = .center
        micRow.distribution = .equalCentering
        micRow.spacing = 12

        let globe = key(nil, symbol: "globe", action: nil)
        globe.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)
        globeButton = globe
        let last = key(nil, symbol: "text.insert", action: #selector(insertLast))
        last.accessibilityLabel = L("keyboard.insert")
        let space = key(L("keyboard.space"), symbol: nil, action: #selector(spaceTapped))
        let delete = key(nil, symbol: "delete.left", action: nil)
        delete.addTarget(self, action: #selector(deleteDown), for: .touchDown)
        delete.addTarget(self, action: #selector(deleteUp), for: [.touchUpInside, .touchUpOutside, .touchCancel])
        let ret = key(nil, symbol: "return", action: #selector(returnTapped))

        let bottomRow = UIStackView(arrangedSubviews: [globe, last, space, delete, ret])
        bottomRow.spacing = 6
        space.widthAnchor.constraint(greaterThanOrEqualTo: bottomRow.widthAnchor, multiplier: 0.38).isActive = true

        let stack = UIStackView(arrangedSubviews: [status, micRow, bottomRow])
        stack.axis = .vertical
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 8),
            stack.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -8),
            mic.widthAnchor.constraint(equalToConstant: 80),
            mic.heightAnchor.constraint(equalToConstant: 80),
            spinner.centerXAnchor.constraint(equalTo: mic.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: mic.centerYAnchor),
            stylePill.widthAnchor.constraint(equalTo: translatePill.widthAnchor),
            stylePill.widthAnchor.constraint(lessThanOrEqualTo: micRow.widthAnchor, multiplier: 0.33),
            bottomRow.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func key(_ title: String?, symbol: String?, action: Selector?) -> UIButton {
        var c = UIButton.Configuration.gray()
        c.title = title
        c.image = symbol.flatMap { UIImage(systemName: $0) }
        c.baseForegroundColor = .label
        c.cornerStyle = .medium
        let b = UIButton(configuration: c)
        if let action { b.addTarget(self, action: action, for: .touchUpInside) }
        return b
    }

    // MARK: State

    private func refresh() {
        updatePills()

        guard hasFullAccess else {
            setMic(.idle, enabled: false)
            status.text = L("keyboard.need_full_access")
            return
        }

        if let text = KeyboardBridge.takeResult() {
            insert(text)
            waiting = false
        }

        let alive = KeyboardBridge.sessionAlive
        let phase: KeyboardBridge.Phase = alive ? KeyboardBridge.phase : (waiting ? .working : .idle)
        switch phase {
        case .listening:
            setMic(.listening)
            let secs = Int(Date().timeIntervalSince(KeyboardBridge.listenStart ?? Date()))
            status.text = String(format: L("kb.listening"), secs / 60, secs % 60)
        case .working:
            setMic(.working)
            status.text = L("speak.working")
        case .error:
            setMic(.idle)
            waiting = false
            status.text = KeyboardBridge.error ?? L("kb.tap_to_talk")
        case .idle:
            setMic(.idle)
            status.text = L(alive ? "kb.tap_to_talk" : "kb.tap_to_start")
        }
    }

    private enum MicLook { case idle, listening, working }
    private func setMic(_ look: MicLook, enabled: Bool = true) {
        mic.isEnabled = enabled && look != .working
        mic.alpha = enabled ? 1 : 0.4
        mic.backgroundColor = look == .listening ? .systemRed : Self.accent
        mic.imageView?.alpha = look == .working ? 0 : 1
        let icon = look == .listening ? "stop.fill" : "mic.fill"
        mic.setImage(UIImage(systemName: icon,
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 32, weight: .bold)), for: .normal)
        mic.accessibilityLabel = L(look == .listening ? "speak.stop" : "speak.start")
        if look == .working { spinner.startAnimating() } else { spinner.stopAnimating() }
    }

    private func updatePills() {
        let style = SharedPrefs.style
        stylePill.configuration?.title = L("style.\(style)")
        let mine = SharedPrefs.myLanguage.uppercased(), other = SharedPrefs.otherLanguage.uppercased()
        let on = SharedPrefs.target != nil
        translatePill.configuration?.title = on ? "\(mine) → \(other)" : mine
        translatePill.configuration?.baseBackgroundColor = on ? Self.accent : nil
        translatePill.configuration?.baseForegroundColor = on ? .white : .label
        translatePill.accessibilityLabel = String(format: L(on ? "kb.translate_on" : "kb.translate_off"), other)
    }

    // MARK: Actions

    @objc private func micTapped() {
        guard hasFullAccess else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        if KeyboardBridge.sessionAlive && KeyboardBridge.phase == .listening {
            waiting = true
            DarwinNotify.post(KeyboardBridge.Note.stop)
            setMic(.working)
            status.text = L("speak.working")
            return
        }
        KeyboardBridge.requestID = UUID().uuidString
        if KeyboardBridge.sessionAlive {
            DarwinNotify.post(KeyboardBridge.Note.start)
            setMic(.listening)
            status.text = String(format: L("kb.listening"), 0, 0)
        } else {
            openApp()
        }
    }

    @objc private func cycleStyle() {
        let i = Self.styles.firstIndex(of: SharedPrefs.style) ?? 1
        SharedPrefs.style = Self.styles[(i + 1) % Self.styles.count]
        updatePills()
    }

    @objc private func toggleTranslate() {
        SharedPrefs.target = SharedPrefs.target == nil ? SharedPrefs.otherLanguage : nil
        updatePills()
    }

    /// Types the text, adding a space if it would otherwise run into the previous word.
    private func insert(_ text: String) {
        var t = text
        if let before = textDocumentProxy.documentContextBeforeInput, let lastChar = before.last,
           !lastChar.isWhitespace, !(t.first?.isWhitespace ?? true) {
            t = " " + t
        }
        textDocumentProxy.insertText(t)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    @objc private func insertLast() {
        guard hasFullAccess, let text = SharedResult.load()?.text else { return }
        insert(text)
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
    /// if it does, the status line tells the user to open the app themselves.
    private func openApp() {
        var responder: UIResponder? = self
        while let r = responder {
            if let app = r as? UIApplication {
                app.open(URL(string: "taosdictate://session")!, options: [:]) { [weak self] ok in
                    if !ok { self?.status.text = L("keyboard.open_manually") }
                }
                return
            }
            responder = r.next
        }
        status.text = L("keyboard.open_manually")
    }
}

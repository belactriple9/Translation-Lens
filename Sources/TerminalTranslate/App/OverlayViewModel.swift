@preconcurrency import AppKit
import CoreGraphics
import Foundation
import SwiftUI
import Translation

@MainActor
final class OverlayViewModel: ObservableObject {
    @Published var frameImage: CGImage?
    @Published var translatedBlocks: [RenderedTextBlock] = []
    @Published var settings = TranslationSettings()
    @Published var isPaused = false
    @Published var status: OverlayStatus = .idle("Waiting for the overlay window.")
    @Published var translationConfiguration: TranslationSession.Configuration?

    private weak var window: NSWindow?
    private let captureEngine = ScreenCaptureEngine()
    private let ocrService = OCRService()
    private let translator = NativeTranslationEngine()
    private let colorSampler = ColorSampler()

    private var refreshTimer: Timer?
    private var observers: [NSObjectProtocol] = []
    private var eventMonitors: [Any] = []
    private var lastSignature = ""
    private var refreshTask: Task<Void, Never>?
    private var pendingRefreshForce = false
    private var pendingTranslationBlocks: [RecognizedTextBlock] = []
    private var pendingTranslationImage: CGImage?
    private var pendingTranslationID = UUID()
    private var activeTranslationID: UUID?

    func attach(window: NSWindow) {
        guard self.window !== window else {
            return
        }

        self.window = window
        configure(window: window)
        installObservers(for: window)
        installMousePassthroughMonitors(for: window)
        startRefreshTimer()
        updateWindowInteractivity()
        triggerRefresh(force: true)
    }

    func triggerRefresh(force: Bool = false) {
        pendingRefreshForce = pendingRefreshForce || force

        guard refreshTask == nil else {
            return
        }

        let effectiveForce = pendingRefreshForce
        pendingRefreshForce = false

        refreshTask = Task { [weak self] in
            await self?.refresh(force: effectiveForce)
            await MainActor.run {
                self?.refreshTask = nil
                if self?.pendingRefreshForce == true {
                    self?.triggerRefresh(force: true)
                }
            }
        }
    }

    func setShowSourceText(_ value: Bool) {
        settings.showSourceText = value
    }

    func setRefreshInterval(_ value: Double) {
        settings.refreshInterval = value
        startRefreshTimer()
    }

    func togglePause() {
        isPaused.toggle()
        triggerRefresh(force: true)
    }

    private func configure(window: NSWindow) {
        window.title = "Lens"
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isMovableByWindowBackground = true
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.minSize = NSSize(width: 360, height: 240)
    }

    private func installObservers(for window: NSWindow) {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()

        let center = NotificationCenter.default
        observers.append(
            center.addObserver(forName: NSWindow.didMoveNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateWindowInteractivity()
                    self?.triggerRefresh(force: true)
                }
            }
        )
        observers.append(
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateWindowInteractivity()
                    self?.triggerRefresh(force: true)
                }
            }
        )
        observers.append(
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateWindowInteractivity()
                    self?.triggerRefresh(force: true)
                }
            }
        )
    }

    private func installMousePassthroughMonitors(for window: NSWindow) {
        for monitor in eventMonitors {
            NSEvent.removeMonitor(monitor)
        }
        eventMonitors.removeAll()

        let handler: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateWindowInteractivity()
            }
        }

        if let globalMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseDown, .leftMouseUp],
            handler: handler
        ) {
            eventMonitors.append(globalMonitor)
        }

        let localMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .leftMouseDown, .leftMouseUp]
        ) { [weak self] event in
            self?.updateWindowInteractivity()
            return event
        }
        if let localMonitor {
            eventMonitors.append(localMonitor)
        }

        window.ignoresMouseEvents = true
    }

    private func updateWindowInteractivity() {
        guard let window, let contentBounds = window.contentView?.bounds else {
            return
        }

        let mouseLocationRect = NSRect(origin: NSEvent.mouseLocation, size: .zero)
        let locationInWindow = window.convertFromScreen(mouseLocationRect).origin
        let isInsideWindow = contentBounds.contains(locationInWindow)
        let edgeSize: CGFloat = 18
        let isNearEdge =
            locationInWindow.x <= edgeSize ||
            locationInWindow.x >= contentBounds.width - edgeSize ||
            locationInWindow.y <= edgeSize ||
            locationInWindow.y >= contentBounds.height - edgeSize

        window.ignoresMouseEvents = isInsideWindow && !isNearEdge
    }

    private func startRefreshTimer() {
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: settings.refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.triggerRefresh()
            }
        }
    }

    private func refresh(force: Bool) async {
        guard !Task.isCancelled else {
            return
        }

        guard !isPaused else {
            status = .idle("Capture paused.")
            return
        }

        guard let window else {
            status = .idle("Waiting for the overlay window.")
            return
        }

        guard captureEngine.hasPermission(promptIfNeeded: true) else {
            status = .error("Grant Screen Recording permission to Lens.")
            translatedBlocks = []
            return
        }

        do {
            let snapshot = try await captureEngine.captureBelow(window: window)
            frameImage = snapshot.image

            let recognizedBlocks = try await ocrService.recognize(in: snapshot.image)
            let signature = signatureForBlocks(recognizedBlocks)

            if !force, signature == lastSignature {
                if recognizedBlocks.isEmpty {
                    status = .idle("No text detected.")
                } else {
                    status = .running("Watching \(recognizedBlocks.count) text region(s).")
                }
                return
            }

            lastSignature = signature

            guard !recognizedBlocks.isEmpty else {
                translatedBlocks = []
                translationConfiguration = nil
                status = .idle("No text detected.")
                return
            }

            translatedBlocks = decorateFallbackBlocks(recognizedBlocks, image: snapshot.image)
            queueTranslation(for: recognizedBlocks, image: snapshot.image)
            status = .running("Detecting and translating \(recognizedBlocks.count) text region(s).")
        } catch {
            status = .error(error.localizedDescription)
        }
    }

    func performTranslation(using session: TranslationSession) async {
        guard let image = pendingTranslationImage, !pendingTranslationBlocks.isEmpty else {
            return
        }

        let jobID = pendingTranslationID
        guard activeTranslationID == nil else {
            return
        }

        activeTranslationID = jobID
        defer {
            activeTranslationID = nil
            if pendingTranslationID != jobID {
                var configuration = translationConfiguration
                configuration?.invalidate()
                translationConfiguration = configuration
            }
        }

        let sourceBlocks = pendingTranslationBlocks
        let translated = await translator.translate(blocks: sourceBlocks, using: session)

        guard pendingTranslationID == jobID else {
            return
        }

        translatedBlocks = decorate(blocks: translated, sourceBlocks: sourceBlocks, image: image)

        let translatedCount = translated.filter { !$0.isFallback }.count
        if translatedCount == 0 {
            status = .idle("Waiting for clearer text or a supported language.")
        } else {
            status = .running("Showing \(translatedCount) translated block(s).")
        }
    }

    private func queueTranslation(for blocks: [RecognizedTextBlock], image: CGImage) {
        pendingTranslationBlocks = blocks
        pendingTranslationImage = image
        pendingTranslationID = UUID()

        if translationConfiguration == nil {
            translationConfiguration = TranslationSession.Configuration(source: nil, target: nil)
        } else {
            var configuration = translationConfiguration
            configuration?.invalidate()
            translationConfiguration = configuration
        }
    }

    private func decorate(
        blocks: [RenderedTextBlock],
        sourceBlocks: [RecognizedTextBlock],
        image: CGImage
    ) -> [RenderedTextBlock] {
        blocks.enumerated().map { index, block in
            let sourceBlock = sourceBlocks[min(index, sourceBlocks.count - 1)]
            let style = colorSampler.style(block: sourceBlock, in: image)
            return RenderedTextBlock(
                sourceText: block.sourceText,
                translatedText: block.translatedText,
                boundingBox: block.boundingBox,
                isFallback: block.isFallback,
                background: style.background,
                foreground: style.foreground
            )
        }
    }

    private func decorateFallbackBlocks(_ blocks: [RecognizedTextBlock], image: CGImage) -> [RenderedTextBlock] {
        blocks.map { block in
            let style = colorSampler.style(block: block, in: image)
            return RenderedTextBlock(
                sourceText: block.sourceText,
                translatedText: block.sourceText,
                boundingBox: block.boundingBox,
                isFallback: true,
                background: style.background,
                foreground: style.foreground
            )
        }
    }

    private func signatureForBlocks(_ blocks: [RecognizedTextBlock]) -> String {
        blocks
            .map { block in
                let x = Int(block.boundingBox.origin.x * 1000)
                let y = Int(block.boundingBox.origin.y * 1000)
                let w = Int(block.boundingBox.size.width * 1000)
                let h = Int(block.boundingBox.size.height * 1000)
                return "\(block.sourceText)|\(x),\(y),\(w),\(h)"
            }
            .joined(separator: "\n")
    }
}

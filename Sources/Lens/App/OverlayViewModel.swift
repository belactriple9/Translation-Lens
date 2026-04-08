@preconcurrency import AppKit
import CoreGraphics
import Foundation
import SwiftUI

@MainActor
final class OverlayViewModel: ObservableObject {
    @Published var frameImage: CGImage?
    @Published var translatedBlocks: [RenderedTextBlock] = []
    @Published var settings = TranslationSettings()
    @Published var isPaused = false
    @Published var status: OverlayStatus = .idle("Waiting for the overlay window.")

    private weak var window: NSWindow?
    private let captureEngine = ScreenCaptureEngine()
    private let ocrService = OCRService()
    private let translator = NativeTranslationEngine()
    private let colorSampler = ColorSampler()

    private var displayLink: CVDisplayLink?
    private var observers: [NSObjectProtocol] = []
    private var eventMonitors: [Any] = []

    private var lastSignature = ""
    private var signatureChangedAt = Date.distantPast
    private var lastSignatureChangeCount = 0
    private var isScrolling = false

    private var captureTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var pendingTranslationBlocks: [RecognizedTextBlock]?
    private var pendingTranslationImage: CGImage?
    private var translationGeneration: UInt64 = 0

    func attach(window: NSWindow) {
        guard self.window !== window else {
            return
        }

        self.window = window
        configure(window: window)
        installObservers(for: window)
        installMousePassthroughMonitors(for: window)
        startDisplayLink()
        updateWindowInteractivity()
    }

    func setShowSourceText(_ value: Bool) {
        settings.showSourceText = value
    }

    func setTargetLanguage(_ value: TargetLanguage) {
        settings.targetLanguage = value
        translator.clearCache()
        lastSignature = ""
        scheduleCaptureNow()
    }

    func setRefreshInterval(_ value: Double) {
        settings.refreshInterval = value
    }

    func togglePause() {
        isPaused.toggle()
        if isPaused {
            translatedBlocks = []
            status = .idle("Capture paused.")
        } else {
            scheduleCaptureNow()
        }
    }

    // MARK: - Display Link (60fps capture)

    private func startDisplayLink() {
        guard displayLink == nil else { return }

        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, userInfo -> CVReturn in
            guard let userInfo else { return kCVReturnSuccess }
            let vm = Unmanaged<OverlayViewModel>.fromOpaque(userInfo).takeUnretainedValue()
            Task { @MainActor in
                vm.displayLinkFired()
            }
            return kCVReturnSuccess
        }

        let pointer = Unmanaged.passUnretained(self).toOpaque()
        CVDisplayLinkSetOutputCallback(link, callback, pointer)
        CVDisplayLinkStart(link)
        displayLink = link
    }

    private func displayLinkFired() {
        guard !isPaused, window != nil, captureTask == nil else { return }

        captureTask = Task { [weak self] in
            await self?.captureAndProcess()
            await MainActor.run {
                self?.captureTask = nil
            }
        }
    }

    func scheduleCaptureNow() {
        displayLinkFired()
    }

    // MARK: - Capture & OCR

    private func captureAndProcess() async {
        guard !Task.isCancelled, !isPaused else { return }

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

            if signature == lastSignature {
                return
            }

            // Detect scrolling: rapid signature changes
            let now = Date()
            let timeSinceLast = now.timeIntervalSince(signatureChangedAt)
            signatureChangedAt = now

            if timeSinceLast < 0.15 {
                lastSignatureChangeCount += 1
            } else {
                lastSignatureChangeCount = 0
            }

            let wasScrolling = isScrolling
            isScrolling = lastSignatureChangeCount >= 2

            lastSignature = signature

            if isScrolling {
                // Content is scrolling — drop overlays, skip translation
                translationTask?.cancel()
                translationTask = nil
                translatedBlocks = []
                if !wasScrolling {
                    status = .running("Scrolling\u{2026}")
                }
                return
            }

            guard !recognizedBlocks.isEmpty else {
                translatedBlocks = []
                status = .idle("No text detected.")
                return
            }

            // Queue translation (debounced)
            pendingTranslationBlocks = recognizedBlocks
            pendingTranslationImage = snapshot.image
            scheduleTranslation()

        } catch {
            status = .error(error.localizedDescription)
        }
    }

    // MARK: - Translation (debounced)

    private func scheduleTranslation() {
        translationTask?.cancel()
        translationGeneration &+= 1
        let gen = translationGeneration

        translationTask = Task { [weak self] in
            // Small debounce so rapid changes don't spam the translator
            try? await Task.sleep(for: .milliseconds(120))

            guard !Task.isCancelled else { return }
            await self?.runTranslation(generation: gen)
        }
    }

    private func runTranslation(generation: UInt64) async {
        guard generation == translationGeneration else { return }
        guard let blocks = pendingTranslationBlocks,
              let image = pendingTranslationImage,
              !blocks.isEmpty
        else { return }

        status = .running("Translating \(blocks.count) text region(s)\u{2026}")

        let targetLocale = settings.targetLanguage.locale
        let translated = await translator.translate(blocks: blocks, targetLanguage: targetLocale)

        guard generation == translationGeneration, !Task.isCancelled else { return }

        translatedBlocks = decorate(blocks: translated, sourceBlocks: blocks, image: image)

        let translatedCount = translated.filter { !$0.isFallback }.count
        let totalCount = translated.count
        if translatedCount == 0 {
            status = .idle("Text detected but already in your language.")
        } else {
            status = .running("Translated \(translatedCount) of \(totalCount) block(s).")
        }
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
                    self?.scheduleCaptureNow()
                }
            }
        )
        observers.append(
            center.addObserver(forName: NSWindow.didResizeNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateWindowInteractivity()
                    self?.scheduleCaptureNow()
                }
            }
        )
        observers.append(
            center.addObserver(forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateWindowInteractivity()
                    self?.scheduleCaptureNow()
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
                foreground: style.foreground,
                lineCount: block.lineCount
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

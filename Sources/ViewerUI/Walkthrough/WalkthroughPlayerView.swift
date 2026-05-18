import SwiftUI
import ViewerKit
import ViewerCore

/// Docked-at-the-bottom-of-the-right-pane controller strip for an
/// active walkthrough. Only visible when `controller.engine.state` is
/// not `.idle` (see ContentView's gate).
///
/// Layout (left → right):
///
///   ┌─────────────────────────────────────────────────────────────────┐
///   │ [speaker] narration text…           [● ● ● ─] scrub bar         │
///   │                                                                 │
///   │ [⌘[] [⏯] [⌘]]   1x▾   Steps▾   [+ Note]                  [Exit] │
///   └─────────────────────────────────────────────────────────────────┘
///
/// The strip is keyboard-shortcut-active when the engine is non-idle:
/// `Space` toggles play/pause, `⌘[` / `⌘]` go prev/next, `Esc` exits.
@MainActor
public struct WalkthroughPlayerView: View {

    @ObservedObject var controller: WalkthroughPlayerController

    public init(controller: WalkthroughPlayerController) {
        self.controller = controller
    }

    public var body: some View {
        VStack(spacing: 0) {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                topRow
                bottomRow
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Palette.controlBackground)
            .accessibilityIdentifier("mdv.walkthrough.player")
        }
    }

    // MARK: - Subviews

    private var topRow: some View {
        HStack(alignment: .top, spacing: 10) {
            // Speaker label — small pill on the left.
            speakerPill
            VStack(alignment: .leading, spacing: 2) {
                if let narration = controller.currentStep?.narration,
                   !narration.isEmpty {
                    Text(narration)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(3)
                        .accessibilityIdentifier("mdv.walkthrough.narration")
                } else {
                    Text(" ")    // reserve a line so the strip's
                                 // height doesn't jump when narration
                                 // is empty.
                }
            }
            Spacer(minLength: 12)
            scrubBar
                .frame(width: 140)
        }
    }

    private var bottomRow: some View {
        HStack(spacing: 8) {
            transportButtons
            speedPill
            stepsMenu
            noteButton
            Spacer()
            exitButton
        }
    }

    private var speakerPill: some View {
        let label = controller.currentStep?.speakerLabel ?? "claude"
        return Text(label)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.accentColor)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.accentColor.opacity(0.15))
            )
            .accessibilityIdentifier("mdv.walkthrough.speaker")
    }

    private var scrubBar: some View {
        let total = max(1, controller.totalSteps)
        let current = max(0, controller.currentStepIndex)
        return GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.secondary.opacity(0.18))
                Capsule()
                    .fill(Color.accentColor)
                    .frame(
                        width: geo.size.width
                             * CGFloat(current + 1)
                             / CGFloat(total)
                    )
            }
        }
        .frame(height: 4)
        .accessibilityIdentifier("mdv.walkthrough.scrub")
        .accessibilityLabel("Step \(controller.currentStepIndex + 1) of \(controller.totalSteps)")
    }

    private var transportButtons: some View {
        HStack(spacing: 4) {
            Button(action: { controller.previous() }) {
                Image(systemName: "chevron.left")
            }
            .help("Previous step (⌘[)")
            .keyboardShortcut("[", modifiers: .command)
            .disabled(!controller.canGoPrevious)
            .accessibilityIdentifier("mdv.walkthrough.prev")

            Button(action: { controller.togglePlayPause() }) {
                Image(systemName: controller.isPaused ? "play.fill" : "pause.fill")
            }
            .help(controller.isPaused ? "Play (Space)" : "Pause (Space)")
            .keyboardShortcut(.space, modifiers: [])
            .accessibilityIdentifier("mdv.walkthrough.playpause")

            Button(action: { controller.next() }) {
                Image(systemName: "chevron.right")
            }
            .help("Next step (⌘])")
            .keyboardShortcut("]", modifiers: .command)
            .disabled(!controller.canGoNext)
            .accessibilityIdentifier("mdv.walkthrough.next")
        }
        .buttonStyle(.borderless)
        .controlSize(.regular)
    }

    private var speedPill: some View {
        Menu(controller.speed.label) {
            ForEach(WalkthroughAutoAdvance.Speed.allCases, id: \.self) { s in
                Button(action: { controller.setSpeed(s) }) {
                    HStack {
                        Text(s.label)
                        if controller.speed == s {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .font(.system(size: 11, weight: .medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.15))
        )
        .help("Playback speed")
        .accessibilityIdentifier("mdv.walkthrough.speed")
    }

    private var stepsMenu: some View {
        Menu {
            ForEach(Array(controller.steps.enumerated()), id: \.element.id) { idx, step in
                Button(action: { controller.jump(to: step.id) }) {
                    HStack {
                        Text("\(idx + 1). \(step.narration ?? step.id)")
                            .lineLimit(1)
                        if idx == controller.currentStepIndex {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text("Steps")
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .font(.system(size: 11, weight: .medium))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 4)
                .fill(Color.secondary.opacity(0.15))
        )
        .accessibilityIdentifier("mdv.walkthrough.steps")
    }

    private var noteButton: some View {
        Button(action: { controller.requestNote() }) {
            HStack(spacing: 3) {
                Image(systemName: "plus.bubble")
                Text("Note")
            }
            .font(.system(size: 11, weight: .medium))
        }
        .buttonStyle(.borderless)
        .help("Capture a note at this step (Code Review hookup coming)")
        .accessibilityIdentifier("mdv.walkthrough.note")
    }

    private var exitButton: some View {
        Button("Exit") { controller.exit() }
            .buttonStyle(.borderless)
            .keyboardShortcut(.escape, modifiers: [])
            .font(.system(size: 11))
            .accessibilityIdentifier("mdv.walkthrough.exit")
    }
}

// MARK: - Controller

/// View-model wrapper around `WalkthroughEngine` + `WalkthroughAutoAdvance`.
/// Holds the delegate (`WalkthroughPlayerImpl`) so the engine's `weak`
/// reference doesn't dangle. SwiftUI binds to `@Published` mirrors of
/// engine state — we can't observe the engine directly (no
/// `ObservableObject` conformance there by design).
@MainActor
public final class WalkthroughPlayerController: ObservableObject {

    @Published public private(set) var script: WalkthroughScript?
    @Published public private(set) var currentStepIndex: Int = -1
    @Published public private(set) var isPaused: Bool = false
    @Published public private(set) var isActive: Bool = false
    @Published public private(set) var speed: WalkthroughAutoAdvance.Speed = .x1

    public let engine: WalkthroughEngine
    public let autoAdvance: WalkthroughAutoAdvance
    public let impl: WalkthroughPlayerImpl
    private weak var model: DocumentModel?

    public init(model: DocumentModel) {
        let e = WalkthroughEngine()
        let impl = WalkthroughPlayerImpl(model: model, engine: e)
        e.delegate = impl
        self.engine = e
        self.impl = impl
        self.autoAdvance = WalkthroughAutoAdvance(engine: e)
        self.model = model
    }

    // MARK: - Derived state for the view

    public var steps: [Step] { script?.steps ?? [] }
    public var totalSteps: Int { steps.count }

    public var currentStep: Step? {
        guard currentStepIndex >= 0,
              currentStepIndex < steps.count else { return nil }
        return steps[currentStepIndex]
    }

    public var canGoPrevious: Bool { currentStepIndex > 0 }
    public var canGoNext: Bool { currentStepIndex + 1 < totalSteps }

    // MARK: - Lifecycle

    /// Load + start a script. Reads from the engine on each transport
    /// call to refresh the published mirrors.
    public func start(_ script: WalkthroughScript) {
        impl.prepare(for: script)
        engine.load(script)
        self.script = script
        isActive = true
        engine.next()
        syncFromEngine()
        scheduleAdvanceIfNeeded()
    }

    public func exit() {
        autoAdvance.cancel()
        isActive = false
        script = nil
        currentStepIndex = -1
        model?.walkthroughBridge.clearHighlight()
        model?.walkthroughBridge.clearPopover()
    }

    // MARK: - Transport

    public func next() {
        engine.next()
        syncFromEngine()
        scheduleAdvanceIfNeeded()
    }

    public func previous() {
        engine.previous()
        syncFromEngine()
        scheduleAdvanceIfNeeded()
    }

    public func togglePlayPause() {
        if engine.state == .paused {
            engine.resume()
            syncFromEngine()
            scheduleAdvanceIfNeeded()
        } else if engine.state == .playing {
            engine.pause()
            autoAdvance.cancel()
            syncFromEngine()
        }
    }

    public func jump(to stepID: String) {
        try? engine.jumpTo(stepID: stepID)
        syncFromEngine()
        scheduleAdvanceIfNeeded()
    }

    public func setSpeed(_ s: WalkthroughAutoAdvance.Speed) {
        autoAdvance.setSpeed(s)
        speed = s
    }

    public func requestNote() {
        guard let step = currentStep else { return }
        model?.walkthroughBridge.requestNote(forStepID: step.id)
        // Diagnostic crumb — wiring to Code Review threads is the
        // follow-up task (BACKLOG).
        FileHandle.standardError.write(
            Data("walkthrough: note requested at step \(step.id)\n".utf8)
        )
    }

    // MARK: - Private

    private func syncFromEngine() {
        currentStepIndex = engine.stepIndex
        isPaused = engine.state == .paused
        if engine.state == .done {
            autoAdvance.cancel()
        }
    }

    private func scheduleAdvanceIfNeeded() {
        guard engine.state == .playing,
              let step = currentStep,
              impl.pendingAwaitUser == nil else {
            autoAdvance.cancel()
            return
        }
        autoAdvance.schedule(forStepDwell: step.dwellSec)
    }
}

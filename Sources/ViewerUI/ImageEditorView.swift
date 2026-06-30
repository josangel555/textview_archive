import AppKit
import SwiftUI
import UniformTypeIdentifiers
import ViewerCore

/// Minimal image-editor PoC view (TSK-342) — binds to the host-tested
/// `ImageEditorViewModel`. Left: the live WYSIWYG preview of the edited
/// document. Right: the controls (tonal sliders + geometry + history + save).
///
/// All the heavy lifting (decode → ops → CGImage, export) is in the engine /
/// view-model, both host-tested; this view is the thin, render-gated binding
/// layer whose on-screen behaviour is validated on the VM pixel/AX lane.
/// a11y identifiers (`mdv.imageEditor.*`) exist so that VM UI test can find the
/// preview + a slider + the Done button.
struct ImageEditorView: View {
    @StateObject private var vm: ImageEditorViewModel
    /// TSK-1101 — last canvas pixel painted this drag, for continuous brush strokes.
    @State private var lastPaintPixel: (x: Int, y: Int)?
    /// TSK-1059 — in-progress shape drag (view points), for the live rubber-band.
    @State private var shapeDragStart: CGPoint?
    @State private var shapeDragCurrent: CGPoint?
    /// TSK-1064 — in-progress lasso path (view points) while dragging the lasso tool.
    @State private var lassoPoints: [CGPoint] = []
    /// TSK-1073 — resize/stretch dialog state.
    @State private var resizeSheetShown = false
    @State private var resizeWidth = ""
    @State private var resizeHeight = ""
    @State private var resizePercent = "100"
    @State private var resizeUsePercent = false
    @State private var resizeMaintainAspect = true
    @State private var resizeCanvasMode = false   // TSK-1076: scale vs canvas-size
    /// TSK-1074 — skew dialog state.
    @State private var skewSheetShown = false
    @State private var skewH = "0"
    @State private var skewV = "0"
    /// Called when the user dismisses the editor (returns to the plain viewer).
    let onClose: () -> Void

    init(url: URL, onClose: @escaping () -> Void) {
        _vm = StateObject(wrappedValue: ImageEditorViewModel(ImageDocument(contentsOf: url)))
        self.onClose = onClose
    }

    var body: some View {
        HStack(spacing: 0) {
            preview
                // The floor matters: in a panel-crowded narrow window the
                // flexible preview otherwise collapses to ~0pt while the
                // fixed-width controls survive — an "editor with no image"
                // (TSK-618). Better to overflow/clip the controls edge than
                // to silently hide the document being edited.
                .frame(minWidth: 160, maxWidth: .infinity, maxHeight: .infinity)
                .background(Palette.windowBackground)
            Divider()
            controls
                .frame(width: 260)
                .background(.regularMaterial)
        }
        .ignoresSafeArea()
        .accessibilityIdentifier("mdv.imageEditor")
    }

    /// TSK-1073 — the Resize/Stretch dialog (by percent or pixels, aspect lock).
    @ViewBuilder private var resizeSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Resize Image").font(.headline)
            // TSK-1076: Scale (resample) vs Canvas size (pad/crop, no scaling).
            Picker("Mode", selection: $resizeCanvasMode) {
                Text("Scale image").tag(false)
                Text("Canvas size").tag(true)
            }
            .pickerStyle(.segmented)
            if resizeCanvasMode {
                HStack { Text("Width:"); TextField("", text: $resizeWidth) }
                HStack { Text("Height:"); TextField("", text: $resizeHeight) }
                Text("Canvas is padded/cropped; the image is not scaled.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Picker("By", selection: $resizeUsePercent) {
                    Text("Pixels").tag(false)
                    Text("Percent").tag(true)
                }
                .pickerStyle(.segmented)
                if resizeUsePercent {
                    HStack { Text("Percent:"); TextField("100", text: $resizePercent) }
                } else {
                    HStack { Text("Width:"); TextField("", text: $resizeWidth) }
                    HStack { Text("Height:"); TextField("", text: $resizeHeight) }
                    Toggle("Maintain aspect ratio", isOn: $resizeMaintainAspect)
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { resizeSheetShown = false }
                Button("Apply") { applyResize() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 300)
        .accessibilityIdentifier("mdv.imageEditor.resizeSheet")
    }

    private func applyResize() {
        defer { resizeSheetShown = false }
        guard let cg = vm.rendered else { return }
        let current = (width: cg.width, height: cg.height)
        if resizeCanvasMode {
            // TSK-1076: pad/crop the canvas (no scaling).
            vm.commitGeometry(.canvasSize(
                width: Int(resizeWidth) ?? current.width,
                height: Int(resizeHeight) ?? current.height))
            return
        }
        let target: (width: Int, height: Int)
        if resizeUsePercent {
            target = ImageResizeMath.scaled(current, percent: Double(resizePercent) ?? 100)
        } else {
            target = ImageResizeMath.sized(
                current: current,
                width: Int(resizeWidth) ?? current.width,
                height: Int(resizeHeight) ?? current.height,
                maintainAspect: resizeMaintainAspect)
        }
        vm.commitGeometry(.resize(width: target.width, height: target.height))
    }

    /// TSK-1074 — the Skew dialog (horizontal / vertical degrees).
    @ViewBuilder private var skewSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Skew Image").font(.headline)
            HStack { Text("Horizontal °:"); TextField("0", text: $skewH) }
            HStack { Text("Vertical °:"); TextField("0", text: $skewV) }
            HStack {
                Spacer()
                Button("Cancel") { skewSheetShown = false }
                Button("Apply") { applySkew() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 280)
        .accessibilityIdentifier("mdv.imageEditor.skewSheet")
    }

    private func applySkew() {
        defer { skewSheetShown = false }
        vm.commitGeometry(.skew(horizontalDegrees: Double(skewH) ?? 0,
                                verticalDegrees: Double(skewV) ?? 0))
    }

    /// TSK-1065 — true when a drag from `p` should MOVE the current selection
    /// (the marquee tool is active and `p` falls inside the existing selection).
    private func isMovingSelection(_ p: CGPoint, in displayed: CGRect, cg: CGImage) -> Bool {
        guard vm.tool.isSelection, let sel = vm.selection,
              let px = PaintCoordinateMapping.canvasPixel(
                  p, in: displayed, imageWidth: cg.width, imageHeight: cg.height)
        else { return false }
        return sel.contains(x: px.x, y: px.y)
    }

    // MARK: - preview

    @ViewBuilder private var preview: some View {
        if let cg = vm.rendered {
            GeometryReader { geo in
                let displayed = Self.aspectFitRect(
                    imageSize: CGSize(width: cg.width, height: cg.height),
                    in: geo.frame(in: .local))
                ZStack {
                    Image(cg, scale: 1, label: Text("Edited image preview"))
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .accessibilityIdentifier("mdv.imageEditor.preview")
                    // Vector annotations (TSK-287) draw OVER the raster, in the
                    // exact rect the fitted image occupies — a pure SwiftUI
                    // sibling (Canvas), so no opaque-representable occlusion.
                    VectorOverlayView(overlay: vm.overlay, imageRect: displayed)
                    // TSK-1059/1058: live rubber-band while dragging a shape tool.
                    if vm.tool.isShape, let s = shapeDragStart, let c = shapeDragCurrent {
                        if vm.tool.isOpenShape {
                            Path { p in p.move(to: s); p.addLine(to: c) }
                                .stroke(Color.accentColor, lineWidth: 1)
                                .allowsHitTesting(false)
                        } else {
                            let r = CGRect(x: min(s.x, c.x), y: min(s.y, c.y),
                                           width: abs(c.x - s.x), height: abs(c.y - s.y))
                            Group {
                                if vm.tool.shapeKind == .ellipse {
                                    Ellipse().stroke(Color.accentColor, lineWidth: 1)
                                } else if vm.tool.shapeKind == .roundedRect {
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color.accentColor, lineWidth: 1)
                                } else {
                                    Rectangle().stroke(Color.accentColor, lineWidth: 1)
                                }
                            }
                            .frame(width: r.width, height: r.height)
                            .position(x: r.midX, y: r.midY)
                            .allowsHitTesting(false)
                        }
                    }
                    // TSK-1063: marquee — live dashed rect during the drag.
                    if vm.tool.isSelection, let s = shapeDragStart, let c = shapeDragCurrent {
                        let r = CGRect(x: min(s.x, c.x), y: min(s.y, c.y),
                                       width: abs(c.x - s.x), height: abs(c.y - s.y))
                        Rectangle()
                            .stroke(Color.white, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .frame(width: r.width, height: r.height)
                            .position(x: r.midX, y: r.midY)
                            .allowsHitTesting(false)
                    }
                    // TSK-1063: persistent marching-ants for the committed selection.
                    if let sel = vm.selection,
                       let r = SelectionGeometry.viewRect(sel, in: displayed,
                                                          imageWidth: cg.width, imageHeight: cg.height) {
                        Rectangle()
                            .stroke(Color.white, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .frame(width: r.width, height: r.height)
                            .position(x: r.midX, y: r.midY)
                            .allowsHitTesting(false)
                    }
                    // TSK-1064: live lasso path while dragging the lasso tool.
                    if vm.tool == .selectLasso, lassoPoints.count >= 2 {
                        Path { p in p.addLines(lassoPoints) }
                            .stroke(Color.white, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .allowsHitTesting(false)
                    }
                    // TSK-1064: persistent marching-ants for a committed lasso polygon.
                    if let sel = vm.selection,
                       let pts = SelectionGeometry.viewPoints(of: sel, in: displayed,
                                                              imageWidth: cg.width, imageHeight: cg.height),
                       pts.count >= 3 {
                        Path { p in p.addLines(pts); p.closeSubpath() }
                            .stroke(Color.white, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                // TSK-1101: map drag/tap → canvas pixel → apply the current paint
                // tool. Brush sweeps a continuous stroke; eyedropper/bucket act on
                // release. Off-image points map to nil and paint nothing.
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            if vm.tool.isShape {
                                shapeDragStart = value.startLocation
                                shapeDragCurrent = value.location
                                return
                            }
                            if vm.tool == .selectLasso {
                                lassoPoints.append(value.location)
                                return
                            }
                            if vm.tool == .selectRect {
                                // A drag starting INSIDE the current selection moves it
                                // (on release); otherwise rubber-band a new marquee.
                                if !isMovingSelection(value.startLocation, in: displayed, cg: cg) {
                                    shapeDragStart = value.startLocation
                                    shapeDragCurrent = value.location
                                }
                                return
                            }
                            guard vm.tool.isContinuous,
                                  let px = PaintCoordinateMapping.canvasPixel(
                                      value.location, in: displayed,
                                      imageWidth: cg.width, imageHeight: cg.height)
                            else { return }
                            if vm.tool == .airbrush {
                                vm.applyTool(atX: px.x, y: px.y)   // spray at each point
                            } else if let last = lastPaintPixel {
                                vm.brushStroke(fromX: last.x, y0: last.y, toX: px.x, y1: px.y)
                            } else {
                                vm.applyTool(atX: px.x, y: px.y)
                            }
                            lastPaintPixel = px
                        }
                        .onEnded { value in
                            if vm.tool == .selectLasso {
                                defer { lassoPoints = [] }
                                if let poly = SelectionGeometry.polygon(
                                    from: lassoPoints, in: displayed,
                                    imageWidth: cg.width, imageHeight: cg.height) {
                                    vm.setSelection(poly)
                                }
                                return
                            }
                            if vm.tool == .selectRect {
                                defer { shapeDragStart = nil; shapeDragCurrent = nil }
                                if isMovingSelection(value.startLocation, in: displayed, cg: cg) {
                                    let dx = Int(value.translation.width / displayed.width * CGFloat(cg.width))
                                    let dy = Int(value.translation.height / displayed.height * CGFloat(cg.height))
                                    vm.moveSelection(byX: dx, y: dy)
                                } else {
                                    vm.setSelection(SelectionGeometry.selectionRect(
                                        from: value.startLocation, to: value.location,
                                        in: displayed, imageWidth: cg.width, imageHeight: cg.height))
                                }
                                return
                            }
                            if let kind = vm.tool.shapeKind {
                                defer { shapeDragStart = nil; shapeDragCurrent = nil }
                                let open = vm.tool.isOpenShape
                                let rect = open
                                    ? ShapeDragGeometry.normalizedSignedRect(
                                        from: value.startLocation, to: value.location, in: displayed)
                                    : ShapeDragGeometry.normalizedRect(
                                        from: value.startLocation, to: value.location, in: displayed)
                                let big = open
                                    ? (abs(rect.width) > 0.001 || abs(rect.height) > 0.001)
                                    : (rect.width > 0.001 && rect.height > 0.001)
                                if big {
                                    vm.drawShape(kind, normalizedFrame: rect)
                                }
                                return
                            }
                            defer { lastPaintPixel = nil }
                            guard vm.tool != .none,
                                  let px = PaintCoordinateMapping.canvasPixel(
                                      value.location, in: displayed,
                                      imageWidth: cg.width, imageHeight: cg.height)
                            else { return }
                            if !vm.tool.isContinuous {
                                vm.applyTool(atX: px.x, y: px.y)
                            }
                        }
                )
            }
            .padding(16)
        } else {
            ContentUnavailableView(
                "Couldn't render image", systemImage: "exclamationmark.triangle",
                description: Text(vm.lastError ?? "Unknown error"))
                .accessibilityIdentifier("mdv.imageEditor.error")
        }
    }

    // MARK: - controls

    private var controls: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Edit Image").font(.headline)
                    Spacer()
                    Button("Done", action: onClose)
                        .accessibilityIdentifier("mdv.imageEditor.done")
                }

                // TSK-1321: edit-after-placement inspector for the selected overlay shape
                // (self-hides when nothing is selected).
                ImageElementPropertiesPanel(vm: vm)

                groupLabel("Tone")
                slider("Brightness", \.brightness, -1, 1, id: "brightness")
                slider("Contrast", \.contrast, 0, 2, id: "contrast")
                slider("Saturation", \.saturation, 0, 2, id: "saturation")
                slider("Exposure", \.exposureEV, -2, 2, id: "exposure")
                slider("Shadows", \.shadow, 0, 1, id: "shadow")
                slider("Highlights", \.highlight, 0, 1, id: "highlight")
                slider("Sharpen", \.sharpness, 0, 2, id: "sharpen")

                groupLabel("Geometry")
                HStack {
                    Button { vm.commitGeometry(.orient(.right90)) } label: {
                        Label("Rotate", systemImage: "rotate.right")
                    }
                    .accessibilityIdentifier("mdv.imageEditor.rotate")
                    // TSK-1072: flip / rotate (wire the existing orientation verbs).
                    Button { vm.commitGeometry(.orient(.left90)) } label: {
                        Label("Rotate Left", systemImage: "rotate.left")
                    }
                    .accessibilityIdentifier("mdv.imageEditor.rotateLeft")
                    Button { vm.commitGeometry(.orient(.down)) } label: {
                        Label("Rotate 180", systemImage: "arrow.2.circlepath")
                    }
                    .accessibilityIdentifier("mdv.imageEditor.rotate180")
                    Button { vm.commitGeometry(.orient(.upMirrored)) } label: {
                        Label("Flip H", systemImage: "arrow.left.and.right")
                    }
                    .accessibilityIdentifier("mdv.imageEditor.flipH")
                    Button { vm.commitGeometry(.orient(.downMirrored)) } label: {
                        Label("Flip V", systemImage: "arrow.up.and.down")
                    }
                    .accessibilityIdentifier("mdv.imageEditor.flipV")
                    // TSK-1075: invert colors (photo-negative).
                    Button { vm.commitGeometry(.invertColors) } label: {
                        Label("Invert Colors", systemImage: "circle.lefthalf.filled")
                    }
                    .accessibilityIdentifier("mdv.imageEditor.invertColors")
                    // TSK-1077: fill the whole canvas with the current paint color.
                    Button { vm.clearImage() } label: {
                        Label("Clear", systemImage: "square.slash")
                    }
                    .accessibilityIdentifier("mdv.imageEditor.clearImage")
                    // TSK-1073: resize / stretch dialog.
                    Button {
                        resizeWidth = String(vm.rendered?.width ?? 0)
                        resizeHeight = String(vm.rendered?.height ?? 0)
                        resizeSheetShown = true
                    } label: {
                        Label("Resize", systemImage: "arrow.up.left.and.arrow.down.right")
                    }
                    .accessibilityIdentifier("mdv.imageEditor.resize")
                    // TSK-1074: skew dialog.
                    Button { skewH = "0"; skewV = "0"; skewSheetShown = true } label: {
                        Label("Skew", systemImage: "skew")
                    }
                    .accessibilityIdentifier("mdv.imageEditor.skew")
                    Button { vm.undo() } label: {
                        Label("Undo", systemImage: "arrow.uturn.backward")
                    }
                    .disabled(!vm.canUndo)
                    .accessibilityIdentifier("mdv.imageEditor.undo")
                    Button { vm.redo() } label: {
                        Label("Redo", systemImage: "arrow.uturn.forward")
                    }
                    .disabled(!vm.canRedo)
                    .accessibilityIdentifier("mdv.imageEditor.redo")
                }
                .sheet(isPresented: $resizeSheetShown) { resizeSheet }
                .sheet(isPresented: $skewSheetShown) { skewSheet }

                // Minimal draw-tool affordance (TSK-749): commits a shape / text
                // op to the undo history. Each draw is undoable via the buttons
                // above. A full marquee/drag tool is the render-gated remainder.
                groupLabel("Draw")
                HStack {
                    // TSK-1309: the one-shot "Box" button was removed — it was
                    // redundant with the interactive `.drawRect` tool in the tool
                    // picker (a hardcoded centred red box). The drawRect tool is the
                    // discoverable, positionable equivalent.
                    // TSK-1310: add a RETAINED, editable text element (selectable + restyleable +
                    // retypable via the inspector), replacing the old one-shot raster placeholder.
                    Button {
                        vm.addShape(Self.centeredShape(.text))
                        vm.selectLatestShape()
                    } label: {
                        Label("Text", systemImage: "textformat")
                    }
                    .accessibilityIdentifier("mdv.imageEditor.drawText")
                }

                groupLabel("Paint")
                paintControls

                groupLabel("Annotations")
                HStack {
                    Button { vm.addShape(Self.centeredShape(.rect)) } label: {
                        Image(systemName: "rectangle")
                    }
                    .accessibilityIdentifier("mdv.imageEditor.addRect")
                    Button { vm.addShape(Self.centeredShape(.ellipse)) } label: {
                        Image(systemName: "circle")
                    }
                    .accessibilityIdentifier("mdv.imageEditor.addEllipse")
                    Button { vm.addShape(Self.centeredShape(.line)) } label: {
                        Image(systemName: "line.diagonal")
                    }
                    .accessibilityIdentifier("mdv.imageEditor.addLine")
                    Button { vm.addShape(Self.centeredShape(.arrow)) } label: {
                        Image(systemName: "arrow.up.right")
                    }
                    .accessibilityIdentifier("mdv.imageEditor.addArrow")
                    Button { vm.clearShapes() } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityIdentifier("mdv.imageEditor.clearShapes")
                    .disabled(vm.overlay.isEmpty)
                }

                groupLabel("Document")
                HStack {
                    Button("Reset Tone") { vm.resetTonal() }
                    Button("Revert All") { vm.revertAll() }
                }
                // TSK-1081: Save (in-place if opened from a file, else Save As) + Save a Copy.
                HStack {
                    Button { saveInPlace() } label: {
                        Label("Save", systemImage: "square.and.arrow.down.fill")
                    }
                    .accessibilityIdentifier("mdv.imageEditor.saveInPlace")
                    Button { saveCopy() } label: {
                        Label("Save a Copy…", systemImage: "square.and.arrow.down")
                    }
                    .accessibilityIdentifier("mdv.imageEditor.save")
                }
                // TSK-1067: copy the selection (or whole image) to a file / paste a file in.
                HStack {
                    Button("Copy to File…") { copyToFile() }
                        .accessibilityIdentifier("mdv.imageEditor.copyToFile")
                    Button("Paste from File…") { pasteFromFile() }
                        .accessibilityIdentifier("mdv.imageEditor.pasteFromFile")
                }

                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text.uppercased())
            .font(.caption2).foregroundStyle(.secondary)
            .padding(.top, 4)
    }

    /// Commit a sample text label near the top-left of the current render. A
    // MARK: - paint tools (TSK-285)

    /// Raster paint affordance: tool picker (eyedropper / brush / bucket), color
    /// swatch, brush size, fill tolerance, and a discard. The tap-to-paint surface
    /// is the preview itself, wired on the VM via `applyTool(atX:y:)` — that
    /// gesture mapping (image point → canvas pixel) is the render-gated remainder
    /// validated on the VM; the model behaviour each control drives is host-tested.
    @ViewBuilder private var paintControls: some View {
        Picker("Tool", selection: $vm.tool) {
            Text("Off").tag(ImageEditorViewModel.RasterTool.none)
            Image(systemName: "eyedropper").tag(ImageEditorViewModel.RasterTool.colorPicker)
            Image(systemName: "paintbrush.pointed").tag(ImageEditorViewModel.RasterTool.brush)
            Image(systemName: "pencil").tag(ImageEditorViewModel.RasterTool.pencil)
            Image(systemName: "eraser").tag(ImageEditorViewModel.RasterTool.eraser)
            Image(systemName: "wind").tag(ImageEditorViewModel.RasterTool.airbrush)
            Image(systemName: "drop").tag(ImageEditorViewModel.RasterTool.floodFill)
            Image(systemName: "rectangle").tag(ImageEditorViewModel.RasterTool.drawRect)
            Image(systemName: "circle").tag(ImageEditorViewModel.RasterTool.drawEllipse)
            Image(systemName: "rectangle.roundedtop").tag(ImageEditorViewModel.RasterTool.drawRoundedRect)
            Image(systemName: "line.diagonal").tag(ImageEditorViewModel.RasterTool.drawLine)
            Image(systemName: "arrow.up.right").tag(ImageEditorViewModel.RasterTool.drawArrow)
            Image(systemName: "rectangle.dashed").tag(ImageEditorViewModel.RasterTool.selectRect)
            Image(systemName: "lasso").tag(ImageEditorViewModel.RasterTool.selectLasso)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("mdv.imageEditor.paintTool")

        ColorPicker("Color", selection: paintColorBinding, supportsOpacity: true)
            .accessibilityIdentifier("mdv.imageEditor.paintColor")
        // TSK-1069: background color (Clear fills with it) + swap.
        HStack {
            ColorPicker("Background", selection: bgColorBinding, supportsOpacity: true)
                .accessibilityIdentifier("mdv.imageEditor.bgColor")
            Button { vm.swapColors() } label: {
                Label("Swap", systemImage: "arrow.triangle.2.circlepath")
            }
            .accessibilityIdentifier("mdv.imageEditor.swapColors")
        }
        // TSK-1070: preset color palette — tap a swatch to set the paint color.
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 18), spacing: 3)], spacing: 3) {
            ForEach(Array(StandardPalette.colors.enumerated()), id: \.offset) { _, c in
                swatch(c)
            }
        }
        .accessibilityIdentifier("mdv.imageEditor.palette")
        // TSK-1118: recently-used colors (newest first), shown only once non-empty.
        if !vm.recentColors.isEmpty {
            Text("Recent").font(.caption2).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 18), spacing: 3)], spacing: 3) {
                ForEach(Array(vm.recentColors.enumerated()), id: \.offset) { _, c in
                    swatch(c)
                }
            }
            .accessibilityIdentifier("mdv.imageEditor.recentColors")
        }

        VStack(alignment: .leading, spacing: 2) {
            Text("Brush Size: \(vm.brushRadius)").font(.caption)
            Slider(
                value: Binding(
                    get: { Double(vm.brushRadius) },
                    set: { vm.brushRadius = Int($0.rounded()) }),
                in: 0...32)
                .accessibilityIdentifier("mdv.imageEditor.brushSize")
        }

        if vm.tool.isShape {
            Toggle("Fill shape", isOn: $vm.shapeFilled)
                .accessibilityIdentifier("mdv.imageEditor.shapeFill")
        }

        if vm.tool == .brush || vm.tool == .eraser {
            Toggle("Square brush", isOn: $vm.squareBrush)
                .accessibilityIdentifier("mdv.imageEditor.squareBrush")
        }

        if vm.tool.isSelection || vm.selection != nil {
            HStack {
                Button("Select All") { vm.selectAll() }
                    .accessibilityIdentifier("mdv.imageEditor.selectAll")
                if vm.canPaste() {
                    Button("Paste") { vm.pasteImage() }
                        .accessibilityIdentifier("mdv.imageEditor.paste")
                }
                if vm.selection != nil {
                    Button("Copy") { vm.copySelection() }
                        .accessibilityIdentifier("mdv.imageEditor.copySelection")
                    Button("Cut") { vm.cutSelection() }
                        .accessibilityIdentifier("mdv.imageEditor.cutSelection")
                    Button("Crop") { vm.cropToSelection() }
                        .accessibilityIdentifier("mdv.imageEditor.cropToSelection")
                    Button("Delete") { vm.deleteSelection() }
                        .accessibilityIdentifier("mdv.imageEditor.deleteSelection")
                    Button("Invert") { vm.invertSelection() }
                        .accessibilityIdentifier("mdv.imageEditor.invertSelection")
                    Button("Deselect") { vm.clearSelection() }
                }
            }
        }

        VStack(alignment: .leading, spacing: 2) {
            Text("Fill Tolerance: \(vm.fillTolerance)").font(.caption)
            Slider(
                value: Binding(
                    get: { Double(vm.fillTolerance) },
                    set: { vm.fillTolerance = UInt8(max(0, min(255, $0.rounded()))) }),
                in: 0...255)
                .accessibilityIdentifier("mdv.imageEditor.fillTolerance")
        }

        if vm.hasPaint {
            Button("Discard Paint") { vm.discardPaint() }
                .accessibilityIdentifier("mdv.imageEditor.discardPaint")
        }
    }

    /// Bridge the VM's straight-RGBA8 `paintColor` to SwiftUI's `Color` for the
    /// `ColorPicker`. The setter resolves the picked `Color` into 8-bit sRGB
    /// components via `NSColor`.
    private func colorBinding(
        _ get: @escaping () -> RGBAColor, _ set: @escaping (RGBAColor) -> Void
    ) -> Binding<Color> {
        Binding(
            get: {
                let c = get()
                return Color(.sRGB,
                             red: Double(c.r) / 255, green: Double(c.g) / 255,
                             blue: Double(c.b) / 255, opacity: Double(c.a) / 255)
            },
            set: { newColor in
                let ns = NSColor(newColor).usingColorSpace(.sRGB) ?? NSColor(newColor)
                func byte(_ v: CGFloat) -> UInt8 { UInt8(max(0, min(255, (v * 255).rounded()))) }
                set(RGBAColor(
                    r: byte(ns.redComponent), g: byte(ns.greenComponent),
                    b: byte(ns.blueComponent), a: byte(ns.alphaComponent)))
            })
    }
    private var paintColorBinding: Binding<Color> { colorBinding({ vm.paintColor }, { vm.paintColor = $0 }) }
    private var bgColorBinding: Binding<Color> { colorBinding({ vm.bgColor }, { vm.bgColor = $0 }) }

    /// TSK-1070 — a SwiftUI `Color` from a straight-RGBA8 `RGBAColor` (palette swatches).
    private func swiftUIColor(_ c: RGBAColor) -> Color {
        Color(.sRGB, red: Double(c.r) / 255, green: Double(c.g) / 255,
              blue: Double(c.b) / 255, opacity: Double(c.a) / 255)
    }

    /// TSK-1070/1118 — a tappable color swatch: sets the paint color and records
    /// it into the recent-swatches MRU. Shared by the preset palette + recent rows.
    private func swatch(_ c: RGBAColor) -> some View {
        RoundedRectangle(cornerRadius: 3)
            .fill(swiftUIColor(c))
            .frame(width: 18, height: 18)
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(.secondary, lineWidth: 0.5))
            .onTapGesture { vm.paintColor = c; vm.recordRecentColor(c) }
    }

    private func slider(
        _ label: String,
        _ keyPath: ReferenceWritableKeyPath<ImageEditorViewModel, Double>,
        _ lo: Double, _ hi: Double, id: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption)
            Slider(
                value: Binding(
                    get: { vm[keyPath: keyPath] },
                    // TSK-1050: debounce — a drag fires many deltas/sec; coalesce
                    // them into one render instead of running CoreImage per tick.
                    set: { vm[keyPath: keyPath] = $0; vm.scheduleRender() }),
                in: lo...hi)
                .accessibilityIdentifier("mdv.imageEditor.\(id)")
        }
    }

    /// A new shape of `kind` placed in the centre of the image (normalized
    /// `0...1` space): a 40% box for closed shapes, a diagonal across the middle
    /// 40% for open shapes (line / arrow), styled with the default red stroke so
    /// it reads as an annotation against most photos.
    static func centeredShape(_ kind: VectorShape.Kind) -> VectorShape {
        let style = ShapeStyle(stroke: .red, lineWidth: 3)
        switch kind {
        case .rect, .ellipse, .roundedRect:
            return VectorShape(
                kind: kind, frame: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4),
                style: style)
        case .line, .arrow:
            let frame = VectorShape.openFrame(
                from: CGPoint(x: 0.3, y: 0.3), to: CGPoint(x: 0.7, y: 0.7))
            return VectorShape(kind: kind, frame: frame, style: style)
        case .text:
            // A retained, editable text label (TSK-1310) — default copy + 6%-of-height size.
            return VectorShape(
                kind: .text, frame: CGRect(x: 0.3, y: 0.4, width: 0.4, height: 0.12),
                style: style, text: "Text", fontSize: 0.06)
        }
    }

    /// Compute the rect a `imageSize` raster occupies when aspect-fit-centered
    /// into `bounds` — the same fit `Image(...).aspectRatio(contentMode: .fit)`
    /// applies — so the vector overlay maps its normalized `0...1` coordinates
    /// into the exact pixels the image covers. Returns `.zero` for a degenerate
    /// image (so the overlay simply draws nothing).
    static func aspectFitRect(imageSize: CGSize, in bounds: CGRect) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0,
              bounds.width > 0, bounds.height > 0 else { return .zero }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let w = imageSize.width * scale
        let h = imageSize.height * scale
        return CGRect(
            x: bounds.minX + (bounds.width - w) / 2,
            y: bounds.minY + (bounds.height - h) / 2,
            width: w, height: h)
    }

    /// Present an `NSSavePanel` and write the edited document via the
    /// host-tested `ImageEditorViewModel.export`. Format follows the chosen
    /// extension (defaults to PNG).
    private func saveCopy() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "edited.png"
        panel.allowedContentTypes = [.png, .jpeg, .heic, .bmp, .gif, .tiff]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let format = imageFormat(forExtension: url.pathExtension)
        // Route through the view-model so a write/encoder failure (disk
        // full, dir not writable, HEIC encode failure) is captured in
        // `lastError` and surfaced — the old `try? vm.export(...)` discarded
        // EVERY failure, so a failed save looked exactly like a successful
        // one (silent data loss). Mirror AudioEditorView.saveCopy().
        // TSK-1053: encode + write run off-main so a big image doesn't freeze
        // the UI during save; the alert (on failure) comes back on the main actor.
        Task {
            if !(await vm.saveCopyAsync(format: format, to: url)) {
                let alert = NSAlert()
                alert.messageText = "Couldn't save a copy"
                alert.informativeText = vm.lastError ?? "The image couldn't be saved."
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    /// TSK-1067 — copy the selection (or whole image) to a chosen image file.
    private func copyToFile() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "selection.png"
        panel.allowedContentTypes = [.png, .jpeg, .heic, .bmp, .gif, .tiff]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = vm.copyToFile(to: url, format: imageFormat(forExtension: url.pathExtension))
    }

    /// TSK-1081 — map a file extension to an export format (shared by the save paths).
    private func imageFormat(forExtension ext: String) -> ExportSpec.Format {
        switch ext.lowercased() {
        case "jpg", "jpeg": return .jpeg
        case "heic": return .heic
        case "bmp": return .bmp
        case "gif": return .gif
        case "tif", "tiff": return .tiff
        default: return .png
        }
    }

    /// TSK-1081 — Save: write back to the document's original file if it has one;
    /// otherwise fall through to Save-a-Copy (Save As).
    private func saveInPlace() {
        guard let url = vm.sourceURL else { saveCopy(); return }
        let fmt = imageFormat(forExtension: url.pathExtension)
        Task {
            if !(await vm.saveCopyAsync(format: fmt, to: url)) {
                let alert = NSAlert()
                alert.messageText = "Couldn't save"
                alert.informativeText = vm.lastError ?? "The image couldn't be saved."
                alert.alertStyle = .warning
                alert.runModal()
            }
        }
    }

    /// TSK-1067 — paste an image file onto the canvas (at the selection origin).
    private func pasteFromFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.png, .jpeg, .heic, .bmp, .gif, .tiff]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = vm.pasteImageFromFile(from: url)
    }
}

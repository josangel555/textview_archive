import SwiftUI
import ViewerCore

/// In-app HTTP request tool (TSK-721). A request form (method · URL · headers ·
/// body) on top, a response view (status · timing · headers · body) below,
/// hosted in a tab via `DocumentModel.openHTTPClient()` →
/// `openHostedView(title:rootView:)`. All request logic lives in the pure,
/// host-tested `HTTPClientCore`; this view only binds + renders.
///
/// The send/parse path is exercised by `HTTPClientViewModelTests` (model layer);
/// the on-screen rendering is left for VM render validation per the testing
/// rules (host can't prove SwiftUI pixels).
struct HTTPClientView: View {
    @StateObject private var model = HTTPClientViewModel()
    /// TSK-1447 — save-request popover state (view-local).
    @State private var showSavePopover = false
    @State private var saveName = ""

    var body: some View {
        VSplitView {
            requestForm
                .frame(minHeight: 200, idealHeight: 280)
            responsePane
                .frame(minHeight: 160, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Request form

    private var requestForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker("", selection: $model.request.method) {
                    ForEach(HTTPMethod.allCases, id: \.self) { method in
                        Text(method.rawValue).tag(method)
                    }
                }
                .labelsHidden()
                .frame(width: 110)
                .accessibilityIdentifier("mdv.http.method")

                TextField("https://example.com/api", text: $model.request.urlString)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityIdentifier("mdv.http.url")
                    .onSubmit { model.send() }

                Button(model.isSending ? "Sending…" : "Send") { model.send() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.isSending)
                    .accessibilityIdentifier("mdv.http.send")
            }

            savedAndHistoryBar

            headersEditor

            if model.request.method.allowsBody {
                Text("Body")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextEditor(text: $model.request.body)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 60)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.3))
                    )
                    .accessibilityIdentifier("mdv.http.body")
            }
        }
        .padding(12)
    }

    /// TSK-1447 — the request-builder ergonomics bar: Save the current request
    /// under a name, and a Load menu recalling saved + recent (history) requests.
    private var savedAndHistoryBar: some View {
        HStack(spacing: 8) {
            Button("Save…") { showSavePopover = true }
                .accessibilityIdentifier("mdv.http.save")
                .popover(isPresented: $showSavePopover, arrowEdge: .bottom) { savePopover }

            Menu("Load") {
                if model.saved.isEmpty && model.history.isEmpty {
                    Text("No saved or recent requests")
                }
                if !model.saved.isEmpty {
                    Section("Saved") {
                        ForEach(model.saved) { s in
                            Button(s.name) { model.load(s.request) }
                        }
                    }
                }
                if !model.history.isEmpty {
                    Section("Recent") {
                        ForEach(model.history) { h in
                            Button(h.displayLabel) { model.load(h.request) }
                        }
                        Divider()
                        Button("Clear History") { model.clearHistory() }
                    }
                }
            }
            .fixedSize()
            .disabled(model.saved.isEmpty && model.history.isEmpty)
            .accessibilityIdentifier("mdv.http.load")

            Spacer()
        }
    }

    /// The Save popover: name the current request, then Save (disabled on empty).
    private var savePopover: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Save request").font(.headline)
            TextField("Name", text: $saveName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 220)
                .accessibilityIdentifier("mdv.http.saveName")
                .onSubmit(commitSave)
            HStack {
                Spacer()
                Button("Cancel") { showSavePopover = false }
                Button("Save", action: commitSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(saveName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(12)
    }

    private func commitSave() {
        let trimmed = saveName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        model.saveCurrent(name: trimmed)
        saveName = ""
        showSavePopover = false
    }

    private var headersEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("Headers")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button {
                    model.addHeader()
                } label: {
                    Image(systemName: "plus")
                }
                .buttonStyle(.borderless)
                .accessibilityIdentifier("mdv.http.addHeader")
            }
            ForEach($model.request.headers) { $header in
                HStack(spacing: 6) {
                    Toggle("", isOn: $header.isEnabled)
                        .labelsHidden()
                    TextField("Name", text: $header.name)
                        .textFieldStyle(.roundedBorder)
                    TextField("Value", text: $header.value)
                        .textFieldStyle(.roundedBorder)
                    Button {
                        model.removeHeader(id: header.id)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                }
            }
        }
    }

    // MARK: - Response pane

    @ViewBuilder
    private var responsePane: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundColor(.red)
                    .accessibilityIdentifier("mdv.http.error")
            } else if let response = model.response {
                HStack(spacing: 12) {
                    Text(response.statusLine)
                        .font(.headline)
                        .foregroundColor(response.isSuccess ? .green : .orange)
                        .accessibilityIdentifier("mdv.http.status")
                    Text(String(format: "%.0f ms", response.elapsed * 1000))
                        .foregroundColor(.secondary)
                    Text("\(response.body.count) bytes")
                        .foregroundColor(.secondary)
                    Spacer()
                }
                .font(.caption)

                if !response.headers.isEmpty {
                    DisclosureGroup("Response Headers (\(response.headers.count))") {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 2) {
                                ForEach(response.headers) { header in
                                    Text("\(header.name): \(header.value)")
                                        .font(.system(.caption, design: .monospaced))
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }
                        }
                        .frame(maxHeight: 120)
                    }
                }

                ScrollView {
                    Text(response.bodyText ?? "<\(response.body.count) bytes of binary data>")
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                        .accessibilityIdentifier("mdv.http.responseBody")
                }
            } else {
                // TSK-1435: purposeful empty state (what this tool is + how
                // to fire the first request).
                HostedEmptyStateView(EmptyStateCatalog.httpClient)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// View model bridging the SwiftUI form to the pure `HTTPClientCore`. Holds the
/// editable request + last response/error and drives the async send. Host
/// tests (`HTTPClientViewModelTests`) exercise `addHeader` / `removeHeader` and
/// the response/error application paths via `applyResult` without a network.
@MainActor
final class HTTPClientViewModel: ObservableObject {
    @Published var request = HTTPRequestModel()
    @Published private(set) var response: HTTPResponseModel?
    @Published private(set) var errorMessage: String?
    @Published private(set) var isSending = false
    /// TSK-1447 — recent sent requests (auto-recorded) + user-saved named requests,
    /// mirrored from the store so the Load menu binds them.
    @Published private(set) var history: [HTTPHistoryEntry] = []
    @Published private(set) var saved: [HTTPSavedRequest] = []

    /// Persisted history/saved store (defaults to the on-disk one; tests inject a
    /// temp-dir store). TSK-1447.
    private let store: HTTPRequestStore

    init(store: HTTPRequestStore = HTTPRequestStore()) {
        self.store = store
        self.history = store.history
        self.saved = store.saved
    }

    func addHeader() {
        request.headers.append(HTTPHeader(name: "", value: ""))
    }

    func removeHeader(id: UUID) {
        request.headers.removeAll { $0.id == id }
    }

    // MARK: - TSK-1447: history + save

    /// Record a sent request in history (dedup on content) and refresh the
    /// published mirror. Called on send completion (status known on success).
    func recordHistory(_ request: HTTPRequestModel, status: Int?) {
        store.recordHistory(request, status: status)
        history = store.history
    }

    /// Save the CURRENT request under `name` (no-op on an empty name) and refresh
    /// the saved mirror.
    func saveCurrent(name: String) {
        guard store.save(name: name, request: request) != nil else { return }
        saved = store.saved
    }

    /// Load a stored request (from history or saved) back into the editor.
    func load(_ request: HTTPRequestModel) {
        self.request = request
    }

    func deleteSaved(id: UUID) {
        store.deleteSaved(id: id)
        saved = store.saved
    }

    func clearHistory() {
        store.clearHistory()
        history = store.history
    }

    func send() {
        guard !isSending else { return }
        isSending = true
        errorMessage = nil
        let snapshot = request
        Task { @MainActor in
            do {
                let result = try await HTTPClientCore.send(snapshot)
                recordHistory(snapshot, status: result.statusCode)
                applyResult(.success(result))
            } catch let httpError as HTTPRequestError {
                // Record only genuine send attempts — a pure build-validation
                // failure (empty/invalid/unsupported URL) never left the app, so
                // it doesn't belong in history.
                switch httpError {
                case .transport, .nonHTTPResponse: recordHistory(snapshot, status: nil)
                case .emptyURL, .invalidURL, .unsupportedScheme: break
                }
                applyResult(.failure(httpError))
            } catch {
                recordHistory(snapshot, status: nil)
                applyResult(.failure(.transport(code: -1, message: error.localizedDescription)))
            }
        }
    }

    /// Apply a send outcome to the published state. Separated from `send` so a
    /// host test can pin the state transitions without hitting the network.
    func applyResult(_ result: Result<HTTPResponseModel, HTTPRequestError>) {
        isSending = false
        switch result {
        case .success(let response):
            self.response = response
            self.errorMessage = nil
        case .failure(let error):
            self.response = nil
            self.errorMessage = error.message
        }
    }
}

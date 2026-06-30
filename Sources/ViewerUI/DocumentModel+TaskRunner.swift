import Foundation
import ViewerCore

/// TSK-1160 — the Task Runner panel's DocumentModel wiring: open the panel + discover the
/// runnable tasks from the active project root. The @Published flag + view-model live on
/// DocumentModel (stored props can't be in an extension); this is the open method. The
/// presentation (.sheet) + menu trigger are the view-side companions; this is host-testable.
extension DocumentModel {

    /// Open the Task Runner panel, discovering tasks from the active project root: the opened
    /// folder (sidebar root) if there is one, else the active file's directory.
    public func openTaskRunner() {
        let root = sidebar.rootURL ?? tabs.selected?.url?.deletingLastPathComponent()
        let vm = TaskRunnerViewModel()
        if let root { vm.discover(at: root) }
        taskRunnerVM = vm
        showTaskRunner = true
    }
}

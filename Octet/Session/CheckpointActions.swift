import Foundation

/// Restoring a checkpoint: asks first, names the files, and offers Undo.
@MainActor
enum CheckpointActions {
    static func confirmRestore(_ checkpoint: Checkpoint, changed: [String], in directory: String) {
        let time = checkpoint.date.formatted(date: .omitted, time: .shortened)
        guard !changed.isEmpty else {
            ToastCenter.shared.info("Nothing to restore", detail: "The files are the same as at \(time).")
            return
        }
        let shown = Array(changed.prefix(12))
        ConfirmCenter.shared.ask(
            title: "Put \(changed.count) \(changed.count == 1 ? "file" : "files") back as they were at \(time)?",
            message: "\(checkpoint.label). Files made since are removed. The current state is saved as a checkpoint first, so this can be undone.",
            items: shown + (changed.count > shown.count ? ["and \(changed.count - shown.count) more"] : []),
            confirmTitle: "Restore",
            destructive: true
        ) { _ in
            restore(checkpoint, in: directory)
        }
    }

    static func restore(_ checkpoint: Checkpoint, in directory: String) {
        let time = checkpoint.date.formatted(date: .omitted, time: .shortened)
        let toast = ToastCenter.shared.progress("Restoring \(time)…")
        DispatchQueue.global(qos: .userInitiated).async {
            let outcome = Result { try Checkpoints.restore(checkpoint, in: directory) }
            DispatchQueue.main.async {
                switch outcome {
                case .success(let before):
                    ToastCenter.shared.dismiss(handleId: toast)
                    ToastCenter.shared.info("Restored the files to \(time)", detail: checkpoint.label, after: 8,
                                            action: .init(title: "Undo") { restore(before, in: directory) })
                case .failure(let error):
                    ToastCenter.shared.fail(toast, "Couldn't restore \(time)", detail: String(describing: error))
                }
            }
        }
    }
}

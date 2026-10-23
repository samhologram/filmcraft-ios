import Foundation
@preconcurrency import FilmCraftKit

/// Export: renders with the engine (`file.exportMedia` behind `ProjectHandle.startExport`, options
/// `{"preset":"h264","width"?,"height"?,"crf","audio":"aac","range":"all"}`), polls the job at ~4 Hz into
/// `exportProgress`, then saves to Photos or Files.
extension EditorModel {
    func export(to destination: ExportDestination, options: ExportOptions) async {
        guard !isExporting else { return }
        exportMessage = nil
        exportProgress = 0
        if isPlaying { playback.stop() }
        let task = Task { @MainActor [weak self] () -> Void in
            guard let self else { return }
            let phase = await ExportService.run(
                handle: self.handle, options: options,
                setJob: { self.exportJob = $0 },
                progress: { self.exportProgress = $0 })
            switch phase {
            case .done(let file):
                self.exportProgress = 1
                do {
                    let message = try await ExportService.save(file, to: destination)
                    self.exportMessage = message
                    Log.export.info("export done: \(message, privacy: .public)")
                } catch {
                    self.exportMessage = errorText(error)
                    self.lastError = errorText(error)
                    Log.export.error("export save failed: \(errorText(error), privacy: .public)")
                }
            case .failed(let message):
                self.exportMessage = message
                self.lastError = message
                Log.export.error("export failed: \(message, privacy: .public)")
            case .cancelled:
                self.exportMessage = "Export cancelled"
                Log.export.info("export cancelled")
            }
            self.exportProgress = nil
            self.exportTask = nil
        }
        exportTask = task
        await task.value
    }

    func cancelExport() {
        if let job = exportJob { handle.cancelJob(jobId: job) }
        exportTask?.cancel()
    }
}

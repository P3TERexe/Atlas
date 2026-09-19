import Foundation
@preconcurrency import AVFoundation

// MARK: - Plugin

class VideoPlugin: AtlasPlugin {
    let id = "video"
    
    var capabilities: [ToolCapability] {
        let videoFormats = Array(MediaFormats.video).sorted()
        
        return [
            ToolCapability(
                id: "video.extractAudio",
                description: "Extracts the audio track from a video into an audio file. Set 'format' to 'mp3' or 'm4a' (default: m4a, no external tools needed).",
                inputFormats: videoFormats,
                outputFormats: ["m4a", "mp3"],
                executor: ExtractAudioAction()
            ),
            ToolCapability(
                id: "video.convert",
                description: "Converts a video to another container/format (mp4, mov) using ffmpeg. Set 'quality' from 1 to 100 for resolution (default 75).",
                inputFormats: videoFormats,
                outputFormats: ["mp4", "mov"],
                executor: ConvertVideoAction()
            ),
        ]
    }
}

// MARK: - Extract Audio

final class ExtractAudioAction: ActionExecutor {
    func validate(step: ActionStep, context: FinderContext) throws {
        _ = try InputResolver.resolve(step: step, context: context, extensions: MediaFormats.video)
    }
    
    func shellCommands(step: ActionStep, context: FinderContext) -> [String]? {
        guard let inputs = try? InputResolver.resolve(step: step, context: context, extensions: MediaFormats.video) else { return nil }
        guard !inputs.isEmpty, let directory = context.currentDirectory else { return nil }
        
        let format = (step.format?.lowercased() ?? "m4a")
        
        return inputs.map { inputURL in
            let outputURL = FileResolver.uniqueURL(
                in: directory,
                baseName: inputURL.deletingPathExtension().lastPathComponent + "-audio",
                extensionName: format == "mp3" ? "mp3" : "m4a"
            )
            if format == "mp3" {
                return "ffmpeg -i \(inputURL.path) -vn -c:a libmp3lame -q:a 2 \(outputURL.path)"
            } else {
                return "ffmpeg -i \(inputURL.path) -vn -c:a aac -b:a 192k \(outputURL.path)"
            }
        }
    }
    
    func execute(step: ActionStep, context: FinderContext, progress: ItemProgressCallback?) async throws -> ActionResult {
        var outputFiles: [URL] = []
        do {
            let inputs = try InputResolver.resolve(step: step, context: context, extensions: MediaFormats.video)
            guard let directory = context.currentDirectory else {
                throw ExecutorError.executionFailed("Cartella corrente non disponibile.")
            }
            let format = step.format?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "m4a"
            for (index, inputURL) in inputs.enumerated() {
                try Task.checkCancellation()
                progress?(index + 1, inputs.count, "Estrazione audio: \(inputURL.lastPathComponent)")
                let outputURL = FileResolver.uniqueURL(
                    in: directory,
                    baseName: inputURL.deletingPathExtension().lastPathComponent + "-audio",
                    extensionName: format == "mp3" ? "mp3" : "m4a"
                )
                try await StagedOutput.write(to: outputURL, journal: &outputFiles) { temporaryURL in
                    if format == "mp3" {
                        guard let ffmpeg = Self.ffmpegBinary() else {
                            throw ExecutorError.executionFailed("L'estrazione in MP3 richiede ffmpeg. Installa con: brew install ffmpeg")
                        }
                        let status = try await run(binary: ffmpeg, arguments: [
                            "-i", inputURL.path, "-vn", "-c:a", "libmp3lame", "-q:a", "2", "-y", temporaryURL.path
                        ])
                        guard status == 0, FileManager.default.fileExists(atPath: temporaryURL.path) else {
                            throw ExecutorError.executionFailed("Estrazione MP3 fallita per \(inputURL.lastPathComponent)")
                        }
                    } else {
                        do {
                            try await Self.extractAudioNative(inputURL: inputURL, outputURL: temporaryURL)
                        } catch {
                            if error is CancellationError { throw error }
                            try Task.checkCancellation()
                            guard let ffmpeg = Self.ffmpegBinary() else { throw error }
                            if FileManager.default.fileExists(atPath: temporaryURL.path) {
                                try FileManager.default.removeItem(at: temporaryURL)
                            }
                            let status = try await run(binary: ffmpeg, arguments: [
                                "-i", inputURL.path, "-vn", "-c:a", "aac", "-b:a", "192k", "-y", temporaryURL.path
                            ])
                            guard status == 0, FileManager.default.fileExists(atPath: temporaryURL.path) else {
                                throw ExecutorError.executionFailed("Estrazione audio fallita per \(inputURL.lastPathComponent)")
                            }
                        }
                    }
                }
            }
            return ActionResult(success: true, outputFiles: outputFiles, message: "Estratto l'audio da \(outputFiles.count) video (\(format.uppercased()))")
        } catch {
            throw ActionExecutionError(underlying: error, partialResult: ActionResult(success: false, outputFiles: outputFiles, message: nil))
        }
    }
    
    // MARK: Native AVFoundation extraction (m4a, no external tools)
    
    private static func extractAudioNative(inputURL: URL, outputURL: URL) async throws {
        let asset = AVURLAsset(url: inputURL)
        guard let audioTrack = try await asset.loadTracks(withMediaType: .audio).first else {
            throw ExecutorError.executionFailed("Nessuna traccia audio in \(inputURL.lastPathComponent)")
        }
        
        let reader = try AVAssetReader(asset: asset)
        let trackOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        reader.add(trackOutput)
        
        // Passthrough: writer input without outputSettings copies the compressed
        // audio (AAC) directly into the m4a container (fast, lossless).
        let formatDescriptions = try await audioTrack.load(.formatDescriptions)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .m4a)
        let writerInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: formatDescriptions.first)
        writer.add(writerInput)
        defer {
            if reader.status == .reading { reader.cancelReading() }
            if writer.status == .writing { writer.cancelWriting() }
        }
        
        guard reader.startReading(), writer.startWriting() else {
            throw ExecutorError.executionFailed("Impossibile avviare l'estrazione audio per \(inputURL.lastPathComponent)")
        }
        writer.startSession(atSourceTime: .zero)
        
        let queue = DispatchQueue(label: "atlas.audio-extract")
        nonisolated(unsafe) let writerInputLocal = writerInput
        nonisolated(unsafe) let trackOutputLocal = trackOutput
        writerInput.requestMediaDataWhenReady(on: queue) {
            while writerInputLocal.isReadyForMoreMediaData {
                if let sampleBuffer = trackOutputLocal.copyNextSampleBuffer() {
                    if !writerInputLocal.append(sampleBuffer) {
                        break
                    }
                } else {
                    writerInputLocal.markAsFinished()
                    break
                }
            }
        }
        
        let deadline = Date().addingTimeInterval(300)
        while reader.status == .reading && writer.status == .writing {
            if Date() > deadline {
                reader.cancelReading()
                throw ExecutorError.executionFailed("Timeout durante l'estrazione audio di \(inputURL.lastPathComponent)")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        
        try Task.checkCancellation()
        guard reader.status == .completed, writer.status == .writing else {
            throw ExecutorError.executionFailed("Lettura audio fallita per \(inputURL.lastPathComponent): \(reader.error?.localizedDescription ?? writer.error?.localizedDescription ?? "stato non valido")")
        }
        writer.finishWriting(completionHandler: {})
        while writer.status == .writing {
            guard Date() <= deadline else {
                throw ExecutorError.executionFailed("Timeout durante la scrittura audio di \(inputURL.lastPathComponent)")
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try Task.checkCancellation()
        
        guard reader.status == .completed, writer.status == .completed else {
            let readerDetail = reader.error?.localizedDescription ?? reader.status.rawValue.description
            let writerDetail = writer.error?.localizedDescription ?? writer.status.rawValue.description
            throw ExecutorError.executionFailed("Estrazione audio fallita per \(inputURL.lastPathComponent): \(readerDetail) / \(writerDetail)")
        }
    }
    
    private static func ffmpegBinary() -> String? {
        BinaryLocator.locate("ffmpeg")
    }
    
    private func run(binary: String, arguments: [String]) async throws -> Int32 {
        let result = try await AsyncProcessRunner.run(executableURL: URL(fileURLWithPath: binary), arguments: arguments)
        return result.exitCode
    }
}

// MARK: - Convert Video

final class ConvertVideoAction: ActionExecutor {
    func validate(step: ActionStep, context: FinderContext) throws {
        _ = try Self.containerFormat(for: step.format ?? "mp4")
        _ = try InputResolver.resolve(step: step, context: context, extensions: MediaFormats.video)
    }
    
    func shellCommands(step: ActionStep, context: FinderContext) -> [String]? {
        guard let inputs = try? InputResolver.resolve(step: step, context: context, extensions: MediaFormats.video) else { return nil }
        guard !inputs.isEmpty, let directory = context.currentDirectory else { return nil }
        
        guard let format = try? Self.containerFormat(for: step.format ?? "mp4") else { return nil }
        
        return inputs.map { inputURL in
            let outputURL = FileResolver.uniqueURL(
                in: directory,
                baseName: inputURL.deletingPathExtension().lastPathComponent,
                extensionName: format
            )
            return ([BinaryLocator.locate("ffmpeg") ?? "ffmpeg"] + Self.arguments(inputURL: inputURL, outputURL: outputURL, quality: step.quality ?? 75)).map(ZipFilesAction.shellQuote).joined(separator: " ")
        }
    }
    
    func execute(step: ActionStep, context: FinderContext, progress: ItemProgressCallback?) async throws -> ActionResult {
        var outputFiles: [URL] = []
        do {
            let inputs = try InputResolver.resolve(step: step, context: context, extensions: MediaFormats.video)
            guard let directory = context.currentDirectory else {
                throw ExecutorError.executionFailed("Cartella corrente non disponibile.")
            }
            let fileExtension = try Self.containerFormat(for: step.format ?? "mp4")
            guard let ffmpeg = BinaryLocator.locate("ffmpeg") else {
                throw ExecutorError.executionFailed("La conversione video richiede ffmpeg. Installa con: brew install ffmpeg")
            }
            for (index, inputURL) in inputs.enumerated() {
                try Task.checkCancellation()
                progress?(index + 1, inputs.count, "Conversione: \(inputURL.lastPathComponent)")
                let outputURL = FileResolver.uniqueURL(in: directory, baseName: inputURL.deletingPathExtension().lastPathComponent, extensionName: fileExtension)
                try await StagedOutput.write(to: outputURL, journal: &outputFiles) { temporaryURL in
                    let result = try await AsyncProcessRunner.run(
                        executableURL: URL(fileURLWithPath: ffmpeg),
                        arguments: Self.arguments(inputURL: inputURL, outputURL: temporaryURL, quality: step.quality ?? 75)
                    )
                    guard result.isSuccess, FileManager.default.fileExists(atPath: temporaryURL.path) else {
                        throw ExecutorError.executionFailed("Conversione fallita per \(inputURL.lastPathComponent): \(result.stderr)")
                    }
                }
            }
            return ActionResult(success: true, outputFiles: outputFiles, message: "Convertiti \(outputFiles.count) video in \(fileExtension.uppercased())")
        } catch {
            throw ActionExecutionError(underlying: error, partialResult: ActionResult(success: false, outputFiles: outputFiles, message: nil))
        }
    }
    
    static func ffmpegScaleFilter(for quality: Int) -> String {
        let bounds: String
        if quality < 40 { bounds = "640:480" }
        else if quality < 70 { bounds = "960:540" }
        else if quality < 90 { bounds = "1280:720" }
        else { bounds = "1920:1080" }
        return "scale=\(bounds):force_original_aspect_ratio=decrease:force_divisible_by=2"
    }

    private static func arguments(inputURL: URL, outputURL: URL, quality: Int) -> [String] {
        ["-i", inputURL.path, "-c:v", "libx264", "-preset", "medium",
         "-vf", ffmpegScaleFilter(for: quality), "-c:a", "aac", "-b:a", "128k", "-y", outputURL.path]
    }

    private static func containerFormat(for raw: String) throws -> String {
        let format = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard ["mp4", "mov"].contains(format) else {
            throw ExecutorError.validationFailed("Formato video non supportato: \(raw). Usa mp4 o mov.")
        }
        return format
    }
}

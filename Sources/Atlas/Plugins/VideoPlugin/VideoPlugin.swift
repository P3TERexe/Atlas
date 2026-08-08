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

// MARK: - Shared input resolution

enum VideoResolver {
    static let videoExtensions: Set<String> = MediaFormats.video
    
    static func resolveInputURLs(step: ActionStep, context: FinderContext) -> [URL] {
        guard let currentDirectory = context.currentDirectory else { return [] }
        
        let matchingSelected = context.selectedFiles.filter { url in
            videoExtensions.contains(url.pathExtension.lowercased())
        }
        
        if !matchingSelected.isEmpty {
            let selectedNames = Set(matchingSelected.map { $0.lastPathComponent })
            let stepInputNames = Set(step.inputs)
            if step.inputs.isEmpty || !stepInputNames.isDisjoint(with: selectedNames) {
                return matchingSelected
            }
        }
        
        if !step.inputs.isEmpty {
            return step.inputs.compactMap { inputPath in
                let url = currentDirectory.appendingPathComponent(inputPath)
                return FileManager.default.fileExists(atPath: url.path) ? url : nil
            }
        }
        
        guard let contents = try? FileManager.default.contentsOfDirectory(at: currentDirectory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else {
            return []
        }
        
        return contents.filter { url in
            videoExtensions.contains(url.pathExtension.lowercased())
        }
    }
    
    static func validateNonEmpty(step: ActionStep, context: FinderContext) throws {
        guard !resolveInputURLs(step: step, context: context).isEmpty else {
            throw ExecutorError.validationFailed("Nessun file video trovato nella cartella o tra i file selezionati.")
        }
    }
    
    static func uniqueURL(in directory: URL, baseName: String, extensionName: String) -> URL {
        var candidate = directory.appendingPathComponent(baseName + "." + extensionName)
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = directory.appendingPathComponent(baseName + "-\(counter)." + extensionName)
            counter += 1
        }
        return candidate
    }
}

// MARK: - Extract Audio

final class ExtractAudioAction: ActionExecutor {
    func validate(step: ActionStep, context: FinderContext) throws {
        try VideoResolver.validateNonEmpty(step: step, context: context)
    }
    
    func shellCommands(step: ActionStep, context: FinderContext) -> [String]? {
        let inputs = VideoResolver.resolveInputURLs(step: step, context: context)
        guard !inputs.isEmpty, let directory = context.currentDirectory else { return nil }
        
        let format = (step.format?.lowercased() ?? "m4a")
        
        return inputs.map { inputURL in
            let outputURL = VideoResolver.uniqueURL(
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
    
    func execute(step: ActionStep, context: FinderContext) async throws -> ActionResult {
        let inputs = VideoResolver.resolveInputURLs(step: step, context: context)
        guard let directory = context.currentDirectory else {
            throw ExecutorError.executionFailed("Cartella corrente non disponibile.")
        }
        
        let format = step.format?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "m4a"
        
        var outputFiles: [URL] = []
        
        for inputURL in inputs {
            let outputURL = VideoResolver.uniqueURL(
                in: directory,
                baseName: inputURL.deletingPathExtension().lastPathComponent + "-audio",
                extensionName: format == "mp3" ? "mp3" : "m4a"
            )
            
            if format == "mp3" {
                guard let ffmpeg = Self.ffmpegBinary() else {
                    throw ExecutorError.executionFailed("L'estrazione in MP3 richiede ffmpeg. Installa con: brew install ffmpeg")
                }
                let status = try await run(binary: ffmpeg, arguments: [
                    "-i", inputURL.path,
                    "-vn", "-c:a", "libmp3lame", "-q:a", "2",
                    "-y", outputURL.path
                ])
                guard status == 0, FileManager.default.fileExists(atPath: outputURL.path) else {
                    throw ExecutorError.executionFailed("Estrazione MP3 fallita per \(inputURL.lastPathComponent)")
                }
            } else {
                // Try 1: Native AVFoundation passthrough (m4a, no external tools)
                do {
                    try await Self.extractAudioNative(inputURL: inputURL, outputURL: outputURL)
                } catch {
                    // Try 2: ffmpeg fallback (codec audio non compatibile col passthrough)
                    guard let ffmpeg = Self.ffmpegBinary() else {
                        throw error
                    }
                    let status = try await run(binary: ffmpeg, arguments: [
                        "-i", inputURL.path,
                        "-vn", "-c:a", "aac", "-b:a", "192k",
                        "-y", outputURL.path
                    ])
                    guard status == 0, FileManager.default.fileExists(atPath: outputURL.path) else {
                        throw ExecutorError.executionFailed("Estrazione audio fallita per \(inputURL.lastPathComponent)")
                    }
                }
            }
            
            outputFiles.append(outputURL)
        }
        
        return ActionResult(
            success: true,
            outputFiles: outputFiles,
            message: "Estratto l'audio da \(outputFiles.count) video (\(format.uppercased()))"
        )
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
        
        await writer.finishWriting()
        
        guard reader.status == .completed, writer.status == .completed else {
            let readerDetail = reader.error?.localizedDescription ?? reader.status.rawValue.description
            let writerDetail = writer.error?.localizedDescription ?? writer.status.rawValue.description
            throw ExecutorError.executionFailed("Estrazione audio fallita per \(inputURL.lastPathComponent): \(readerDetail) / \(writerDetail)")
        }
    }
    
    private static func ffmpegBinary() -> String? {
        for path in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"] {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }
    
    private func run(binary: String, arguments: [String]) async throws -> Int32 {
        let result = try await AsyncProcessRunner.run(executableURL: URL(fileURLWithPath: binary), arguments: arguments)
        return result.exitCode
    }
}

// MARK: - Convert Video

final class ConvertVideoAction: ActionExecutor {
    func validate(step: ActionStep, context: FinderContext) throws {
        try VideoResolver.validateNonEmpty(step: step, context: context)
    }
    
    func shellCommands(step: ActionStep, context: FinderContext) -> [String]? {
        let inputs = VideoResolver.resolveInputURLs(step: step, context: context)
        guard !inputs.isEmpty, let directory = context.currentDirectory else { return nil }
        
        let format = (step.format?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? "mp4").replacingOccurrences(of: ".", with: "")
        let scale = Self.ffmpegScale(for: step.quality ?? 75)
        
        return inputs.map { inputURL in
            let outputURL = VideoResolver.uniqueURL(
                in: directory,
                baseName: inputURL.deletingPathExtension().lastPathComponent,
                extensionName: format
            )
            return "ffmpeg -i \(inputURL.path) -c:v libx264 -preset medium \(scale) -c:a aac -b:a 128k -y \(outputURL.path)"
        }
    }
    
    func execute(step: ActionStep, context: FinderContext) async throws -> ActionResult {
        let inputs = VideoResolver.resolveInputURLs(step: step, context: context)
        guard let directory = context.currentDirectory else {
            throw ExecutorError.executionFailed("Cartella corrente non disponibile.")
        }
        guard let ffmpeg = Self.ffmpegBinary() else {
            throw ExecutorError.executionFailed("La conversione video richiede ffmpeg. Installa con: brew install ffmpeg")
        }
        
        let quality = step.quality ?? 75
        let scale = Self.ffmpegScale(for: quality)
        let containerFormat = Self.containerFormat(for: step.format ?? "mp4")
        let fileExtension = containerFormat == "mov" ? "mov" : "mp4"
        
        var outputFiles: [URL] = []
        var converted = 0
        
        for inputURL in inputs {
            let outputURL = VideoResolver.uniqueURL(
                in: directory,
                baseName: inputURL.deletingPathExtension().lastPathComponent,
                extensionName: fileExtension
            )
            
            let status = try await run(binary: ffmpeg, arguments: [
                "-i", inputURL.path,
                "-c:v", "libx264", "-preset", "medium", scale,
                "-c:a", "aac", "-b:a", "128k",
                "-y", outputURL.path
            ])
            guard status == 0, FileManager.default.fileExists(atPath: outputURL.path) else {
                throw ExecutorError.executionFailed("Conversione fallita per \(inputURL.lastPathComponent)")
            }
            outputFiles.append(outputURL)
            converted += 1
        }
        
        return ActionResult(
            success: true,
            outputFiles: outputFiles,
            message: "Convertiti \(converted) video in \(fileExtension.uppercased())"
        )
    }
    
    private static func ffmpegScale(for quality: Int) -> String {
        if quality < 40 { return "-vf scale=640:480" }
        if quality < 70 { return "-vf scale=960:540" }
        if quality < 90 { return "-vf scale=1280:720" }
        return "-vf scale=1920:1080"
    }
    
    private static func containerFormat(for raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: ".", with: "")
    }
    
    private static func ffmpegBinary() -> String? {
        for path in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"] {
            if FileManager.default.fileExists(atPath: path) {
                return path
            }
        }
        return nil
    }
    
    private func run(binary: String, arguments: [String]) async throws -> Int32 {
        let result = try await AsyncProcessRunner.run(executableURL: URL(fileURLWithPath: binary), arguments: arguments)
        return result.exitCode
    }
}

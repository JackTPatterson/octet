#if DEBUG
import AppKit
import AVFoundation

/// Verification hooks for the transcript's T3 Code features, opened with
/// OCTET_OPEN_WINDOW=conversation:transcript (or transcript-quote,
/// transcript-output, transcript-diff). Nothing reaches an agent.
enum TranscriptDebug {
    static let quotedPassage = "the backoff doubles after every failed attempt"
    static let outputItemId = "tx-bash"

    /// Sample media on disk, for the inline previews.
    static func mediaFolder() -> String {
        let folder = NSTemporaryDirectory() + "octet-transcript-debug"
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        return folder
    }

    static func writeImage(to path: String) {
        guard !FileManager.default.fileExists(atPath: path) else { return }
        let image = NSImage(size: NSSize(width: 640, height: 360), flipped: false) { rect in
            NSGradient(starting: NSColor(calibratedRed: 0.18, green: 0.32, blue: 0.75, alpha: 1),
                       ending: NSColor(calibratedRed: 0.55, green: 0.2, blue: 0.62, alpha: 1))?.draw(in: rect, angle: -30)
            let text = "Upload retry · after" as NSString
            text.draw(at: NSPoint(x: 40, y: 160), withAttributes: [
                .font: NSFont.systemFont(ofSize: 40, weight: .semibold), .foregroundColor: NSColor.white,
            ])
            return true
        }
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: URL(fileURLWithPath: path))
    }

    /// A two-second clip of a colour sweep, so the player has something to play.
    static func writeVideo(to path: String) {
        guard !FileManager.default.fileExists(atPath: path),
              let writer = try? AVAssetWriter(outputURL: URL(fileURLWithPath: path), fileType: .mp4) else { return }
        let width = 320, height = 180
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
        ])
        writer.add(input)
        guard writer.startWriting() else { return }
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<48 {
            while !input.isReadyForMoreMediaData { usleep(1000) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                let row = CVPixelBufferGetBytesPerRow(buffer)
                let pixels = base.assumingMemoryBound(to: UInt8.self)
                for y in 0..<height {
                    for x in 0..<width {
                        let offset = y * row + x * 4
                        pixels[offset] = UInt8((x + frame * 6) % 256)      // B
                        pixels[offset + 1] = UInt8((y * 2) % 256)          // G
                        pixels[offset + 2] = UInt8((frame * 5) % 256)      // R
                        pixels[offset + 3] = 255
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 24))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
    }
}

extension AgentSession {
    /// Two finished turns that edit files, run a command with long output,
    /// and reply with a quotable passage, an image and a video.
    func debugLoadTranscriptFeatures() {
        title = "Fix the upload retry"
        let folder = TranscriptDebug.mediaFolder()
        let image = folder + "/retry-after.png"
        let video = folder + "/retry-demo.mp4"
        TranscriptDebug.writeImage(to: image)
        TranscriptDebug.writeVideo(to: video)
        let root = cwd
        let start = Date().addingTimeInterval(-600)

        conversation.appendUser("The upload retry loop never gives up. Fix it, add tests, and show me it working.",
                                id: "tx-user-1")
        let output = (1...60).map { line -> String in
            switch line {
            case 12: return "warning: Uploader.swift:41: 'attempt' was never mutated"
            case 37: return "error: RetryTests.testGivesUp failed (expected 3 attempts, got 4)"
            case 38: return "error: RetryTests.testBacksOff failed (timeout)"
            case 59: return "Executed 24 tests, with 2 failures"
            default: return "Test Case '-[AppTests.Case\(line) test\(line)]' passed (0.00\(line % 10) seconds)."
            }
        }.joined(separator: "\n")
        let reply = """
        The loop now stops after `maxAttempts`, and the backoff doubles after every failed attempt, capped at 30 seconds. \
        I added tests for both.

        Here's the progress bar after the fix: \(image)

        And a short recording of a failed upload retrying: [retry demo](\(video))
        """
        let events: [[String: Any]] = [
            ["type": "assistant", "message": ["id": "tx-a1", "content": [
                ["type": "tool_use", "id": "tx-edit-1", "name": "Edit", "input": [
                    "file_path": root + "/Sources/App/Uploader.swift",
                    "old_string": "while true {\n    attempt = 0\n    try? upload()\n}",
                    "new_string": "while attempt < maxAttempts {\n    attempt += 1\n    if (try? upload()) == true { return }\n    try await backoff(attempt)\n}",
                ]],
                ["type": "tool_use", "id": "tx-edit-2", "name": "MultiEdit", "input": [
                    "file_path": root + "/Sources/App/Retry/Backoff.swift",
                    "edits": [["old_string": "let delay = 1.0", "new_string": "let delay = min(30, pow(2, Double(attempt)))"]],
                ]],
                ["type": "tool_use", "id": "tx-write-1", "name": "Write", "input": [
                    "file_path": root + "/Tests/AppTests/RetryTests.swift",
                    "content": "import XCTest\n@testable import App\n\nfinal class RetryTests: XCTestCase {\n    func testGivesUp() {}\n    func testBacksOff() {}\n}",
                ]],
            ]]],
            ["type": "user", "message": ["content": [
                ["type": "tool_result", "tool_use_id": "tx-edit-1", "content": "Updated"],
                ["type": "tool_result", "tool_use_id": "tx-edit-2", "content": "Updated"],
                ["type": "tool_result", "tool_use_id": "tx-write-1", "content": "Created"],
            ]]],
            ["type": "assistant", "message": ["id": "tx-a2", "content": [
                ["type": "tool_use", "id": TranscriptDebug.outputItemId, "name": "Bash", "input": ["command": "swift test 2>&1 | tail -60"]],
            ]]],
            ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": TranscriptDebug.outputItemId, "content": output]]]],
            ["type": "assistant", "message": ["id": "tx-a3", "content": [["type": "text", "text": reply]]]],
            ["type": "result", "subtype": "success"],
        ]
        for event in events { conversation.apply(event) }

        conversation.appendUser("Also log each retry.", id: "tx-user-2")
        let second: [[String: Any]] = [
            ["type": "assistant", "message": ["id": "tx-b1", "content": [
                ["type": "tool_use", "id": "tx-edit-3", "name": "Edit", "input": [
                    "file_path": root + "/Sources/App/Uploader.swift",
                    "old_string": "    attempt += 1\n",
                    "new_string": "    attempt += 1\n    log.info(\"retry \\(attempt) of \\(maxAttempts)\")\n",
                ]],
            ]]],
            ["type": "user", "message": ["content": [["type": "tool_result", "tool_use_id": "tx-edit-3", "content": "Updated"]]]],
            ["type": "assistant", "message": ["id": "tx-b2", "content": [["type": "text", "text": "Each retry is logged with its attempt number."]]]],
            ["type": "result", "subtype": "success"],
        ]
        for event in second { conversation.apply(event) }
        // Spread the items over ten minutes, as a real conversation's are.
        for index in conversation.items.indices {
            conversation.items[index].createdAt = start.addingTimeInterval(Double(index) * 20)
        }
        conversation.isRunning = false
    }
}
#endif

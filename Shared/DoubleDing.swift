import Foundation

/// Octet's own finished sound: two quick bell strikes, the second a third
/// above the first, so "done" reads as a small cheerful ding-ding rather
/// than a system chime. Synthesised once into a WAV, so the app and the
/// subagent viewer (which plays through `afplay`) share the one file.
enum DoubleDing {
    static let name = "Double Ding"

    static let sampleRate = 44_100
    /// Each strike: its pitch and when it lands.
    static let strikes: [(frequency: Double, start: Double)] = [(1046.5, 0), (1318.5, 0.13)]
    static let duration = 0.95

    /// The WAV on disk, written the first time it's asked for.
    static func fileURL(cache: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]) -> URL? {
        let url = cache.appendingPathComponent("Octet/double-ding-v1.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try wav().write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Mono 16-bit samples of both strikes.
    static func samples() -> [Int16] {
        let count = Int(duration * Double(sampleRate))
        var mix = [Double](repeating: 0, count: count)
        for strike in strikes {
            let first = Int(strike.start * Double(sampleRate))
            for i in first..<count {
                let t = Double(i - first) / Double(sampleRate)
                // A 4 ms attack so the strike doesn't click, then a bell's decay.
                let envelope = min(1, t / 0.004) * exp(-t * 7)
                // The fundamental, a soft octave, and the inharmonic partial
                // that makes it a bell rather than a beep; it dies away first.
                let f = strike.frequency
                let tone = sin(2 * .pi * f * t)
                    + 0.3 * sin(2 * .pi * f * 2 * t) * exp(-t * 6)
                    + 0.18 * sin(2 * .pi * f * 2.76 * t) * exp(-t * 14)
                mix[i] += tone * envelope
            }
        }
        // Headroom for the overlap; quiet enough to sit under the terminal.
        let peak = mix.map(abs).max() ?? 1
        let gain = 0.42 / max(peak, 1e-9)
        return mix.map { Int16(max(-1, min(1, $0 * gain)) * Double(Int16.max)) }
    }

    static func wav() -> Data {
        let samples = samples()
        var data = Data()
        func append<T: FixedWidthInteger>(_ value: T) { withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) } }
        let bytes = UInt32(samples.count * 2)
        data.append(contentsOf: Array("RIFF".utf8)); append(36 + bytes)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8)); append(UInt32(16))
        append(UInt16(1)); append(UInt16(1))  // PCM, mono
        append(UInt32(sampleRate)); append(UInt32(sampleRate * 2))
        append(UInt16(2)); append(UInt16(16))
        data.append(contentsOf: Array("data".utf8)); append(bytes)
        for sample in samples { append(sample) }
        return data
    }
}

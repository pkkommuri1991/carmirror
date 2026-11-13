import XCTest
import AVFoundation
import Network
import ReplayKit

/// Synthetic ReplayKit-like frames.
enum Frames {
    static let clock = CMClockGetHostTimeClock()
    static var now: CMTime { CMClockGetTime(clock) }

    static func make(width: Int = 1170, height: Int = 2532, shade: UInt8 = 128,
                     pts: CMTime = Frames.now,
                     orientation: CGImagePropertyOrientation = .up) -> CMSampleBuffer {
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        let pixel = pb!
        CVPixelBufferLockBaseAddress(pixel, [])
        memset(CVPixelBufferGetBaseAddress(pixel), Int32(shade), CVPixelBufferGetDataSize(pixel))
        CVPixelBufferUnlockBaseAddress(pixel, [])

        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixel, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var buffer: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixel, formatDescription: format!,
                                                 sampleTiming: &timing, sampleBufferOut: &buffer)
        CMSetAttachment(buffer!, key: RPVideoSampleOrientationKey as CFString,
                        value: NSNumber(value: orientation.rawValue),
                        attachmentMode: kCMAttachmentMode_ShouldPropagate)
        return buffer!
    }
}

/// Parsed live.m3u8.
struct Playlist {
    var targetDuration = -1
    var mediaSequence = -1
    var mapURI = ""
    var segments: [(name: String, duration: Double)] = []
    var ended = false

    init(_ text: String) {
        var pending: Double?
        for line in text.split(separator: "\n").map(String.init) {
            if line.hasPrefix("#EXT-X-TARGETDURATION:") { targetDuration = Int(line.dropFirst(22)) ?? -1 }
            else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") { mediaSequence = Int(line.dropFirst(22)) ?? -1 }
            else if line.hasPrefix("#EXT-X-MAP:URI=") { mapURI = line.dropFirst(15).trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            else if line.hasPrefix("#EXTINF:") { pending = Double(line.dropFirst(8).dropLast()) }
            else if line == "#EXT-X-ENDLIST" { ended = true }
            else if !line.hasPrefix("#"), let d = pending { segments.append((line, d)); pending = nil }
        }
    }

    init(contentsOf dir: URL) throws {
        self.init(try String(contentsOf: dir.appendingPathComponent("live.m3u8"), encoding: .utf8))
    }
}

/// Raw HTTP over TCP so we can send requests URLSession would normalise (e.g. "/../").
struct RawHTTP {
    struct Response { var status: Int; var headers: [String: String]; var body: Data }

    static func send(_ request: String, port: UInt16, timeout: TimeInterval = 5) throws -> Response {
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let queue = DispatchQueue(label: "rawhttp")
        let done = DispatchSemaphore(value: 0)
        var received = Data()
        var failure: Error?

        func readMore() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, complete, error in
                if let data { received.append(data) }
                if let error { failure = error; done.signal(); return }
                if complete { done.signal() } else { readMore() }
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in readMore() })
            case .failed(let error), .waiting(let error):
                failure = error; done.signal()
            default: break
            }
        }
        connection.start(queue: queue)
        defer { connection.cancel() }
        guard done.wait(timeout: .now() + timeout) == .success else {
            throw NSError(domain: "RawHTTP", code: -1, userInfo: [NSLocalizedDescriptionKey: "timeout"])
        }
        if let failure, received.isEmpty { throw failure }

        guard let split = received.range(of: Data("\r\n\r\n".utf8)) else {
            throw NSError(domain: "RawHTTP", code: -2, userInfo: [NSLocalizedDescriptionKey: "no header end"])
        }
        let head = String(decoding: received[..<split.lowerBound], as: UTF8.self).components(separatedBy: "\r\n")
        let status = Int(head.first?.split(separator: " ").dropFirst().first ?? "") ?? -1
        var headers: [String: String] = [:]
        for line in head.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 { headers[parts[0].lowercased()] = parts[1] }
        }
        return Response(status: status, headers: headers, body: received[split.upperBound...])
    }

    static func get(_ path: String, port: UInt16, method: String = "GET") throws -> Response {
        try send("\(method) \(path) HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n", port: port)
    }
}

/// Reads a private stored property (for white-box checks on extension state).
func privateValue<T>(_ object: Any, _ name: String) -> T? {
    Mirror(reflecting: object).children.first { $0.label == name }?.value as? T
}

extension XCTestCase {
    func tempDir() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// Feeds frames at ~30 fps for `seconds` (blocking).
    func feed(seconds: Double, _ sink: (CMSampleBuffer) -> Void) {
        let end = Date().addingTimeInterval(seconds)
        var i = 0
        while Date() < end {
            sink(Frames.make(shade: UInt8(i % 255)))
            i += 1
            Thread.sleep(forTimeInterval: 1.0 / 30)
        }
    }
}

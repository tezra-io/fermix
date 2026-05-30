import Foundation
import Darwin

final class RealtimeSocketClient {
    var onEvent: (([String: Any]) -> Void)?
    var onClose: (() -> Void)?

    private static let queueKey = DispatchSpecificKey<UUID>()

    private var fd: Int32 = -1
    private let queue = DispatchQueue(label: "fermix.pet.socket")
    private let queueID = UUID()
    private var readSource: DispatchSourceRead?

    init() {
        queue.setSpecific(key: Self.queueKey, value: queueID)
    }

    var connected: Bool {
        fd >= 0
    }

    func connect(path: String) throws {
        close()

        let socketFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketFD >= 0 else { throw POSIXError(.EIO) }

        do {
            try disableSigPipe(on: socketFD)
        } catch {
            Darwin.close(socketFD)
            throw error
        }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let maxLength = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLength else {
            Darwin.close(socketFD)
            throw POSIXError(.ENAMETOOLONG)
        }

        withUnsafeMutableBytes(of: &addr.sun_path) { destination in
            path.utf8CString.withUnsafeBufferPointer { source in
                destination.copyBytes(from: UnsafeRawBufferPointer(source))
            }
        }

        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { socketAddress in
                Darwin.connect(socketFD, socketAddress, size)
            }
        }

        guard result == 0 else {
            Darwin.close(socketFD)
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        fd = socketFD
        startReading()
        NSLog("FermixPet: realtime socket connected fd=%d path=%@", socketFD, path)
    }

    func send(_ event: [String: Any]) throws {
        try onSocketQueue {
            try sendUnlocked(event)
        }
    }

    func sendAudioChunk(_ data: Data) {
        queue.async { [weak self] in
            guard let self else { return }
            let encoded = data.base64EncodedString()

            do {
                try self.sendUnlocked(["type": "audio_chunk", "audio": encoded])
            } catch {
                NSLog("FermixPet: audio chunk send failed: %@", String(describing: error))
            }
        }
    }

    func close() {
        onSocketQueue {
            closeUnlocked()
        }
    }

    private func sendUnlocked(_ event: [String: Any]) throws {
        guard connected else { throw POSIXError(.ENOTCONN) }
        let data = try JSONSerialization.data(withJSONObject: event, options: [])
        var payload = data
        payload.append(0x0A)

        try payload.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0

            while written < payload.count {
                let sent = Darwin.write(fd, base.advanced(by: written), payload.count - written)

                if sent <= 0 {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }

                written += sent
            }
        }
    }

    private func disableSigPipe(on socketFD: Int32) throws {
        var value: Int32 = 1
        let result = setsockopt(
            socketFD,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &value,
            socklen_t(MemoryLayout<Int32>.size)
        )

        if result != 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func closeUnlocked() {
        readSource?.cancel()
        readSource = nil

        if fd >= 0 {
            NSLog("FermixPet: realtime socket closing fd=%d", fd)
            Darwin.close(fd)
            fd = -1
        }
    }

    private func startReading() {
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        var buffer = Data()

        source.setEventHandler { [weak self] in
            guard let self else { return }
            var chunk = [UInt8](repeating: 0, count: 4096)
            let count = Darwin.read(self.fd, &chunk, chunk.count)

            if count <= 0 {
                let handler = self.onClose
                self.closeUnlocked()
                handler?()
                return
            }

            buffer.append(contentsOf: chunk.prefix(count))
            self.drainLines(from: &buffer)
        }

        readSource = source
        source.resume()
    }

    private func drainLines(from buffer: inout Data) {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[..<newline]
            buffer.removeSubrange(...newline)

            guard !line.isEmpty else { continue }

            if let object = try? JSONSerialization.jsonObject(with: Data(line)),
               let event = object as? [String: Any] {
                if let type = event["type"] as? String, type == "audio_delta" {
                    let chars = (event["audio"] as? String)?.count ?? 0
                    NSLog("FermixPet: realtime event audio_delta chars=%d", chars)
                }
                onEvent?(event)
            }
        }
    }

    private func onSocketQueue<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: Self.queueKey) == queueID {
            return try work()
        }

        return try queue.sync(execute: work)
    }
}

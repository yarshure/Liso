//
//  PacketBuffer.swift
//  Nobel
//
//  Created by apple on 4/5/26.
//
import Foundation
import Network
import os.lock

// MARK: - PacketBuffer Storage

final class _PacketStorage: @unchecked Sendable {
    let base: UnsafeMutableRawPointer
    let capacity: Int

    init(capacity: Int) {
        precondition(capacity >= 0)
        self.capacity = max(capacity, 1) // 避免 0 byte allocate 的边界问题
        self.base = UnsafeMutableRawPointer.allocate(
            byteCount: self.capacity,
            alignment: MemoryLayout<UInt8>.alignment
        )
    }

    deinit {
        base.deallocate()
    }
}

// MARK: - PacketBuffer

public struct PacketBuffer<Content>: @unchecked Sendable {
    private let storage: _PacketStorage

    public let content: Content?
    public private(set) var count: Int

    public var base: UnsafeMutableRawPointer {
        storage.base
    }

    public var capacity: Int {
        storage.capacity
    }

    public var availableSpace: Int {
        capacity - count
    }

    /// 当前有效数据视图，不拷贝
    public var dataBuffer: UnsafeRawBufferPointer {
        UnsafeRawBufferPointer(start: base, count: count)
    }

    /// 转成 Data（会拷贝）
    public var data: Data {
        Data(bytes: base, count: count)
    }

    /// 分配指定容量的空 buffer
    public init(capacity: Int, content: Content? = nil) {
        let storage = _PacketStorage(capacity: capacity)
        self.storage = storage
        self.count = 0
        self.content = content
    }

    /// 从 Data 构造，拷贝一份内容到内部 buffer
    public init(data: Data, content: Content? = nil) {
        let storage = _PacketStorage(capacity: data.count)
        self.storage = storage
        self.count = data.count
        self.content = content

        if !data.isEmpty {
            data.withUnsafeBytes { src in
                guard let srcBase = src.baseAddress else { return }
                memcpy(storage.base, srcBase, data.count)
            }
        }
    }

    /// 从 bytes 拷贝
    public init(copying bytes: UnsafeRawBufferPointer, content: Content? = nil) {
        let storage = _PacketStorage(capacity: bytes.count)
        self.storage = storage
        self.count = bytes.count
        self.content = content

        if let srcBase = bytes.baseAddress, bytes.count > 0 {
            memcpy(storage.base, srcBase, bytes.count)
        }
    }

    /// 追加 Data 到尾部
    public mutating func append(_ data: Data) {
        precondition(data.count <= availableSpace, "PacketBuffer overflow")

        guard !data.isEmpty else { return }

        data.withUnsafeBytes { src in
            guard let srcBase = src.baseAddress else { return }
            memcpy(base.advanced(by: count), srcBase, data.count)
        }

        count += data.count
    }

    /// 追加原始字节
    public mutating func append(_ bytes: UnsafeRawBufferPointer) {
        precondition(bytes.count <= availableSpace, "PacketBuffer overflow")

        guard let srcBase = bytes.baseAddress, bytes.count > 0 else { return }
        memcpy(base.advanced(by: count), srcBase, bytes.count)
        count += bytes.count
    }

    /// 清空有效长度，不释放底层容量
    public mutating func removeAll(keepingCapacity: Bool = true) {
        if keepingCapacity {
            count = 0
        } else {
            self = PacketBuffer(capacity: 0, content: content)
        }
    }
}

// MARK: - Convenience for byte-only payloads

public extension PacketBuffer where Content == Any {
    init(data: Data) {
        self.init(data: data, content: nil)
    }
}

public extension PacketBuffer {
    var isEmpty:Bool {
        return count == 0
    }
}

// MARK: - OutboundAdapter Protocol

public protocol OutboundAdapter: AnyObject, Sendable {
    /// Stable identifier used to look up adapters in the registry.
    var id: String { get }

    /// Establish the upstream connection. Throws on failure.
    func start(with context: OutboundContext) async throws

    /// Send data to the upstream side.
    func send(_ data: PacketBuffer<Any>) async throws

    /// Receive data from the upstream side.
    /// Returns nil when the upstream connection has closed normally.
    func receive() async throws -> PacketBuffer<Any>?

    /// Tear down the upstream connection immediately.
    func close()

        /// Send data to the upstream side.
   func send(_ data: Data) async throws
   func receive() async throws -> Data?
}

// MARK: - Simple lock wrapper

public final class UnfairLock: @unchecked Sendable {
    private var _lock = os_unfair_lock_s()

    public init() {}

    @discardableResult
    public func withLock<T>(_ body: () throws -> T) rethrows -> T {
        os_unfair_lock_lock(&_lock)
        defer { os_unfair_lock_unlock(&_lock) }
        return try body()
    }
}

final class ContinuationGate: @unchecked Sendable {
    private let lock = UnfairLock()
    private var resumed = false

    func tryResume() -> Bool {
        lock.withLock {
            guard !resumed else { return false }
            resumed = true
            return true
        }
    }
}

// MARK: - NWConnection-based Adapter Example

public final class NWOutboundAdapter: OutboundAdapter, @unchecked Sendable {
    public let id: String

    private let host: NWEndpoint.Host
    private let port: NWEndpoint.Port
    private let parameters: NWParameters
    private let lock = UnfairLock()

    private var connection: NWConnection?

    public init(
        id: String,
        host: String,
        port: UInt16,
        parameters: NWParameters = .tcp
    ) {
        self.id = id
        self.host = NWEndpoint.Host(host)
        self.port = NWEndpoint.Port(rawValue: port)!
        self.parameters = parameters
    }

    public func start(with context: OutboundContext) async throws {
        let conn = NWConnection(host: host, port: port, using: parameters)
        let gate = ContinuationGate()

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard gate.tryResume() else { return }
                    cont.resume()

                case .failed(let error):
                    guard gate.tryResume() else { return }
                    cont.resume(throwing: error)

                case .cancelled:
                    guard gate.tryResume() else { return }
                    cont.resume(throwing: CancellationError())

                default:
                    break
                }
            }

            self.lock.withLock {
                self.connection = conn
            }

            conn.start(queue: .global())
        }
    }

    public func send(_ data: PacketBuffer<Any>) async throws {
        let conn = lock.withLock { connection }
        guard let conn else {
            throw NWError.posix(.ENOTCONN)
        }

        let payload = data.data

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                conn.send(content: payload, completion: .contentProcessed { error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                })
            }
        } onCancel: {
            conn.cancel()
        }
    }

    public func receive() async throws -> PacketBuffer<Any>? {
        let conn = lock.withLock { connection }
        guard let conn else { return nil }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<PacketBuffer<Any>?, Error>) in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
                    if let error {
                        cont.resume(throwing: error)
                    } else if let content, !content.isEmpty {
                        cont.resume(returning: PacketBuffer<Any>(data: content))
                    } else if isComplete {
                        cont.resume(returning: nil) // EOF
                    } else {
                        cont.resume(returning: nil)
                    }
                }
            }
        } onCancel: {
            conn.cancel()
        }
    }

    public func close() {
        let conn = lock.withLock { () -> NWConnection? in
            let c = connection
            connection = nil
            return c
        }
        conn?.cancel()
    }

    /// Send data to the upstream side.
    public func send(_ data: Data) async throws {
        guard let conn = lock.withLock({ connection }) else {
            throw SessionError.internalError("send called before start")
        }
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error { cont.resume(throwing: error) }
                else {
                    cont.resume()
                }
            })
        }
    }
    
   public func receive() async throws -> Data?{
        guard let conn = lock.withLock({ connection }) else { return nil }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { cont in
                conn.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { content, _, isComplete, error in
                    if let error {
                        cont.resume(throwing: error)
                    } else if let content, !content.isEmpty {
                        cont.resume(returning: content)
                    } else if isComplete {
                        cont.resume(returning: nil)   // EOF
                    } else {
                        // intermediate, call again
                        cont.resume(returning: nil)
                    }
                }
            }
        } onCancel: {
            conn.cancel()
        }
    }
}

public extension PacketBuffer where Content == Any {
    func prefix(_ maxLength: Int) -> Data {
        let n = Swift.min(maxLength, count)
        return Data(bytes: base, count: n)
    }

    mutating func removeFirst(_ n: Int) {
        precondition(n >= 0 && n <= count, "removeFirst out of bounds")
        guard n > 0 else { return }

        let remaining = count - n
        if remaining > 0 {
            memmove(base, base.advanced(by: n), remaining)
        }
        count = remaining
    }

    mutating func append(_ other: PacketBuffer<Any>) {
        precondition(other.count <= availableSpace, "PacketBuffer overflow")
        guard other.count > 0 else { return }

        memcpy(base.advanced(by: count), other.base, other.count)
        count += other.count
    }

    func range(of pattern: Data) -> Range<Int>? {
        guard !pattern.isEmpty else { return 0..<0 }
        guard pattern.count <= count else { return nil }

        let haystack = dataBuffer
        return pattern.withUnsafeBytes { pat in
            guard let patBase = pat.baseAddress?.assumingMemoryBound(to: UInt8.self) else {
                return nil
            }

            for i in 0...(count - pattern.count) {
                guard let start = haystack.baseAddress?.advanced(by: i).assumingMemoryBound(to: UInt8.self) else {
                    return nil
                }
                if memcmp(start, patBase, pattern.count) == 0 {
                    return i..<(i + pattern.count)
                }
            }
            return nil
        }
    }
}

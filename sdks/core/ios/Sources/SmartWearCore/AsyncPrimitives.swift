import Foundation

/// Kết quả một lần (giống `CompletableDeferred` trên Android), chờ được với timeout.
/// Mọi thao tác chạy trên MainActor (CoreBluetooth được tạo với queue main).
@MainActor
public final class OneShot<T> {
    private var continuation: CheckedContinuation<T, Error>?
    private var result: Result<T, Error>?
    private var timeoutTask: Task<Void, Never>?

    public init() {}

    public var isCompleted: Bool { result != nil }

    /// Chờ kết quả. Hết `timeout` giây thì thất bại với lỗi do `onTimeout` tạo ra.
    public func wait(timeout: TimeInterval? = nil, onTimeout: @escaping @MainActor () -> Error = { GattError.timeout("") }) async throws -> T {
        if let result { return try result.get() }
        if let timeout {
            timeoutTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                guard !Task.isCancelled else { return }
                self?.fail(onTimeout())
            }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
                if let result {
                    c.resume(with: result)
                } else {
                    continuation = c
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.fail(CancellationError()) }
        }
    }

    public func succeed(_ value: T) { finish(.success(value)) }
    public func fail(_ error: Error) { finish(.failure(error)) }

    private func finish(_ r: Result<T, Error>) {
        guard result == nil else { return }
        result = r
        timeoutTask?.cancel()
        timeoutTask = nil
        let c = continuation
        continuation = nil
        c?.resume(with: r)
    }
}

/// Khoá bất đồng bộ FIFO (giống `Mutex` của kotlinx.coroutines) để tuần tự hoá thao tác GATT.
@MainActor
public final class AsyncLock {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    public func withLock<R>(_ body: () async throws -> R) async rethrows -> R {
        await lock()
        defer { unlock() }
        return try await body()
    }
}

/// Hộp giá trị dùng chung giữa các closure trên MainActor.
@MainActor
public final class Box<T> {
    public var value: T
    public init(_ value: T) { self.value = value }
}

/// Chạy `body`, ném `GattError.timeout` nếu quá `seconds`.
@MainActor
public func withTimeout<R: Sendable>(
    _ seconds: TimeInterval, _ what: String, _ body: @escaping @MainActor () async throws -> R
) async throws -> R {
    try await withThrowingTaskGroup(of: R.self) { group in
        group.addTask { @MainActor in try await body() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw GattError.timeout(what)
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw GattError.timeout(what) }
        return first
    }
}

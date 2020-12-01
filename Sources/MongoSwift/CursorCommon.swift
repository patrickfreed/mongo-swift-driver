import CLibMongoC
import Foundation
import NIO
import NIOConcurrencyHelpers
import SwiftBSON

/// A protocol describing the common public API between cursor-like objects in the driver.
internal protocol CursorProtocol {
    /// The decoded type iterated over by the cursor.
    associatedtype T: Codable

    /**
     * Indicates whether this cursor has the potential to return more data.
     *
     * This method is mainly useful if this cursor is tailable, since in that case `tryNext` may return more results
     * even after returning `nil`.
     *
     * If this cursor is non-tailable, it will always be dead as soon as either `tryNext` returns `nil` or an error.
     *
     * This cursor will be dead as soon as `next` returns `nil` or an error, regardless of the `MongoCursorType`.
     */
    func isAlive() -> EventLoopFuture<Bool>

    /**
     * Get the next `T` from the cursor.
     *
     * If this cursor is tailable, this method will continue retrying until a non-empty batch is returned or the cursor
     * is closed
     */
    func next() -> EventLoopFuture<T?>

    /**
     * Attempt to get the next `T` from the cursor, returning `nil` if there are no results.
     *
     * If this cursor is tailable and `isAlive` is true, this may be called multiple times to attempt to retrieve more
     * elements.
     *
     * If this cursor is a tailable await cursor, it will wait for results server side for a maximum of `maxAwaitTimeMS`
     * before evaluating to `nil`. This option can be configured via options passed to the method that created this
     * cursor (e.g. the `maxAwaitTimeMS` option on the `FindOptions` passed to `find`).
     */
    func tryNext() -> EventLoopFuture<T?>

    /// Retrieves all the documents currently available in this cursor. If the cursor is not tailable, exhausts it. If
    /// the cursor is tailable or is a change stream, this method may return more data if it is called again while the
    /// cursor is still alive.
    func toArray() -> EventLoopFuture<[T]>

    /**
     * Kills this cursor.
     *
     * This method MUST be called before this cursor goes out of scope to prevent leaking resources.
     * This method may be called even if there are unresolved futures created from other `Cursor` methods.
     *
     * This method should not fail.
     */
    func kill() -> EventLoopFuture<Void>
}

extension EventLoopFuture {
    /// Run the provided callback after this future succeeds, preserving the succeeded value.
    internal func afterSuccess(f: @escaping (Value) -> EventLoopFuture<Void>) -> EventLoopFuture<Value> {
        self.flatMap { value in
            f(value).and(value: value)
        }.map { _, value in
            value
        }
    }
}

/// Protocol describing the behavior of a mongoc cursor wrapper.
internal protocol MongocCursorWrapper {
    /// The underlying libmongoc pointer.
    var pointer: OpaquePointer { get }

    /// Indicates whether this type lazily sends its corresponding initial command to the server.
    static var isLazy: Bool { get }

    /// Method wrapping the appropriate libmongoc "error" function (e.g. `mongoc_cursor_error_document`).
    func errorDocument(bsonError: inout bson_error_t, replyPtr: UnsafeMutablePointer<BSONPointer?>) -> Bool

    /// Method wrapping the appropriate libmongoc "next" function (e.g. `mongoc_cursor_next`).
    func next(outPtr: UnsafeMutablePointer<BSONPointer?>) -> Bool

    /// Method wrapping the appropriate libmongoc "more" function (e.g. `mongoc_cursor_more`).
    func more() -> Bool

    /// Method wrapping the appropriate libmongoc "destroy" function (e.g. `mongoc_cursor_destroy`).
    func destroy()
}

internal let ClosedCursorError: Error = MongoError.LogicError(
    message: "Cannot advance a dead cursor or change stream"
)

/// Internal type representing a MongoDB cursor.
internal class Cursor<CursorKind: MongocCursorWrapper> {
    private enum State {
        /// Indicates that the cursor is still open. Stores a `MongocCursorWrapper`, along with the source
        /// connection, and possibly session to ensure they are kept alive as long as the cursor is.
        case open(cursor: CursorKind, connection: Connection, session: ClientSession?)

        /// Indicates the cursor last returned an error from `next`. `nil` will be returned if
        /// `next` is called again, and the cursor will be moved to `closed` state.
        case error

        /// Indicates the cursor has completed iteration, either by exhausting its results or by returning
        /// an error and then `nil`.
        case closed
    }

    /// The state of this cursor.
    private var state: State

    /// Used to store a cached next value to return, if one exists.
    private enum CachedDocument {
        /// Indicates that the associated value is the next value to return. This value may be nil.
        case cached(BSONDocument?)
        /// Indicates that there is no value cached.
        case none

        /// Get the contents of the cache and clear it.
        fileprivate mutating func clear() -> CachedDocument {
            let copy = self
            self = .none
            return copy
        }
    }

    /// Tracks the caching status of this cursor.
    private var cached: CachedDocument

    /// The type of this cursor. Useful for indicating whether or not it is tailable.
    private let type: MongoCursorType

    /// Lock used to synchronize usage of the internal state: specifically the `state` and `cached` properties.
    /// This lock should only be acquired in the bodies of non-private methods.
    private let lock: Lock

    /// Atomic variable used to signal long running operations (e.g. `next(...)`) that the cursor is closing.
    private var isClosing: NIOAtomic<Bool>

    /// Retrieves any error that occurred in mongoc or on the server while iterating the cursor. Returns `nil` if this
    /// cursor is already closed, or if no error occurred.
    ///
    /// This method should only be called while the lock is held.
    private func getMongocError() -> Error? {
        guard case let .open(mongocCursor, _, _) = self.state else {
            return nil
        }

        let replyPtr = UnsafeMutablePointer<BSONPointer?>.allocate(capacity: 1)
        defer {
            replyPtr.deinitialize(count: 1)
            replyPtr.deallocate()
        }

        var error = bson_error_t()
        guard mongocCursor.errorDocument(bsonError: &error, replyPtr: replyPtr) else {
            return nil
        }

        // If a reply is present, it implies the error occurred on the server. This *should* always be a commandError,
        // but we will still parse the mongoc error to cover all cases.
        if let docPtr = replyPtr.pointee {
            do {
                // we have to copy because libmongoc owns the pointer.
                let reply = try BSONDocument(copying: docPtr)
                return extractMongoError(error: error, reply: reply)
            } catch {
                return error
            }
        }

        // Otherwise, the only feasible error is that the user tried to advance a dead cursor,
        // which is a logic error. We will still parse the mongoc error to cover all cases.
        return extractMongoError(error: error)
    }

    /// Retrieves the next document from the `MongocCursor`.
    /// Will close the cursor if the end of the cursor is reached or if an error occurs.
    ///
    /// This method should only be called while the lock is held.
    private func getNextDocument() throws -> BSONDocument? {
        guard case let .open(mongocCursor, _, session) = self.state else {
            throw ClosedCursorError
        }

        if let session = session, !session.active {
            throw ClientSession.SessionInactiveError
        }

        let out = UnsafeMutablePointer<BSONPointer?>.allocate(capacity: 1)
        defer {
            out.deinitialize(count: 1)
            out.deallocate()
        }

        guard mongocCursor.next(outPtr: out) else {
            if let error = self.getMongocError() {
                self.close(fromError: true)
                throw error
            }

            // if we've reached the end of the cursor, close it.
            if !self.type.isTailable || !mongocCursor.more() {
                self.close(fromError: false)
            }

            return nil
        }

        guard let pointee = out.pointee else {
            fatalError("The cursor was advanced, but the document is nil")
        }

        // We have to copy because libmongoc owns the pointer.
        return try BSONDocument(copying: pointee)
    }

    /// Close this cursor
    ///
    /// This method should only be called while the lock is held.
    private func close(fromError: Bool) {
        guard case let .open(mongocCursor, _, _) = self.state else {
            return
        }
        mongocCursor.destroy()

        if fromError {
            self.state = .error
        } else {
            self.state = .closed
        }
    }

    /// This initializer is blocking and should only be run via the executor.
    internal init(
        mongocCursor: CursorKind,
        connection: Connection,
        session: ClientSession?,
        type: MongoCursorType
    ) throws {
        self.state = .open(cursor: mongocCursor, connection: connection, session: session)
        self.type = type
        self.lock = Lock()
        self.isClosing = NIOAtomic.makeAtomic(value: false)
        self.cached = .none

        // If there was an error constructing the cursor, throw it.
        if let error = self.getMongocError() {
            self.close(fromError: true)
            throw error
        }

        // if this type lazily sends its initial command, retrieve and cache the first document so that we start I/O.
        if CursorKind.isLazy {
            self.cached = try .cached(self.tryNext())
        }
    }

    /// Asserts that the cursor was closed.
    deinit {
        assert(!self._isAlive, "cursor or change stream wasn't closed before it went out of scope")
    }

    /// Whether the cursor is alive. This property can block while waiting for the lock and should only be accessed
    /// from within the executor.
    internal var isAlive: Bool {
        self.lock.withLock {
            self._isAlive
        }
    }

    /// Checks whether the cursor is alive. Meant for private use only.
    /// This property should only be read while the lock is held.
    private var _isAlive: Bool {
        if case .cached = self.cached {
            return true
        }

        switch self.state {
        case .open:
            return true
        case .closed, .error:
            return false
        }
    }

    /// Block until a result document is received, an error occurs, or the cursor dies.
    /// This method is blocking and should only be run via the executor.
    internal func next() throws -> BSONDocument? {
        try self.lock.withLock {
            guard self._isAlive else {
                guard case .error = self.state else {
                    throw ClosedCursorError
                }
                self.state = .closed
                return nil
            }

            if case let .cached(result) = self.cached.clear() {
                // If there are no more results forthcoming after clearing the cache, or the cache had a non-nil
                // result in it, return that.
                if !self._isAlive || result != nil {
                    return result
                }
            }

            // Keep trying until either the cursor is killed or a notification has been sent by close
            while self._isAlive && !self.isClosing.load() {
                if let doc = try self.getNextDocument() {
                    return doc
                }
            }
            return nil
        }
    }

    /// Attempt to retrieve a single document from the server, returning nil if there are no results.
    /// This method is blocking and should only be run via the executor.
    internal func tryNext() throws -> BSONDocument? {
        try self.lock.withLock {
            if case let .cached(result) = self.cached.clear() {
                return result
            }
            return try self.getNextDocument()
        }
    }

    /// Retrieve all the currently available documents in the result set.
    /// This will not exhaust the cursor.
    /// This method is blocking and should only be run via the executor.
    internal func toArray() throws -> [BSONDocument] {
        try self.lock.withLock {
            guard self._isAlive else {
                throw ClosedCursorError
            }

            var results: [BSONDocument] = []
            if case let .cached(result) = self.cached.clear(), let unwrappedResult = result {
                results.append(unwrappedResult)
            }
            // the only value left was the cached one
            guard self._isAlive else {
                return results
            }

            while let result = try self.getNextDocument() {
                results.append(result)
            }
            return results
        }
    }

    /// Kill this cursor.
    /// If this cursor is already dead, this method has no effect.
    /// This method is blocking and should only be run via the executor.
    internal func kill() {
        self.isClosing.store(true)
        self.lock.withLock {
            self.cached = .none
            self.close(fromError: false)
        }
        self.isClosing.store(false)
    }

    /// Access the underlying mongoc pointer.
    /// The pointer is guaranteed to be alive for the duration of the closure if it is non-nil.
    /// This method is blocking and should only be run via the executor.
    internal func withUnsafeMongocPointer<T>(_ f: (OpaquePointer?) throws -> T) rethrows -> T {
        try self.lock.withLock {
            guard case let .open(mongocCursor, _, _) = self.state else {
                return try f(nil)
            }
            return try f(mongocCursor.pointer)
        }
    }
}

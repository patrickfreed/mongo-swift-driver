import CLibMongoC
import Foundation

internal typealias BSONPointer = UnsafePointer<bson_t>
internal typealias MutableBSONPointer = UnsafeMutablePointer<bson_t>

extension SwiftBSON.BSONDocument {
    /// Executes the given closure with a read-only, stack-allocated pointer to a bson_t.
    /// The pointer is only valid within the body of the closure and MUST NOT be persisted outside of it.
    internal func withBSONPointer<T>(_ f: (BSONPointer) throws -> T) rethrows -> T {
        var bson = bson_t()
        return try self.buffer.withUnsafeReadableBytes { bufferPtr in
            guard let baseAddrPtr = bufferPtr.baseAddress else {
                fatalError("BSONDocument buffer pointer is null")
            }
            guard bson_init_static(&bson, baseAddrPtr.assumingMemoryBound(to: UInt8.self), bufferPtr.count) else {
                fatalError("failed to initialize read-only bson_t from BSONDocument")
            }
            return try f(&bson)
        }
    }

    /**
     * Copies the data from the given `BSONPointer` into a new `BSONDocument`.
     *
     *  Throws an `MongoError.InternalError` if the bson_t isn't proper BSON.
     */
    internal init(copying bsonPtr: BSONPointer) throws {
        guard let ptr = bson_get_data(bsonPtr) else {
            fatalError("bson_t data is null")
        }
        let bufferPtr = UnsafeBufferPointer(start: ptr, count: Int(bsonPtr.pointee.len))
        do {
            try self.init(fromBSON: Data(bufferPtr))
        } catch {
            throw MongoError.InternalError(message: "failed initializing BSONDocument from bson_t: \(error)")
        }
    }

    /// If the document already has an _id, returns it as-is. Otherwise, returns a new document
    /// containing all the keys from this document, with an _id prepended.
    internal func withID() throws -> SwiftBSON.BSONDocument {
        if self.hasKey("_id") {
            return self
        }

        var idDoc: SwiftBSON.BSONDocument = ["_id": .objectID()]
        for (k, v) in self {
            idDoc[k] = v
        }
        return self
    }

    /**
     * Initializes a `BSONDocument` using an array where the values are optional
     * `BSON`s. Values are stored under a string of their index in the
     * array.
     *
     * - Parameters:
     *   - elements: a `[BSON]`
     *
     * - Returns: a new `BSONDocument`
     */
    internal init(_ values: [SwiftBSON.BSON]) {
        var doc = BSONDocument()
        for (i, value) in values.enumerated() {
            doc["\(i)"] = value
        }
        self = doc
    }
}

/**
 * Executes the given closure with a read-only `BSONPointer` to the provided `BSONDocument` if non-nil.
 * The pointer will only be valid within the body of the closure, and it MUST NOT be persisted outside of it.
 *
 * Use this function rather than optional chaining on `BSONDocument` to guarantee the provided closure is executed.
 */
internal func withOptionalBSONPointer<T>(
    to document: BSONDocument?,
    body: (BSONPointer?) throws -> T
) rethrows -> T {
    guard let doc = document else {
        return try body(nil)
    }
    return try doc.withBSONPointer(body)
}

extension BSONObjectID {
    internal init(bsonOid _: bson_oid_t) {
        fatalError("todo")
    }
}

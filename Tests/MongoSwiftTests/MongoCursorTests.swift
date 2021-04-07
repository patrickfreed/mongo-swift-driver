import Foundation
@testable import MongoSwift
import Nimble
import NIO
import NIOConcurrencyHelpers
import TestsCommon
import XCTest

private let doc1: BSONDocument = ["_id": 1, "x": 1]
private let doc2: BSONDocument = ["_id": 2, "x": 2]
private let doc3: BSONDocument = ["_id": 3, "x": 3]

final class AsyncMongoCursorTests: MongoSwiftTestCase {
    override func setUp() {
        super.setUp()
        self.continueAfterFailure = false
    }

    func testNonTailableCursor() throws {
        try self.withTestNamespace { _, db, coll in
            // query empty collection
            var cursor = try coll.find().wait()
            expect(try cursor.next().wait()).toNot(throwError())
            // cursor should immediately be closed as its empty
            expect(try cursor.isAlive().wait()).to(beFalse())
            // iterating dead cursor should error
            expect(try cursor.next().wait()).to(throwError(errorType: MongoError.LogicError.self))

            // insert and read out one document
            _ = try coll.insertOne(doc1).wait()
            cursor = try coll.find().wait()
            let results = try cursor.toArray().wait()
            expect(results).to(haveCount(1))
            expect(results[0]).to(equal(doc1))
            // cursor should be closed now that its exhausted
            expect(try cursor.isAlive().wait()).to(beFalse())
            // iterating a dead cursor should error
            expect(try cursor.next().wait()).to(throwError())

            cursor = try coll.find(options: FindOptions(batchSize: 1)).wait()
            expect(try cursor.next().wait()).toNot(throwError())

            // run killCursors so next iteration fails on the server
            _ = try db.runCommand(["killCursors": .string(coll.name), "cursors": [.int64(cursor.id!)]]).wait()
            let expectedError = MongoError.CommandError.new(
                code: 43,
                codeName: "CursorNotFound",
                message: "",
                errorLabels: nil
            )
            expect(try cursor.next().wait()).to(throwError(expectedError))
            // cursor should be closed now that it errored
            expect(try cursor.isAlive().wait()).to(beFalse())
        }
    }

    func testTailableAwaitAsyncCursor() throws {
        let collOptions = CreateCollectionOptions(capped: true, max: 3, size: 1000)
        try self.withTestNamespace(collectionOptions: collOptions) { _, _, coll in
            let cursorOpts = FindOptions(batchSize: 1, cursorType: .tailableAwait, maxAwaitTimeMS: 10)
            _ = try coll.insertMany([BSONDocument()]).wait()

            let cursor = try coll.find(options: cursorOpts).wait()
            let doc = try cursor.next().wait()
            expect(doc).toNot(beNil())

            let future = cursor.next()
            _ = try coll.insertMany([BSONDocument()]).wait()
            expect(try future.wait()).toNot(beNil())

            expect(try cursor.tryNext().wait()).to(beNil())

            // start polling and interrupt with close
            let interruptedFuture = cursor.next()
            // ensure the "next" loop is scheduled before the subsequent "kill".
            Thread.sleep(forTimeInterval: 0.25)

            expect(try cursor.kill().wait()).toNot(throwError())
            expect(try interruptedFuture.wait()).to(beNil())
            expect(try cursor.next().wait()).to(throwError(errorType: MongoError.LogicError.self))
        }
    }

    func testTailableAsyncCursor() throws {
        let collOptions = CreateCollectionOptions(capped: true, max: 3, size: 1000)
        try self.withTestNamespace(collectionOptions: collOptions) { _, _, coll in
            let cursorOpts = FindOptions(cursorType: .tailable)

            var cursor = try coll.find(options: cursorOpts).wait()
            expect(try cursor.next().wait()).to(beNil())
            // no documents matched initial query, so cursor is dead
            expect(try cursor.isAlive().wait()).to(beFalse())
            expect(try cursor.next().wait()).to(throwError(errorType: MongoError.LogicError.self))

            // insert a doc so something matches initial query
            _ = try coll.insertOne(doc1).wait()
            cursor = try coll.find(options: cursorOpts).wait()

            // for each doc we insert, check that it arrives in the cursor next,
            // and that the cursor is still alive afterward
            let checkNextResult: (BSONDocument) throws -> Void = { doc in
                let results = try cursor.toArray().wait()
                expect(results).to(haveCount(1))
                expect(results[0]).to(equal(doc))
                expect(try cursor.isAlive().wait()).to(beTrue())
            }
            try checkNextResult(doc1)

            _ = try coll.insertOne(doc2).wait()
            try checkNextResult(doc2)

            _ = try coll.insertOne(doc3).wait()
            try checkNextResult(doc3)

            // no more docs, but should still be alive
            expect(try cursor.tryNext().wait()).to(beNil())
            expect(try cursor.isAlive().wait()).to(beTrue())

            // insert 3 docs so the cursor loses track of its position
            for i in 4..<7 {
                _ = try coll.insertOne(["_id": BSON(i), "x": BSON(i)]).wait()
            }

            let expectedError = MongoError.CommandError.new(
                code: 136,
                codeName: "CappedPositionLost",
                message: "",
                errorLabels: nil
            )
            expect(try cursor.next().wait()).to(throwError(expectedError))
            // cursor should be closed now that it errored
            expect(try cursor.isAlive().wait()).to(beFalse())
            expect(try cursor.next().wait()).to(beNil())

            // iterating dead cursor should error
            expect(try cursor.next().wait()).to(throwError(errorType: MongoError.LogicError.self))
        }
    }

    func testAsyncNext() throws {
        try self.withTestNamespace { _, _, coll in
            // query empty collection
            var cursor = try coll.find().wait()
            expect(try cursor.next().wait()).to(beNil())
            expect(try cursor.isAlive().wait()).to(beFalse())

            // insert a doc so something matches initial query
            _ = try coll.insertOne(doc1).wait()
            cursor = try coll.find().wait()

            let doc = try cursor.next().wait()
            expect(doc).toNot(beNil())
            expect(doc).to(equal(doc1))

            expect(try cursor.next().wait()).to(beNil())
            expect(try cursor.isAlive().wait()).to(beFalse())

            expect(try cursor.next().wait()).to(throwError(errorType: MongoError.LogicError.self))
        }
    }

    func testCursorToArray() throws {
        // normal cursor
        try self.withTestNamespace { _, _, coll in
            // query empty collection
            var cursor = try coll.find().wait()
            expect(try cursor.toArray().wait()).to(equal([]))
            expect(try cursor.isAlive().wait()).to(beFalse())
            // iterating dead cursor should error
            expect(try cursor.next().wait()).to(throwError(errorType: MongoError.LogicError.self))

            // iterating after calling toArray should error.
            _ = try coll.insertMany([doc1, doc2, doc3]).wait()
            cursor = try coll.find().wait()
            var results = try cursor.toArray().wait()
            expect(results).to(equal([doc1, doc2, doc3]))
            // cursor should be closed now that its exhausted
            expect(try cursor.isAlive().wait()).to(beFalse())
            // iterating dead cursor should error
            expect(try cursor.next().wait()).to(throwError(errorType: MongoError.LogicError.self))

            // calling toArray on a closed cursor should error.
            cursor = try coll.find().wait()
            results = try cursor.toArray().wait()
            expect(results).to(haveCount(3))
            expect(try cursor.toArray().wait()).to(throwError())
        }

        // tailable cursor
        let collOptions = CreateCollectionOptions(capped: true, max: 3, size: 1000)
        try self.withTestNamespace(collectionOptions: collOptions) { _, _, coll in
            let cursorOpts = FindOptions(cursorType: .tailable)

            var cursor = try coll.find(options: cursorOpts).wait()
            defer { try? cursor.kill().wait() }

            expect(try cursor.toArray().wait()).to(beEmpty())
            // no documents matched initial query, so cursor is dead
            expect(try cursor.isAlive().wait()).to(beFalse())
            expect(try cursor.next().wait()).to(throwError(errorType: MongoError.LogicError.self))

            // insert a doc so something matches initial query
            _ = try coll.insertOne(doc1).wait()
            cursor = try coll.find(options: cursorOpts).wait()
            expect(try cursor.toArray().wait()).to(equal([doc1]))
            expect(try cursor.isAlive().wait()).to(beTrue())

            // newly inserted docs will be returned by toArray
            _ = try coll.insertMany([doc2, doc3]).wait()
            expect(try cursor.toArray().wait()).to(equal([doc2, doc3]))
            expect(try cursor.isAlive().wait()).to(beTrue())
        }
    }

    func testForEach() throws {
        let count = NIOAtomic<Int>.makeAtomic(value: 0)
        let increment: (BSONDocument) -> Void = { _ in
            _ = count.add(1)
        }

        // non-tailable
        try self.withTestNamespace { _, _, coll in
            // empty collection
            var cursor = try coll.find().wait()
            _ = try cursor.forEach(increment).wait()
            expect(count.load()).to(equal(0))
            expect(try cursor.isAlive().wait()).to(beFalse())

            _ = try coll.insertMany([doc1, doc2]).wait()

            // non empty
            cursor = try coll.find().wait()
            _ = try cursor.forEach(increment).wait()
            expect(count.load()).to(equal(2))
            expect(try cursor.isAlive().wait()).to(beFalse())
        }

        count.store(0)

        // tailable
        let collOptions = CreateCollectionOptions(capped: true, max: 3, size: 1000)
        try self.withTestNamespace(collectionOptions: collOptions) { _, _, coll in
            let cursorOpts = FindOptions(cursorType: .tailable)

            var cursor = try coll.find(options: cursorOpts).wait()
            _ = try cursor.forEach(increment).wait()
            expect(count.load()).to(equal(0))
            // no documents matched initial query, so cursor is dead
            expect(try cursor.isAlive().wait()).to(beFalse())

            _ = try coll.insertMany([doc1, doc2]).wait()
            cursor = try coll.find(options: cursorOpts).wait()

            // start running forEach; future will not resolve since cursor is tailable
            let future = cursor.forEach(increment)
            expect(count.load()).toEventually(equal(2))

            // killing the cursor should resolve the future and not error
            expect(try cursor.kill().wait()).toNot(throwError())
            expect(try future.wait()).toNot(throwError())

            // calling forEach on a dead cursor should error
            expect(try cursor.forEach(increment).wait()).to(throwError(errorType: MongoError.LogicError.self))
        }
    }

    /// Required prose tests for Serverless testing.
    func testCursorId() throws {
        func cursorIdTest(monitor: TestCommandMonitor, observedId: Int64, ns: MongoNamespace) throws {
            let events = monitor.events(withNames: ["find", "killCursors"])
            guard events.count == 4 else {
                XCTFail("expected 4 events, got \(events.count) instead: \(events)")
                return
            }

            expect(events[0].commandName).to(equal("find"))
            expect(events[1].commandName).to(equal("find"))
            guard case let .succeeded(findSucceeded) = events[1] else {
                XCTFail("find succeeded not observed: \(events[1])")
                return
            }
            guard
                let cursorDoc = findSucceeded.reply["cursor"]?.documentValue,
                let findId = cursorDoc["id"]?.toInt64(),
                let namespace = cursorDoc["ns"]?.stringValue
            else {
                XCTFail("find reply missing cursor id or ns: \(findSucceeded.reply)")
                return
            }
            expect(findId).to(equal(observedId))
            expect(namespace).to(equal(ns.description))

            expect(events[2].commandName).to(equal("killCursors"))
            guard case let .started(killCursorsStarted) = events[2] else {
                XCTFail("killCursors started event not observed: \(events[2])")
                return
            }
            expect(killCursorsStarted.databaseName).to(equal(ns.db))
            expect(killCursorsStarted.command["$db"]?.stringValue).to(equal(ns.db))
            expect(killCursorsStarted.command["killCursors"]?.stringValue).to(equal(ns.collection))
            expect(killCursorsStarted.command["cursors"]?.arrayValue).to(equal([.int64(findId)]))

            expect(events[3].commandName).to(equal("killCursors"))
            guard case let .succeeded(killCursorsSucceeded) = events[3] else {
                XCTFail("killCursors succeeded event not observed: \(events[3])")
                return
            }
            expect(killCursorsSucceeded.reply["cursorsKilled"]).to(equal([.int64(findId)]))
        }

        // test after just initial find
        try self.withTestNamespace { client, _, coll in
            _ = try coll.insertMany([["x": 1], ["x": 2], ["x": 3]]).wait()

            let monitor = client.addCommandMonitor()
            var observedId: Int64 = 0

            try monitor.captureEvents {
                // use batchSize of 1 so the cursor has to use multiple batches and will have an id
                let options = FindOptions(batchSize: 1)
                let cursorWithId = try coll.find(options: options).wait()
                defer { try? cursorWithId.kill().wait() }
                expect(cursorWithId.id).toNot(beNil())
                observedId = cursorWithId.id!
            }

            let cursorNoId = try coll.find().wait()
            defer { try? cursorNoId.kill().wait() }
            expect(cursorNoId.id).to(beNil())

            try cursorIdTest(monitor: monitor, observedId: observedId, ns: coll.namespace)
        }

        // test after one getMore
        try self.withTestNamespace { client, _, coll in
            _ = try coll.insertMany([["x": 1], ["x": 2], ["x": 3]]).wait()

            let monitor = client.addCommandMonitor()
            var observedId: Int64 = 0

            try monitor.captureEvents {
                // use batchSize of 1 so the cursor has to use multiple batches and will have an id
                let options = FindOptions(batchSize: 1)
                let cursorWithId = try coll.find(options: options).wait()
                defer { try? cursorWithId.kill().wait() }
                expect(cursorWithId.id).toNot(beNil())
                observedId = cursorWithId.id!
                expect(try cursorWithId.next().wait()).toNot(beNil())
            }

            try cursorIdTest(monitor: monitor, observedId: observedId, ns: coll.namespace)
        }
    }
}

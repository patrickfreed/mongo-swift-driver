import MongoSwiftSync
import Nimble
import TestsCommon

/// A enumeration of the different objects a `TestOperation` may be performed against.
enum TestOperationObject: Decodable {
    case client
    case database
    case collection
    case gridfsbucket
    case testRunner
    case session(String)

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        switch rawValue {
        case "client":
            self = .client
        case "database":
            self = .database
        case "collection":
            self = .collection
        case "gridfsbucket":
            self = .gridfsbucket
        case "testRunner":
            self = .testRunner
        default:
            self = .session(rawValue)
        }
    }
}

/// Struct containing an operation and an expected outcome.
struct TestOperationDescription: Decodable {
    /// The operation to run.
    let operation: AnyTestOperation

    /// The object to perform the operation on.
    let object: TestOperationObject

    /// The return value of the operation, if any.
    let result: TestOperationResult?

    /// Whether the operation should expect an error.
    let error: Bool?

    /// The parameters to pass to the database used for this operation.
    let databaseOptions: DatabaseOptions?

    /// The parameters to pass to the collection used for this operation.
    let collectionOptions: CollectionOptions?

    /// Present only when the operation is `runCommand`. The name of the command to run.
    let commandName: String?

    public enum CodingKeys: String, CodingKey {
        case object, result, error, databaseOptions, collectionOptions, commandName = "command_name"
    }

    public init(from decoder: Decoder) throws {
        self.operation = try AnyTestOperation(from: decoder)

        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.object = try container.decode(TestOperationObject.self, forKey: .object)
        self.result = try container.decodeIfPresent(TestOperationResult.self, forKey: .result)
        self.error = try container.decodeIfPresent(Bool.self, forKey: .error)
        self.databaseOptions = try container.decodeIfPresent(DatabaseOptions.self, forKey: .databaseOptions)
        self.collectionOptions = try container.decodeIfPresent(CollectionOptions.self, forKey: .collectionOptions)
        self.commandName = try container.decodeIfPresent(String.self, forKey: .commandName)
    }

    // swiftlint:disable cyclomatic_complexity

    /// Runs the operation and asserts its results meet the expectation.
    func validateExecution<T: SpecTest>(
        test: inout T,
        client: MongoClient,
        dbName: String,
        collName: String?,
        sessions: [String: ClientSession]
    ) throws {
        let database = client.db(dbName, options: self.databaseOptions)
        var collection: MongoCollection<Document>?

        if let collName = collName {
            collection = database.collection(collName, options: self.collectionOptions)
        }

        do {
            let result: TestOperationResult?
            switch self.object {
            case .client:
                result = try self.operation.op.execute(on: client, sessions: sessions)
            case .database:
                result = try self.operation.op.execute(on: database, sessions: sessions)
            case .collection:
                guard let collection = collection else {
                    throw TestError(message: "got collection object but was not provided a collection")
                }
                result = try self.operation.op.execute(on: collection, sessions: sessions)
            case let .session(sessionName):
                guard let session = sessions[sessionName] else {
                    throw TestError(message: "got session object but was not provided a session")
                }
                result = try self.operation.op.execute(on: session)
            case .testRunner:
                result = try self.operation.op.execute(on: &test, sessions: sessions)
            case .gridfsbucket:
                throw TestError(message: "gridfs tests should be skipped")
            }

            expect(self.error ?? false)
                .to(beFalse(), description: "expected to fail but succeeded with result \(String(describing: result))")
            if let expectedResult = self.result {
                expect(result).to(match(expectedResult))
            }
        } catch {
            if case let .error(expectedErrorResult) = self.result {
                try expectedErrorResult.checkErrorResult(error)
            } else {
                expect(self.error ?? false).to(beTrue(), description: "expected no error, got \(error)")
            }
        }
    }

    // swiftlint:enable cyclomatic_complexity
}

/// Protocol describing the behavior of a spec test "operation"
protocol TestOperation: Decodable {
    func execute(on client: MongoClient, sessions: [String: ClientSession]) throws -> TestOperationResult?

    func execute(on database: MongoDatabase, sessions: [String: ClientSession]) throws -> TestOperationResult?

    func execute(
        on collection: MongoCollection<Document>,
        sessions: [String: ClientSession]
    ) throws -> TestOperationResult?

    func execute(on session: ClientSession) throws -> TestOperationResult?

    func execute<T: SpecTest>(on runner: inout T, sessions: [String: ClientSession]) throws -> TestOperationResult?
}

extension TestOperation {
    func execute(on _: MongoClient, sessions _: [String: ClientSession]) throws -> TestOperationResult? {
        throw TestError(message: "\(type(of: self)) cannot execute on a client")
    }

    func execute(on _: MongoDatabase, sessions _: [String: ClientSession]) throws -> TestOperationResult? {
        throw TestError(message: "\(type(of: self)) cannot execute on a database")
    }

    func execute(
        on _: MongoCollection<Document>,
        sessions _: [String: ClientSession]
    ) throws -> TestOperationResult? {
        throw TestError(message: "\(type(of: self)) cannot execute on a collection")
    }

    func execute(on _: ClientSession) throws -> TestOperationResult? {
        throw TestError(message: "\(type(of: self)) cannot execute on a session")
    }

    func execute<T: SpecTest>(on _: inout T, sessions _: [String: ClientSession]) throws -> TestOperationResult? {
        throw TestError(message: "\(type(of: self)) cannot execute on a test runner")
    }
}

/// Wrapper around a `TestOperation.swift` allowing it to be decoded from a spec test.
struct AnyTestOperation: Decodable {
    let op: TestOperation

    private enum CodingKeys: String, CodingKey {
        case name, arguments
    }

    // swiftlint:disable:next cyclomatic_complexity
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let opName = try container.decode(String.self, forKey: .name)

        switch opName {
        case "aggregate":
            self.op = try container.decode(Aggregate.self, forKey: .arguments)
        case "countDocuments":
            self.op = try container.decode(CountDocuments.self, forKey: .arguments)
        case "estimatedDocumentCount":
            self.op = EstimatedDocumentCount()
        case "distinct":
            self.op = try container.decode(Distinct.self, forKey: .arguments)
        case "find":
            self.op = try container.decode(Find.self, forKey: .arguments)
        case "findOne":
            self.op = try container.decode(FindOne.self, forKey: .arguments)
        case "updateOne":
            self.op = try container.decode(UpdateOne.self, forKey: .arguments)
        case "updateMany":
            self.op = try container.decode(UpdateMany.self, forKey: .arguments)
        case "insertOne":
            self.op = try container.decode(InsertOne.self, forKey: .arguments)
        case "insertMany":
            self.op = try container.decode(InsertMany.self, forKey: .arguments)
        case "deleteOne":
            self.op = try container.decode(DeleteOne.self, forKey: .arguments)
        case "deleteMany":
            self.op = try container.decode(DeleteMany.self, forKey: .arguments)
        case "bulkWrite":
            self.op = try container.decode(BulkWrite.self, forKey: .arguments)
        case "findOneAndDelete":
            self.op = try container.decode(FindOneAndDelete.self, forKey: .arguments)
        case "findOneAndReplace":
            self.op = try container.decode(FindOneAndReplace.self, forKey: .arguments)
        case "findOneAndUpdate":
            self.op = try container.decode(FindOneAndUpdate.self, forKey: .arguments)
        case "replaceOne":
            self.op = try container.decode(ReplaceOne.self, forKey: .arguments)
        case "rename":
            self.op = try container.decode(RenameCollection.self, forKey: .arguments)
        case "startTransaction":
            self.op = (try container.decodeIfPresent(StartTransaction.self, forKey: .arguments)) ?? StartTransaction()
        case "createCollection":
            self.op = try container.decode(CreateCollection.self, forKey: .arguments)
        case "dropCollection":
            self.op = try container.decode(DropCollection.self, forKey: .arguments)
        case "createIndex":
            self.op = try container.decode(CreateIndex.self, forKey: .arguments)
        case "runCommand":
            self.op = try container.decode(RunCommand.self, forKey: .arguments)
        case "assertCollectionExists":
            self.op = try container.decode(AssertCollectionExists.self, forKey: .arguments)
        case "assertCollectionNotExists":
            self.op = try container.decode(AssertCollectionNotExists.self, forKey: .arguments)
        case "assertIndexExists":
            self.op = try container.decode(AssertIndexExists.self, forKey: .arguments)
        case "assertIndexNotExists":
            self.op = try container.decode(AssertIndexNotExists.self, forKey: .arguments)
        case "assertSessionPinned":
            self.op = try container.decode(AssertSessionPinned.self, forKey: .arguments)
        case "assertSessionUnpinned":
            self.op = try container.decode(AssertSessionUnpinned.self, forKey: .arguments)
        case "assertSessionTransactionState":
            self.op = try container.decode(AssertSessionTransactionState.self, forKey: .arguments)
        case "targetedFailPoint":
            self.op = try container.decode(TargetedFailPoint.self, forKey: .arguments)
        case "drop":
            self.op = Drop()
        case "listDatabaseNames":
            self.op = ListDatabaseNames()
        case "listDatabases":
            self.op = ListDatabases()
        case "listDatabaseObjects":
            self.op = ListMongoDatabases()
        case "listIndexes":
            self.op = ListIndexes()
        case "listIndexNames":
            self.op = ListIndexNames()
        case "listCollections":
            self.op = ListCollections()
        case "listCollectionObjects":
            self.op = ListMongoCollections()
        case "listCollectionNames":
            self.op = ListCollectionNames()
        case "watch":
            self.op = Watch()
        case "commitTransaction":
            self.op = CommitTransaction()
        case "abortTransaction":
            self.op = AbortTransaction()
        case "mapReduce", "download_by_name", "download", "count":
            self.op = NotImplemented(name: opName)
        default:
            throw TestError(message: "unsupported op name \(opName)")
        }
    }
}

struct Aggregate: TestOperation {
    let session: String?
    let pipeline: [Document]
    let options: AggregateOptions

    private enum CodingKeys: String, CodingKey { case session, pipeline }

    init(from decoder: Decoder) throws {
        self.options = try AggregateOptions(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.session = try container.decodeIfPresent(String.self, forKey: .session)
        self.pipeline = try container.decode([Document].self, forKey: .pipeline)
    }

    func execute(
        on collection: MongoCollection<Document>,
        sessions: [String: ClientSession]
    ) throws -> TestOperationResult? {
        try TestOperationResult {
            try collection.aggregate(self.pipeline, options: self.options, session: sessions[self.session ?? ""])
        }
    }
}

struct CountDocuments: TestOperation {
    let session: String?
    let filter: Document
    let options: CountDocumentsOptions

    private enum CodingKeys: String, CodingKey { case session, filter }

    init(from decoder: Decoder) throws {
        self.options = try CountDocumentsOptions(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.session = try container.decodeIfPresent(String.self, forKey: .session)
        self.filter = try container.decode(Document.self, forKey: .filter)
    }

    func execute(
        on collection: MongoCollection<Document>,
        sessions: [String: ClientSession]
    ) throws -> TestOperationResult? {
        try TestOperationResult {
            try collection.countDocuments(self.filter, options: self.options, session: sessions[self.session ?? ""])
        }
    }
}

struct Distinct: TestOperation {
    let session: String?
    let fieldName: String
    let filter: Document?
    let options: DistinctOptions

    private enum CodingKeys: String, CodingKey { case session, fieldName, filter }

    init(from decoder: Decoder) throws {
        self.options = try DistinctOptions(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.session = try container.decodeIfPresent(String.self, forKey: .session)
        self.fieldName = try container.decode(String.self, forKey: .fieldName)
        self.filter = try container.decodeIfPresent(Document.self, forKey: .filter)
    }

    func execute(
        on collection: MongoCollection<Document>,
        sessions: [String: ClientSession]
    ) throws -> TestOperationResult? {
        let result = try collection.distinct(
            fieldName: self.fieldName,
            filter: self.filter ?? [:],
            options: self.options,
            session: sessions[self.session ?? ""]
        )
        return .array(result)
    }
}

struct Find: TestOperation {
    let session: String?
    let filter: Document
    let options: FindOptions

    private enum CodingKeys: String, CodingKey { case session, filter }

    init(from decoder: Decoder) throws {
        self.options = try FindOptions(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.session = try container.decodeIfPresent(String.self, forKey: .session)
        self.filter = (try container.decodeIfPresent(Document.self, forKey: .filter)) ?? Document()
    }

    func execute(
        on collection: MongoCollection<Document>,
        sessions: [String: ClientSession]
    ) throws -> TestOperationResult? {
        try TestOperationResult {
            try collection.find(self.filter, options: self.options, session: sessions[self.session ?? ""])
        }
    }
}

struct FindOne: TestOperation {
    let session: String?
    let filter: Document
    let options: FindOneOptions

    private enum CodingKeys: String, CodingKey { case session, filter }

    init(from decoder: Decoder) throws {
        self.options = try FindOneOptions(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.session = try container.decodeIfPresent(String.self, forKey: .session)
        self.filter = try container.decode(Document.self, forKey: .filter)
    }

    func execute(
        on collection: MongoCollection<Document>,
        sessions: [String: ClientSession]
    ) throws -> TestOperationResult? {
        try TestOperationResult {
            try collection.findOne(self.filter, options: self.options, session: sessions[self.session ?? ""])
        }
    }
}

struct UpdateOne: TestOperation {
    let session: String?
    let filter: Document
    let update: Document
    let options: UpdateOptions

    private enum CodingKeys: String, CodingKey { case session, filter, update }

    init(from decoder: Decoder) throws {
        self.options = try UpdateOptions(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.session = try container.decodeIfPresent(String.self, forKey: .session)
        self.filter = try container.decode(Document.self, forKey: .filter)
        self.update = try container.decode(Document.self, forKey: .update)
    }

    func execute(
        on collection: MongoCollection<Document>,
        sessions: [String: ClientSession]
    ) throws -> TestOperationResult? {
        try TestOperationResult { () -> UpdateResult? in
            let update = try collection.updateOne(
                filter: self.filter,
                update: self.update,
                options: self.options,
                session: sessions[self.session ?? ""]
            )
            return update
        }
    }
}

struct UpdateMany: TestOperation {
    let session: String?
    let filter: Document
    let update: Document
    let options: UpdateOptions

    private enum CodingKeys: String, CodingKey { case session, filter, update }

    init(from decoder: Decoder) throws {
        self.options = try UpdateOptions(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.session = try container.decodeIfPresent(String.self, forKey: .session)
        self.filter = try container.decode(Document.self, forKey: .filter)
        self.update = try container.decode(Document.self, forKey: .update)
    }

    func execute(
        on collection: MongoCollection<Document>,
        sessions: [String: ClientSession]
    ) throws -> TestOperationResult? {
        try TestOperationResult {
            try collection.updateMany(
                filter: self.filter,
                update: self.update,
                options: self.options,
                session: sessions[self.session ?? ""]
            )
        }
    }
}

struct DeleteMany: TestOperation {
    let session: String?
    let filter: Document
    let options: DeleteOptions

    private enum CodingKeys: String, CodingKey { case session, filter }

    init(from decoder: Decoder) throws {
        self.options = try DeleteOptions(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.session = try container.decodeIfPresent(String.self, forKey: .session)
        self.filter = try container.decode(Document.self, forKey: .filter)
    }

    func execute(
        on collection: MongoCollection<Document>,
        sessions: [String: ClientSession]
    ) throws -> TestOperationResult? {
        try TestOperationResult {
            try collection.deleteMany(self.filter, options: self.options, session: sessions[self.session ?? ""])
        }
    }
}

struct DeleteOne: TestOperation {
    let session: String?
    let filter: Document
    let options: DeleteOptions

    private enum CodingKeys: String, CodingKey { case session, filter }

    init(from decoder: Decoder) throws {
        self.options = try DeleteOptions(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.session = try container.decodeIfPresent(String.self, forKey: .session)
        self.filter = try container.decode(Document.self, forKey: .filter)
    }

    func execute(
        on collection: MongoCollection<Document>,
        sessions: [String: ClientSession]
    ) throws -> TestOperationResult? {
        try TestOperationResult {
            try collection.deleteOne(self.filter, options: self.options, session: sessions[self.session ?? ""])
        }
    }
}

struct InsertOne: TestOperation {
    let session: String?
    let document: Document

    func execute(
        on collection: MongoCollection<Document>,
        sessions: [String: ClientSession]
    ) throws -> TestOperationResult? {
        try TestOperationResult {
            try collection.insertOne(self.document, session: sessions[self.session ?? ""])
        }
    }
}

struct InsertMany: TestOperation {
    let session: String?
    let documents: [Document]
    let options: InsertManyOptions?

    func execute(
        on collection: MongoCollection<Document>,
        sessions: [String: ClientSession]
    ) throws -> TestOperationResult? {
        try TestOperationResult {
            try collection.insertMany(
                self.documents,
                options: self.options,
                session: sessions[self.session ?? ""]
            )
        }
    }
}

/// Extension of `WriteModel` adding `Decodable` conformance.
extension WriteModel: Decodable {
    private enum CodingKeys: CodingKey {
        case name, arguments
    }

    private enum InsertOneKeys: CodingKey {
        case session, document
    }

    private enum DeleteKeys: CodingKey {
        case session, filter
    }

    private enum ReplaceOneKeys: CodingKey {
        case session, filter, replacement
    }

    private enum UpdateKeys: CodingKey {
        case session, filter, update
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let name = try container.decode(String.self, forKey: .name)

        switch name {
        case "insertOne":
            let args = try container.nestedContainer(keyedBy: InsertOneKeys.self, forKey: .arguments)
            let doc = try args.decode(CollectionType.self, forKey: .document)
            self = .insertOne(doc)
        case "deleteOne", "deleteMany":
            let options = try container.decode(DeleteModelOptions.self, forKey: .arguments)
            let args = try container.nestedContainer(keyedBy: DeleteKeys.self, forKey: .arguments)
            let filter = try args.decode(Document.self, forKey: .filter)
            self = name == "deleteOne" ? .deleteOne(filter, options: options) : .deleteMany(filter, options: options)
        case "replaceOne":
            let options = try container.decode(ReplaceOneModelOptions.self, forKey: .arguments)
            let args = try container.nestedContainer(keyedBy: ReplaceOneKeys.self, forKey: .arguments)
            let filter = try args.decode(Document.self, forKey: .filter)
            let replacement = try args.decode(CollectionType.self, forKey: .replacement)
            self = .replaceOne(filter: filter, replacement: replacement, options: options)
        case "updateOne", "updateMany":
            let options = try container.decode(UpdateModelOptions.self, forKey: .arguments)
            let args = try container.nestedContainer(keyedBy: UpdateKeys.self, forKey: .arguments)
            let filter = try args.decode(Document.self, forKey: .filter)
            let update = try args.decode(Document.self, forKey: .update)
            self = name == "updateOne" ?
                .updateOne(filter: filter, update: update, options: options) :
                .updateMany(filter: filter, update: update, options: options)
        default:
            throw DecodingError.typeMismatch(
                WriteModel.self,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "Unknown write model: \(name)"
                )
            )
        }
    }
}

struct BulkWrite: TestOperation {
    let session: String?
    let requests: [WriteModel<Document>]
    let options: BulkWriteOptions?

    func execute(
        on collection: MongoCollection<Document>,
        sessions: [String: ClientSession]
    ) throws -> TestOperationResult? {
        try TestOperationResult {
            try collection.bulkWrite(self.requests, options: self.options, session: sessions[self.session ?? ""])
        }
    }
}

struct FindOneAndUpdate: TestOperation {
    let session: String?
    let filter: Document
    let update: Document
    let options: FindOneAndUpdateOptions

    private enum CodingKeys: String, CodingKey { case session, filter, update }

    init(from decoder: Decoder) throws {
        self.options = try FindOneAndUpdateOptions(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.session = try container.decodeIfPresent(String.self, forKey: .session)
        self.filter = try container.decode(Document.self, forKey: .filter)
        self.update = try container.decode(Document.self, forKey: .update)
    }

    func execute(
        on collection: MongoCollection<Document>,
        sessions: [String: ClientSession]
    ) throws -> TestOperationResult? {
        try TestOperationResult {
            try collection.findOneAndUpdate(
                filter: self.filter,
                update: self.update,
                options: self.options,
                session: sessions[self.session ?? ""]
            )
        }
    }
}

struct FindOneAndDelete: TestOperation {
    let session: String?
    let filter: Document
    let options: FindOneAndDeleteOptions

    private enum CodingKeys: String, CodingKey { case session, filter }

    init(from decoder: Decoder) throws {
        self.options = try FindOneAndDeleteOptions(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.session = try container.decodeIfPresent(String.self, forKey: .session)
        self.filter = try container.decode(Document.self, forKey: .filter)
    }

    func execute(
        on collection: MongoCollection<Document>,
        sessions: [String: ClientSession]
    ) throws -> TestOperationResult? {
        try TestOperationResult {
            try collection.findOneAndDelete(
                self.filter,
                options: self.options,
                session: sessions[self.session ?? ""]
            )
        }
    }
}

struct FindOneAndReplace: TestOperation {
    let session: String?
    let filter: Document
    let replacement: Document
    let options: FindOneAndReplaceOptions

    private enum CodingKeys: String, CodingKey { case session, filter, replacement }

    init(from decoder: Decoder) throws {
        self.options = try FindOneAndReplaceOptions(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.session = try container.decodeIfPresent(String.self, forKey: .session)
        self.filter = try container.decode(Document.self, forKey: .filter)
        self.replacement = try container.decode(Document.self, forKey: .replacement)
    }

    func execute(
        on collection: MongoCollection<Document>,
        sessions: [String: ClientSession]
    ) throws -> TestOperationResult? {
        try TestOperationResult {
            try collection.findOneAndReplace(
                filter: self.filter,
                replacement: self.replacement,
                options: self.options,
                session: sessions[self.session ?? ""]
            )
        }
    }
}

struct ReplaceOne: TestOperation {
    let session: String?
    let filter: Document
    let replacement: Document
    let options: ReplaceOptions

    private enum CodingKeys: String, CodingKey { case session, filter, replacement }

    init(from decoder: Decoder) throws {
        self.options = try ReplaceOptions(from: decoder)
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.session = try container.decodeIfPresent(String.self, forKey: .session)
        self.filter = try container.decode(Document.self, forKey: .filter)
        self.replacement = try container.decode(Document.self, forKey: .replacement)
    }

    func execute(
        on collection: MongoCollection<Document>,
        sessions: [String: ClientSession]
    ) throws -> TestOperationResult? {
        try TestOperationResult {
            try collection.replaceOne(
                filter: self.filter,
                replacement: self.replacement,
                options: self.options,
                session: sessions[self.session ?? ""]
            )
        }
    }
}

struct RenameCollection: TestOperation {
    let session: String?
    let to: String

    func execute(
        on collection: MongoCollection<Document>,
        sessions: [String: ClientSession]
    ) throws -> TestOperationResult? {
        try TestOperationResult {
            let databaseName = collection.namespace.db
            let cmd: Document = [
                "renameCollection": .string(databaseName + "." + collection.name),
                "to": .string(databaseName + "." + self.to)
            ]
            return try collection._client.db("admin").runCommand(cmd, session: sessions[self.session ?? ""])
        }
    }
}

struct Drop: TestOperation {
    func execute(
        on collection: MongoCollection<Document>,
        sessions _: [String: ClientSession]
    ) throws -> TestOperationResult? {
        try collection.drop()
        return nil
    }
}

struct ListDatabaseNames: TestOperation {
    func execute(on client: MongoClient, sessions _: [String: ClientSession]) throws -> TestOperationResult? {
        try .array(client.listDatabaseNames().map { .string($0) })
    }
}

struct ListIndexes: TestOperation {
    func execute(
        on collection: MongoCollection<Document>,
        sessions _: [String: ClientSession]
    ) throws -> TestOperationResult? {
        try TestOperationResult {
            try collection.listIndexes()
        }
    }
}

struct ListIndexNames: TestOperation {
    func execute(
        on collection: MongoCollection<Document>,
        sessions _: [String: ClientSession]
    ) throws -> TestOperationResult? {
        try .array(collection.listIndexNames().map { .string($0) })
    }
}

struct ListDatabases: TestOperation {
    func execute(on client: MongoClient, sessions _: [String: ClientSession]) throws -> TestOperationResult? {
        try TestOperationResult {
            try client.listDatabases()
        }
    }
}

struct ListMongoDatabases: TestOperation {
    func execute(on client: MongoClient, sessions _: [String: ClientSession]) throws -> TestOperationResult? {
        _ = try client.listMongoDatabases()
        return nil
    }
}

struct ListCollections: TestOperation {
    func execute(on database: MongoDatabase, sessions _: [String: ClientSession]) throws -> TestOperationResult? {
        try TestOperationResult {
            try database.listCollections()
        }
    }
}

struct ListMongoCollections: TestOperation {
    func execute(on database: MongoDatabase, sessions _: [String: ClientSession]) throws -> TestOperationResult? {
        _ = try database.listMongoCollections()
        return nil
    }
}

struct ListCollectionNames: TestOperation {
    func execute(on database: MongoDatabase, sessions _: [String: ClientSession]) throws -> TestOperationResult? {
        try .array(database.listCollectionNames().map { .string($0) })
    }
}

struct Watch: TestOperation {
    func execute(on client: MongoClient, sessions _: [String: ClientSession]) throws -> TestOperationResult? {
        _ = try client.watch()
        return nil
    }

    func execute(on database: MongoDatabase, sessions _: [String: ClientSession]) throws -> TestOperationResult? {
        _ = try database.watch()
        return nil
    }

    func execute(
        on collection: MongoCollection<Document>,
        sessions _: [String: ClientSession]
    ) throws -> TestOperationResult? {
        _ = try collection.watch()
        return nil
    }
}

struct EstimatedDocumentCount: TestOperation {
    func execute(
        on collection: MongoCollection<Document>,
        sessions _: [String: ClientSession]
    ) throws -> TestOperationResult? {
        try .int(collection.estimatedDocumentCount())
    }
}

struct StartTransaction: TestOperation {
    let options: TransactionOptions? = nil

    func execute(on session: ClientSession) throws -> TestOperationResult? {
        try session.startTransaction(options: self.options)
        return nil
    }
}

struct CommitTransaction: TestOperation {
    func execute(on session: ClientSession) throws -> TestOperationResult? {
        try session.commitTransaction()
        return nil
    }
}

struct AbortTransaction: TestOperation {
    func execute(on session: ClientSession) throws -> TestOperationResult? {
        try session.abortTransaction()
        return nil
    }
}

struct CreateCollection: TestOperation {
    let session: String?
    let collection: String

    func execute(on database: MongoDatabase, sessions: [String: ClientSession]) throws -> TestOperationResult? {
        _ = try database.createCollection(self.collection, session: sessions[self.session ?? ""])
        return nil
    }
}

struct DropCollection: TestOperation {
    let session: String?
    let collection: String

    func execute(on database: MongoDatabase, sessions: [String: ClientSession]) throws -> TestOperationResult? {
        _ = try database.collection(self.collection).drop(session: sessions[self.session ?? ""])
        return nil
    }
}

struct CreateIndex: TestOperation {
    let session: String?
    let name: String
    let keys: Document

    func execute(
        on collection: MongoCollection<Document>,
        sessions: [String: ClientSession]
    ) throws -> TestOperationResult? {
        let indexOptions = IndexOptions(name: self.name)
        _ = try collection.createIndex(self.keys, indexOptions: indexOptions, session: sessions[self.session ?? ""])
        return nil
    }
}

struct RunCommand: TestOperation {
    let session: String?
    let command: Document
    let readPreference: ReadPreference?

    func execute(on database: MongoDatabase, sessions: [String: ClientSession]) throws -> TestOperationResult? {
        try TestOperationResult {
            let runCommandOptions = RunCommandOptions(readPreference: self.readPreference)
            return try database.runCommand(
                self.command,
                options: runCommandOptions,
                session: sessions[self.session ?? ""]
            )
        }
    }
}

struct AssertCollectionExists: TestOperation {
    let database: String
    let collection: String

    func execute<T: SpecTest>(on runner: inout T, sessions _: [String: ClientSession]) throws -> TestOperationResult? {
        let client = try MongoClient.makeTestClient()
        let collectionNames = try client.db(self.database).listCollectionNames()
        expect(collectionNames).to(contain(self.collection), description: runner.description)
        return nil
    }
}

struct AssertCollectionNotExists: TestOperation {
    let database: String
    let collection: String

    func execute<T: SpecTest>(on runner: inout T, sessions _: [String: ClientSession]) throws -> TestOperationResult? {
        let client = try MongoClient.makeTestClient()
        let collectionNames = try client.db(self.database).listCollectionNames()
        expect(collectionNames).toNot(contain(self.collection), description: runner.description)
        return nil
    }
}

struct AssertIndexExists: TestOperation {
    let database: String
    let collection: String
    let index: String

    func execute<T: SpecTest>(on runner: inout T, sessions _: [String: ClientSession]) throws -> TestOperationResult? {
        let client = try MongoClient.makeTestClient()
        let indexNames = try client.db(self.database).collection(self.collection).listIndexNames()
        expect(indexNames).to(contain(self.index))
        return nil
    }
}

struct AssertIndexNotExists: TestOperation {
    let database: String
    let collection: String
    let index: String

    func execute<T: SpecTest>(on runner: inout T, sessions _: [String: ClientSession]) throws -> TestOperationResult? {
        let client = try MongoClient.makeTestClient()
        let indexNames = try client.db(self.database).collection(self.collection).listIndexNames()
        expect(indexNames).toNot(contain(self.index))
        return nil
    }
}

struct AssertSessionPinned: TestOperation {
    let session: String

    func execute<T: SpecTest>(on _: inout T, sessions: [String: ClientSession]) throws -> TestOperationResult? {
        guard let session = sessions[self.session] else {
            throw TestError(message: "active session not provided to assertSessionPinned")
        }
        expect(session.isPinned).to(beTrue(), description: "expected \(self.session) to be pinned but it wasn't")
        return nil
    }
}

struct AssertSessionUnpinned: TestOperation {
    let session: String

    func execute<T: SpecTest>(on _: inout T, sessions: [String: ClientSession]) throws -> TestOperationResult? {
        guard let session = sessions[self.session] else {
            throw TestError(message: "active session not provided to assertSessionUnpinned")
        }
        expect(session.isPinned).to(beFalse(), description: "expected \(self.session) to be unpinned but it wasn't")
        return nil
    }
}

struct AssertSessionTransactionState: TestOperation {
    let session: String?
    let state: ClientSession.TransactionState

    func execute<T: SpecTest>(on _: inout T, sessions: [String: ClientSession]) throws -> TestOperationResult? {
        guard let transactionState = sessions[self.session ?? ""]?.transactionState else {
            throw TestError(message: "active session not provided to assertSessionTransactionState")
        }
        expect(transactionState).to(equal(self.state))
        return nil
    }
}

struct TargetedFailPoint: TestOperation {
    let session: String
    let failPoint: FailPoint

    func execute<T: SpecTest>(on runner: inout T, sessions: [String: ClientSession]) throws -> TestOperationResult? {
        guard let session = sessions[self.session], let server = session.serverId else {
            throw TestError(message: "could not get session or session not pinned to mongos")
        }
        try runner.activateFailPoint(self.failPoint, onServer: server)
        print("targeted failpoint \(String(describing: runner.activeFailPoint))")
        return nil
    }
}

/// Dummy `TestOperation` that can be used in place of an unimplemented one (e.g. findOne)
struct NotImplemented: TestOperation {
    internal let name: String
}

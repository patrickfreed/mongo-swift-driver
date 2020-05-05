import Foundation
import MongoSwiftSync
import TestsCommon

// File containing the TestOperations executed on a collections.

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

struct EstimatedDocumentCount: TestOperation {
    func execute(
        on collection: MongoCollection<Document>,
        sessions _: [String: ClientSession]
    ) throws -> TestOperationResult? {
        try .int(collection.estimatedDocumentCount())
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

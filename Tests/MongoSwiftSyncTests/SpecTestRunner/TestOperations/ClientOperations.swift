import MongoSwiftSync

struct ListDatabaseNames: TestOperation {
    func execute(on client: MongoClient, sessions _: [String: ClientSession]) throws -> TestOperationResult? {
        try .array(client.listDatabaseNames().map { .string($0) })
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

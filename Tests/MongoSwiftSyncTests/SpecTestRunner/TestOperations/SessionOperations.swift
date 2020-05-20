import MongoSwiftSync

struct StartTransaction: TestOperation {
    let options: TransactionOptions?

    init() {
        self.options = nil
    }

    func execute(on session: ClientSession, context _: TestOperationExecutionContext) throws -> TestOperationResult? {
        try session.startTransaction(options: self.options)
        return nil
    }
}

struct CommitTransaction: TestOperation {
    func execute(on session: ClientSession, context _: TestOperationExecutionContext) throws -> TestOperationResult? {
        try session.commitTransaction()
        return nil
    }
}

struct AbortTransaction: TestOperation {
    func execute(on session: ClientSession, context _: TestOperationExecutionContext) throws -> TestOperationResult? {
        try session.abortTransaction()
        return nil
    }
}

struct WithTransaction: TestOperation {
    struct Callback: Decodable {
        let operations: [TestOperationDescription]
    }

    let callback: Callback
    let options: TransactionOptions?

    func execute(on session: ClientSession, context _: TestOperationExecutionContext) throws -> TestOperationResult? {
        // try session.withTransaction(options: self.options) {
            
        // }
        return nil
    }
}

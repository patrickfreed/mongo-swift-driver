import Foundation
import MongoSwift
import TestsCommon

/// Struct representing a single test within a spec test JSON file.
private struct ConvenientTransactionsTest: SpecTest {
    let description: String

    let operations: [TestOperationDescription]

    let outcome: TestOutcome?

    let skipReason: String?

    let useMultipleMongoses: Bool?

    let clientOptions: ClientOptions?

    let failPoint: FailPoint?

    let sessionOptions: [String: ClientSessionOptions]?

    let expectations: [TestCommandStartedEvent]?

    var activeFailPoint: FailPoint?

    static let sessionNames: [String] = ["session0", "session1"]

    static let skippedTestKeywords: [String] = []
}

/// Struct representing a single transactions spec test JSON file.
private struct ConvenientTransactionsTestFile: Decodable, SpecTestFile {
    private enum CodingKeys: String, CodingKey {
        case name, runOn, databaseName = "database_name", collectionName = "collection_name", data, tests
    }

    let name: String

    let runOn: [TestRequirement]?

    let databaseName: String

    let collectionName: String?

    let data: TestData

    let tests: [ConvenientTransactionsTest]

    static let skippedTestFileNameKeywords: [String] = []
}

final class ConvenientTransactionsTests: MongoSwiftTestCase {
    override func setUp() {
        self.continueAfterFailure = false
    }

    func testTransactions() throws {
        let tests = try retrieveSpecTestFiles(
          specName: "transactions-convenient-api",
          asType: ConvenientTransactionsTestFile.self
        )
        for (_, testFile) in tests {
            try testFile.runTests()
        }
    }
}

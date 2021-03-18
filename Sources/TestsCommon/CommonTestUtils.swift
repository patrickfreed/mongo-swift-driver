import CLibMongoC
import Foundation
@testable import MongoSwift
import Nimble
import XCTest

extension String {
    /// Removes the first occurrence of the specified substring from the string. If the substring is not present, has
    /// no effect.
    public mutating func removeSubstring(_ s: String) {
        guard s.count <= self.count else {
            return
        }
        for i in 0...(self.count - s.count) {
            let startIdx = self.index(self.startIndex, offsetBy: i)
            let endIdx = self.index(startIdx, offsetBy: s.count)
            if self[startIdx..<endIdx] == s {
                self.removeSubrange(startIdx..<endIdx)
                return
            }
        }
    }
}

extension ConnectionString {
    public func toString() -> String {
        self.withMongocURI { uri in
            String(cString: mongoc_uri_get_string(uri))
        }
    }
}

open class MongoSwiftTestCase: XCTestCase {
    /// Gets the name of the database the test case is running against.
    public class var testDatabase: String {
        "test"
    }

    /// Gets the connection string to use from the environment variable, $MONGODB_URI. If the variable does not exist,
    /// will return a default of "mongodb://127.0.0.1/". If singleMongos is true and this is a sharded topology, will
    /// edit $MONGODB_URI as needed so that it only contains a single host.
    public static func getConnectionString(singleMongos: Bool = true) -> ConnectionString {
        // we only need to manipulate the URI if singleMongos is requested and the topology is sharded.
        guard singleMongos && MongoSwiftTestCase.topologyType == .sharded else {
            return try! ConnectionString(Self.uri)
        }

        let hosts = self.getHosts()
        var output = Self.uri
        // remove all but the first host so we connect to a single mongos.
        for host in hosts[1...] {
            output.removeSubstring(",\(host.description)")
        }
        return try! ConnectionString(output)
    }

    /// Get a connection string for the specified host only.
    public static func getConnectionString(forHost serverAddress: ServerAddress) -> ConnectionString {
        Self.getConnectionStringPerHost().first { $0.hosts!.contains(serverAddress) }!
    }

    /// Returns a different connection string per host specified in MONGODB_URI.
    public static func getConnectionStringPerHost() -> [ConnectionString] {
        let uri = Self.uri

        let regex = try! NSRegularExpression(pattern: #"mongodb:\/\/(?:.*@)?([^\/]+)(?:\/|$)"#)
        let range = NSRange(uri.startIndex..<uri.endIndex, in: uri)
        let match = regex.firstMatch(in: uri, range: range)!

        let hostsRange = Range(match.range(at: 1), in: uri)!

        return try! ConnectionString(uri).hosts!.map { host in
            try! ConnectionString(uri.replacingCharacters(in: hostsRange, with: host.description))
        }
    }

    public static func getHosts() -> [ServerAddress] {
        try! ConnectionString(self.uri).hosts ?? []
    }

    // indicates whether we are running on a 32-bit platform
    public static let is32Bit = MemoryLayout<Int>.size == 4

    /// Generates a unique collection name of the format "<Test Suite>_<Test Name>_<suffix>". If no suffix is provided,
    /// the last underscore is omitted.
    ///
    /// For compatibility with older servers, this name will be truncated so the entire namespace fits in 120
    /// characters. The truncation will ensure the suffix can fit at the end.
    public func getCollectionName(suffix: String? = nil) -> String {
        let name = self.name.replacingOccurrences(of: "[\\[\\]-]", with: "", options: [.regularExpression])
        let maxLen = 120 - Self.testDatabase.count - 1
        if let suf = suffix {
            return name.prefix(maxLen - (suf.count + 1)) + "_" + suf
        } else {
            return name.prefix(maxLen).replacingOccurrences(of: "[ \\+\\$]", with: "_", options: [.regularExpression])
        }
    }

    public func getNamespace(suffix: String? = nil) -> MongoNamespace {
        MongoNamespace(db: Self.testDatabase, collection: self.getCollectionName(suffix: suffix))
    }

    public static var topologyType: TopologyDescription.TopologyType {
        guard let topology = ProcessInfo.processInfo.environment["MONGODB_TOPOLOGY"] else {
            return .single
        }
        return TopologyDescription.TopologyType(from: topology)
    }

    public static var uri: String {
        guard let uri = ProcessInfo.processInfo.environment["MONGODB_URI"] else {
            return "mongodb://127.0.0.1/"
        }
        return uri
    }

    /// Indicates that we are running the tests with SSL enabled, determined by the environment variable $SSL.
    public static var ssl: Bool {
        ProcessInfo.processInfo.environment["SSL"] == "ssl"
    }

    /// Returns the path where the SSL key file is located, determined by the environment variable $SSL_KEY_FILE.
    public static var sslPEMKeyFilePath: String? {
        ProcessInfo.processInfo.environment["SSL_KEY_FILE"]
    }

    /// Returns the path where the SSL CA file is located, determined by the environment variable $SSL_CA_FILE..
    public static var sslCAFilePath: String? {
        ProcessInfo.processInfo.environment["SSL_CA_FILE"]
    }

    /// Indicates that we are running the tests with auth enabled, determined by the environment variable $AUTH.
    public static var auth: Bool {
        ProcessInfo.processInfo.environment["AUTH"] == "auth"
    }

    public static var serverless: Bool {
        ProcessInfo.processInfo.environment["SERVERLESS"] == "serverless"
    }
}

/// Enumerates the different topology configurations that are used throughout the tests
public enum TestTopologyConfiguration: String, Decodable {
    /// A sharded topology where each shard is a standalone.
    case sharded
    /// A replica set.
    case replicaSet = "replicaset"
    /// A sharded topology where each shard is a replica set.
    case shardedReplicaSet = "sharded-replicaset"
    /// A standalone server.
    case single

    /// Returns a Bool indicating whether this topology is either sharded configuration.
    public var isSharded: Bool {
        self == .sharded || self == .shardedReplicaSet
    }

    /// Determines the topologyType of a client based on the reply returned by running an isMaster command and the
    /// first document in the config.shards collection.
    public init(isMasterReply: BSONDocument, shards: [BSONDocument]) throws {
        // Check for symptoms of different topologies
        if isMasterReply["msg"] != "isdbgrid" &&
            isMasterReply["setName"] == nil &&
            isMasterReply["isreplicaset"] != true
        {
            self = .single
        } else if isMasterReply["msg"] == "isdbgrid" {
            guard !shards.isEmpty else {
                self = .shardedReplicaSet
                return
            }
            for shard in shards {
                guard let host = shard["host"]?.stringValue else {
                    throw TestError(message: "config.shards document \(shard) unexpectedly missing host string")
                }
                // If the shard is backed by a single server, this field will contain a single host (e.g.
                // localhost:27017). If the shard is backed by a replica set, this field will contain the name of the
                // replica set followed by a forward slash and a comma-delimited list of hosts.
                let replSetHostRegex = try NSRegularExpression(pattern: #"^.*\/.*:\d+$"#)
                let range = NSRange(host.startIndex..<host.endIndex, in: host)
                guard replSetHostRegex.firstMatch(in: host, range: range) != nil else {
                    self = .sharded
                    return
                }
            }
            self = .shardedReplicaSet
        } else if isMasterReply["ismaster"] == true && isMasterReply["setName"] != nil {
            self = .replicaSet
        } else {
            throw TestError(
                message:
                "Invalid test topology configuration given by isMaster reply: \(isMasterReply) and shards: \(shards)"
            )
        }
    }
}

/// Enumerates different possible unmet requirements that can be returned by meetsRequirements
public enum UnmetRequirement {
    case minServerVersion(actual: ServerVersion, required: ServerVersion)
    case maxServerVersion(actual: ServerVersion, required: ServerVersion)
    case topology(actual: TestTopologyConfiguration, required: [TestTopologyConfiguration])
    case serverless(required: TestRequirement.ServerlessMode)
}

/// Struct representing conditions that a deployment must meet in order for a test file to be run.
public struct TestRequirement: Decodable {
    public enum ServerlessMode: String, Decodable {
        case requireServerless
        case forbidServerless
        case allowServerless
    }

    private let minServerVersion: ServerVersion?
    private let maxServerVersion: ServerVersion?
    private let topologies: [TestTopologyConfiguration]?
    private let serverlessMode: ServerlessMode?

    public static let failCommandSupport: [TestRequirement] = [
        TestRequirement(
            minServerVersion: ServerVersion.mongodFailCommandSupport,
            acceptableTopologies: [.single, .replicaSet]
        ),
        TestRequirement(
            minServerVersion: ServerVersion.mongosFailCommandSupport,
            acceptableTopologies: [.sharded]
        )
    ]

    public init(
        minServerVersion: ServerVersion? = nil,
        maxServerVersion: ServerVersion? = nil,
        acceptableTopologies: [TestTopologyConfiguration]? = nil,
        serverlessMode: ServerlessMode? = nil
    ) {
        self.minServerVersion = minServerVersion
        self.maxServerVersion = maxServerVersion
        self.topologies = acceptableTopologies
        self.serverlessMode = serverlessMode
    }

    /// Determines if the given deployment meets this requirement.
    public func getUnmetRequirement(
        givenCurrent version: ServerVersion,
        _ topology: TestTopologyConfiguration
    ) -> UnmetRequirement? {
        if let minVersion = self.minServerVersion {
            guard minVersion <= version else {
                return .minServerVersion(actual: version, required: minVersion)
            }
        }
        if let maxVersion = self.maxServerVersion {
            guard maxVersion >= version else {
                return .maxServerVersion(actual: version, required: maxVersion)
            }
        }
        if let topologies = self.topologies {
            // When matching a "sharded" topology, test runners MUST accept any type of sharded cluster (i.e. "sharded"
            // implies "sharded-replicaset", but not vice versa).
            guard topologies.contains(topology) ||
                (topology == .shardedReplicaSet && topologies.contains(.sharded))
            else {
                return .topology(actual: topology, required: topologies)
            }

            if let serverlessMode = self.serverlessMode {
                switch serverlessMode {
                case .allowServerless:
                    break
                case .forbidServerless:
                    guard !MongoSwiftTestCase.serverless else {
                        return .serverless(required: serverlessMode)
                    }
                case .requireServerless:
                    guard MongoSwiftTestCase.serverless else {
                        return .serverless(required: serverlessMode)
                    }
                }
            }

            return nil
        }
        return nil
    }

    private enum CodingKeys: String, CodingKey {
        case minServerVersion, maxServerVersion, topology, topologies, serverlessMode
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.minServerVersion = try container.decodeIfPresent(ServerVersion.self, forKey: .minServerVersion)
        self.maxServerVersion = try container.decodeIfPresent(ServerVersion.self, forKey: .maxServerVersion)
        // Some older tests use "topology", but the unified format uses "topologies", so look under both keys.
        if let topologies = try container.decodeIfPresent([TestTopologyConfiguration].self, forKey: .topologies) {
            self.topologies = topologies
        } else if let topologies = try container.decodeIfPresent([TestTopologyConfiguration].self, forKey: .topology) {
            self.topologies = topologies
        } else {
            self.topologies = nil
        }
        self.serverlessMode = try container.decodeIfPresent(ServerlessMode.self, forKey: .serverlessMode)
    }
}

public protocol SortedEquatable {
    func sortedEquals(_ other: Self) -> Bool
}

extension BSONDocument: SortedEquatable {
    public func sortedEquals(_ other: BSONDocument) -> Bool {
        self.equalsIgnoreKeyOrder(other)
    }
}

extension BSON: SortedEquatable {
    public func sortedEquals(_ other: BSON) -> Bool {
        switch (self, other) {
        case let (.document(selfDoc), .document(otherDoc)):
            return selfDoc.sortedEquals(otherDoc)
        case let (.array(selfArr), .array(otherArr)):
            return selfArr.elementsEqual(otherArr) {
                $0.sortedEquals($1)
            }
        default:
            return self == other
        }
    }
}

/// Cleans and normalizes a given JSON string for comparison purposes
private func clean(json: String?) -> String {
    guard let str = json else {
        return ""
    }
    do {
        let doc = try BSONDocument(fromJSON: str.data(using: .utf8)!)
        return doc.toExtendedJSONString()
    } catch {
        print("Failed to clean string: \(str)")
        return String()
    }
}

// Adds a custom "cleanEqual" predicate that compares two JSON strings for equality after normalizing
// them with the "clean" function
public func cleanEqual(_ expectedValue: String?) -> Predicate<String> {
    Predicate.define("cleanEqual <\(stringify(expectedValue))>") { actualExpression, msg in
        let actualValue = try actualExpression.evaluate()
        let matches = clean(json: actualValue) == clean(json: expectedValue) && expectedValue != nil
        if expectedValue == nil || actualValue == nil {
            if expectedValue == nil && actualValue != nil {
                return PredicateResult(
                    status: .fail,
                    message: msg.appendedBeNilHint()
                )
            }
            return PredicateResult(status: .fail, message: msg)
        }
        return PredicateResult(status: PredicateStatus(bool: matches), message: msg)
    }
}

// Adds a custom "sortedEqual" predicate that compares two `Document`s and returns true if they
// have the same key/value pairs in them
public func sortedEqual<T: SortedEquatable>(_ expectedValue: T?) -> Predicate<T> {
    Predicate.define("sortedEqual <\(stringify(expectedValue))>") { actualExpression, msg in
        let actualValue = try actualExpression.evaluate()

        guard let expected = expectedValue, let actual = actualValue else {
            if expectedValue == nil && actualValue != nil {
                return PredicateResult(
                    status: .fail,
                    message: msg.appendedBeNilHint()
                )
            }
            return PredicateResult(status: .fail, message: msg)
        }

        let matches = expected.sortedEquals(actual)
        return PredicateResult(status: PredicateStatus(bool: matches), message: msg)
    }
}

public func failCountAssertion<T>(dataName: String, expectedCount: Int, actual: [T]) {
    XCTFail("Expected \(dataName) to have count \(expectedCount), instead was \(actual.count): \(actual)")
}

public func printSkipMessage(testName: String, reason: String) {
    print("Skipping test case \"\(testName)\": \(reason)")
}

/// Prints a message if a server version or topology requirement is not met and a test is skipped
public func printSkipMessage(
    testName: String,
    unmetRequirement: UnmetRequirement
) {
    let reason: String
    switch unmetRequirement {
    case let .minServerVersion(actual, required):
        reason = "minimum required server version \(required) not met by current server version \(actual)"
    case let .maxServerVersion(actual, required):
        reason = "maximum required server version \(required) not met by current server version \(actual)"
    case let .topology(actual, required):
        reason = "unsupported topology type \(actual), supported topologies are: \(required)"
    case let .serverless(required):
        switch required {
        case .allowServerless:
            fatalError("allowServerless should not cause a test to be skipped")
        case .forbidServerless:
            reason = "this test is not supported by Serverless"
        case .requireServerless:
            reason = "this test must be run against a Serverless instance"
        }
    }
    printSkipMessage(testName: testName, reason: reason)
}

public func unsupportedTopologyMessage(
    testName: String,
    topology: TopologyDescription.TopologyType = MongoSwiftTestCase.topologyType
)
    -> String
{
    "Skipping \(testName) due to unsupported topology type \(topology)"
}

public func unsupportedServerVersionMessage(testName: String) -> String {
    "Skipping \(testName) due to unsupported server version."
}

extension TopologyDescription.TopologyType {
    /// Internal initializer used for translating evergreen config and spec test topologies to a `TopologyType`
    public init(from str: String) {
        switch str {
        case "sharded", "sharded_cluster":
            self = .sharded
        case "replicaset", "replica_set":
            self = .replicaSetWithPrimary
        default:
            self = .single
        }
    }
}

public struct TestError: LocalizedError {
    public let message: String
    public var errorDescription: String { self.message }

    public init(message: String) {
        self.message = message
    }
}

/// Makes `ServerAddress` `Decodable` for the sake of constructing it from spec test files.
extension ServerAddress: Decodable {
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let hostPortPair = try container.decode(String.self)
        try self.init(hostPortPair)
    }
}

extension MongoError.CommandError {
    public static func new(
        code: MongoError.ServerErrorCode,
        codeName: String,
        message: String,
        errorLabels: [String]?
    ) -> MongoError.CommandError {
        MongoError.CommandError(
            code: code,
            codeName: codeName,
            message: message,
            errorLabels: errorLabels
        )
    }
}

extension MongoLabeledError {
    /// Returns whether this error or an error type contained by this error has the provided error label.
    public func hasErrorLabel(_ label: String) -> Bool {
        if self.errorLabels?.contains(label) == true {
            return true
        }

        switch self {
        case let bulk as MongoError.BulkWriteError:
            return bulk.writeConcernFailure?.errorLabels?.contains(label) ??
                (bulk.otherError as? MongoLabeledError)?.hasErrorLabel(label) == true
        case let write as MongoError.WriteError:
            return write.errorLabels?.contains(label) ?? write.writeConcernFailure?.errorLabels?.contains(label) == true
        default:
            return false
        }
    }
}

extension MongoErrorProtocol {
    /// Returns a boolean indicating if this error occurred on the client.
    public var isClientError: Bool {
        self is MongoUserError || self is MongoRuntimeError
    }
}

extension CollectionSpecificationInfo {
    public static func new(readOnly: Bool, uuid: UUID? = nil) -> CollectionSpecificationInfo {
        CollectionSpecificationInfo(readOnly: readOnly, uuid: uuid)
    }
}

extension CollectionSpecification {
    public static func new(
        name: String,
        type: CollectionType,
        options: CreateCollectionOptions?,
        info: CollectionSpecificationInfo,
        idIndex: IndexModel?
    ) -> CollectionSpecification {
        CollectionSpecification(
            name: name,
            type: type,
            options: options,
            info: info,
            idIndex: idIndex
        )
    }
}

extension MongoError.WriteFailure {
    public static func new(
        code: MongoError.ServerErrorCode,
        codeName: String,
        message: String
    ) -> MongoError.WriteFailure {
        MongoError.WriteFailure(code: code, codeName: codeName, message: message)
    }
}

extension MongoError.WriteError {
    public static func new(
        writeFailure: MongoError.WriteFailure?,
        writeConcernFailure: MongoError.WriteConcernFailure?,
        errorLabels: [String]?
    ) -> MongoError.WriteError {
        MongoError.WriteError(
            writeFailure: writeFailure,
            writeConcernFailure: writeConcernFailure,
            errorLabels: errorLabels
        )
    }
}

extension BulkWriteResult {
    public static func new(
        deletedCount: Int? = nil,
        insertedCount: Int? = nil,
        insertedIDs: [Int: BSON]? = nil,
        matchedCount: Int? = nil,
        modifiedCount: Int? = nil,
        upsertedCount: Int? = nil,
        upsertedIDs: [Int: BSON]? = nil
    ) -> BulkWriteResult {
        BulkWriteResult(
            deletedCount: deletedCount ?? 0,
            insertedCount: insertedCount ?? 0,
            insertedIDs: insertedIDs ?? [:],
            matchedCount: matchedCount ?? 0,
            modifiedCount: modifiedCount ?? 0,
            upsertedCount: upsertedCount ?? 0,
            upsertedIDs: upsertedIDs ?? [:]
        )
    }
}

extension MongoError.BulkWriteFailure {
    public static func new(
        code: MongoError.ServerErrorCode,
        codeName: String,
        message: String,
        index: Int
    ) -> MongoError.BulkWriteFailure {
        MongoError.BulkWriteFailure(code: code, codeName: codeName, message: message, index: index)
    }
}

extension MongoError.BulkWriteError {
    public static func new(
        writeFailures: [MongoError.BulkWriteFailure]?,
        writeConcernFailure: MongoError.WriteConcernFailure?,
        otherError: Error?,
        result: BulkWriteResult?,
        errorLabels: [String]?
    ) -> MongoError.BulkWriteError {
        MongoError.BulkWriteError(
            writeFailures: writeFailures,
            writeConcernFailure: writeConcernFailure,
            otherError: otherError,
            result: result,
            errorLabels: errorLabels
        )
    }
}

extension InsertManyResult {
    public static func fromBulkResult(_ result: BulkWriteResult) -> InsertManyResult? {
        InsertManyResult(from: result)
    }
}

protocol JSONLineTransport: AnyObject, Sendable {
    func start() async throws
    func send(_ line: String) async throws
    func receive() async throws -> String
    func stop() async
}

enum JSONLineTransportError: Error, Equatable {
    case notStarted
    case closed
    case invalidUTF8
}

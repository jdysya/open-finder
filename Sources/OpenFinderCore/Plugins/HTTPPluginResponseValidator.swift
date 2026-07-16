import Foundation

enum HTTPPluginResponseValidator {
    static func data(
        _ response: HTTPPluginDataResponse,
        accepted: Set<Int>,
        token: String
    ) throws -> Data {
        guard response.headers["openfinder-plugin-protocol"] == "1" else {
            throw HTTPPluginError.invalidResponse("missing protocol header")
        }
        guard isJSON(response.headers["content-type"]) else {
            throw HTTPPluginError.invalidResponse("JSON Content-Type required")
        }
        guard accepted.contains(response.statusCode) else {
            throw HTTPPluginWire.serverError(response.body, status: response.statusCode, token: token)
        }
        return response.body
    }

    static func stream(_ response: HTTPPluginStreamResponse) throws {
        guard response.headers["openfinder-plugin-protocol"] == "1" else {
            throw HTTPPluginError.invalidResponse("missing protocol header")
        }
        guard response.statusCode == 200 else {
            throw HTTPPluginError.invalidResponse("event stream status \(response.statusCode)")
        }
        guard isEventStream(response.headers["content-type"]) else {
            throw HTTPPluginError.invalidResponse("event-stream Content-Type required")
        }
    }

    static func isJSON(_ value: String?) -> Bool {
        mediaType(value) == "application/json"
    }

    static func isEventStream(_ value: String?) -> Bool {
        mediaType(value) == "text/event-stream"
    }

    private static func mediaType(_ value: String?) -> String? {
        value?.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

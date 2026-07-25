import Foundation

enum SmokeExpectedRoute: String, Sendable, Equatable {
    case nativeAVPlayer
    case avKitProxy
}

struct SmokeConfiguration: Sendable, Equatable {
    static let urlEnvironmentKey = "HYBRID_SMOKE_URL"
    static let headersEnvironmentKey = "HYBRID_SMOKE_HEADERS_JSON"
    static let seekEnvironmentKey = "HYBRID_SMOKE_SEEK_SECONDS"
    static let expectedRouteEnvironmentKey =
        "HYBRID_SMOKE_EXPECTED_ROUTE"
    static let environmentPrefix = "HYBRID_SMOKE_"
    static let defaultSeekSeconds = 10.0

    let sourceURL: URL
    let httpHeaders: [String: String]
    let seekSeconds: Double
    let expectedRoute: SmokeExpectedRoute?

    var displaySource: String {
        if sourceURL.isFileURL {
            return "file://…/\(sourceURL.lastPathComponent)"
        }
        let scheme = sourceURL.scheme ?? "unknown"
        let host = sourceURL.host ?? "unknown-host"
        let filename = sourceURL.lastPathComponent
        if filename.isEmpty {
            return "\(scheme)://\(host)/"
        }
        return "\(scheme)://\(host)/…/\(filename)"
    }

    static func fromEnvironment(
        _ environment: [String: String]
    ) throws -> SmokeConfiguration? {
        let containsSmokeConfiguration = environment.keys.contains {
            $0.hasPrefix(environmentPrefix)
        }
        guard let rawURL = environment[urlEnvironmentKey] else {
            if containsSmokeConfiguration {
                throw SmokeConfigurationError.missingURL
            }
            return nil
        }

        return try make(
            rawURL: rawURL,
            rawHeaders: environment[headersEnvironmentKey] ?? "",
            rawSeekSeconds:
                environment[seekEnvironmentKey]
                ?? String(defaultSeekSeconds),
            rawExpectedRoute:
                environment[expectedRouteEnvironmentKey]
        )
    }

    static func interactive(
        rawURL: String,
        rawHeaders: String,
        rawSeekSeconds: String
    ) throws -> SmokeConfiguration {
        try make(
            rawURL: rawURL,
            rawHeaders: rawHeaders,
            rawSeekSeconds: rawSeekSeconds,
            rawExpectedRoute: nil
        )
    }

    private static func make(
        rawURL: String,
        rawHeaders: String,
        rawSeekSeconds: String,
        rawExpectedRoute: String?
    ) throws -> SmokeConfiguration {
        let sourceURL = try parseURL(rawURL)
        let headers = try parseHeaders(rawHeaders)
        let seekSeconds = try parseSeekSeconds(rawSeekSeconds)

        let expectedRoute: SmokeExpectedRoute?
        if let rawExpectedRoute {
            guard let parsed =
                SmokeExpectedRoute(rawValue: rawExpectedRoute) else {
                throw SmokeConfigurationError.invalidExpectedRoute(
                    rawExpectedRoute
                )
            }
            expectedRoute = parsed
        } else {
            expectedRoute = nil
        }

        return SmokeConfiguration(
            sourceURL: sourceURL,
            httpHeaders: headers,
            seekSeconds: seekSeconds,
            expectedRoute: expectedRoute
        )
    }

    private static func parseURL(_ rawValue: String) throws -> URL {
        let value = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !value.isEmpty else {
            throw SmokeConfigurationError.missingURL
        }
        guard let components = URLComponents(string: value),
              let scheme = components.scheme?.lowercased(),
              ["http", "https", "file"].contains(scheme),
              let url = components.url else {
            throw SmokeConfigurationError.invalidURL
        }
        if scheme == "http" || scheme == "https" {
            guard components.host?.isEmpty == false else {
                throw SmokeConfigurationError.invalidURL
            }
        } else {
            guard url.isFileURL, !url.path.isEmpty else {
                throw SmokeConfigurationError.invalidURL
            }
        }
        return url
    }

    private static func parseHeaders(
        _ rawValue: String
    ) throws -> [String: String] {
        let value = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !value.isEmpty else {
            return [:]
        }
        guard let data = value.data(using: .utf8) else {
            throw SmokeConfigurationError.invalidHeadersJSON
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw SmokeConfigurationError.invalidHeadersJSON
        }
        guard let dictionary = object as? [String: Any] else {
            throw SmokeConfigurationError.invalidHeadersJSON
        }

        var headers: [String: String] = [:]
        for (rawName, rawHeaderValue) in dictionary {
            let name = rawName.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !name.isEmpty,
                  let headerValue = rawHeaderValue as? String else {
                throw SmokeConfigurationError.invalidHeadersJSON
            }
            headers[name] = headerValue
        }
        return headers
    }

    private static func parseSeekSeconds(
        _ rawValue: String
    ) throws -> Double {
        let value = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let seconds = Double(value),
              seconds.isFinite,
              seconds > 0 else {
            throw SmokeConfigurationError.invalidSeekSeconds
        }
        return seconds
    }
}

enum SmokeConfigurationError:
    Error,
    Sendable,
    Equatable,
    LocalizedError
{
    case missingURL
    case invalidURL
    case invalidHeadersJSON
    case invalidSeekSeconds
    case invalidExpectedRoute(String)

    var errorDescription: String? {
        switch self {
        case .missingURL:
            "HYBRID_SMOKE_URL or an interactive media URL is required"
        case .invalidURL:
            "Media URL must be an absolute http, https, or file URL"
        case .invalidHeadersJSON:
            "HTTP headers must be a JSON object with string values"
        case .invalidSeekSeconds:
            "Seek seconds must be finite and greater than zero"
        case .invalidExpectedRoute(let value):
            "Expected route must be nativeAVPlayer or avKitProxy, not \(value)"
        }
    }
}

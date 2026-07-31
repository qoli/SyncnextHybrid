import Foundation

enum SmokePlaybackMode: String, CaseIterable, Sendable, Equatable {
    case aetherEngine
    case hybridAVKit

    var title: String {
        switch self {
        case .aetherEngine:
            "AetherEngine Baseline"
        case .hybridAVKit:
            "Hybrid AVKit"
        }
    }
}

enum SmokeExpectedRoute: String, Sendable, Equatable {
    case nativeAVPlayer
    case avKitProxy
}

struct SmokeConfiguration: Sendable, Equatable {
    static let modeEnvironmentKey = "HYBRID_SMOKE_MODE"
    static let urlEnvironmentKey = "HYBRID_SMOKE_URL"
    static let headersEnvironmentKey = "HYBRID_SMOKE_HEADERS_JSON"
    static let seekEnvironmentKey = "HYBRID_SMOKE_SEEK_SECONDS"
    static let rateEnvironmentKey = "HYBRID_SMOKE_RATE"
    static let expectedRouteEnvironmentKey =
        "HYBRID_SMOKE_EXPECTED_ROUTE"
    static let environmentPrefix = "HYBRID_SMOKE_"
    static let defaultSeekSeconds = 10.0
    static let defaultPlaybackRate: Float = 1

    let mode: SmokePlaybackMode
    let sourceURL: URL
    let httpHeaders: [String: String]
    let seekSeconds: Double
    let playbackRate: Float
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
        guard let rawMode = environment[modeEnvironmentKey] else {
            throw SmokeConfigurationError.missingMode
        }

        return try make(
            rawMode: rawMode,
            rawURL: rawURL,
            rawHeaders: environment[headersEnvironmentKey] ?? "",
            rawSeekSeconds:
                environment[seekEnvironmentKey]
                ?? String(defaultSeekSeconds),
            rawPlaybackRate:
                environment[rateEnvironmentKey]
                ?? String(defaultPlaybackRate),
            rawExpectedRoute:
                environment[expectedRouteEnvironmentKey]
        )
    }

    static func interactive(
        mode: SmokePlaybackMode,
        rawURL: String,
        rawHeaders: String,
        rawSeekSeconds: String
    ) throws -> SmokeConfiguration {
        try make(
            rawMode: mode.rawValue,
            rawURL: rawURL,
            rawHeaders: rawHeaders,
            rawSeekSeconds: rawSeekSeconds,
            rawPlaybackRate: String(defaultPlaybackRate),
            rawExpectedRoute: nil
        )
    }

    private static func make(
        rawMode: String,
        rawURL: String,
        rawHeaders: String,
        rawSeekSeconds: String,
        rawPlaybackRate: String,
        rawExpectedRoute: String?
    ) throws -> SmokeConfiguration {
        guard let mode = SmokePlaybackMode(rawValue: rawMode) else {
            throw SmokeConfigurationError.invalidMode(rawMode)
        }
        let sourceURL = try parseURL(rawURL)
        let headers = try parseHeaders(rawHeaders)
        let seekSeconds = try parseSeekSeconds(rawSeekSeconds)
        let playbackRate = try parsePlaybackRate(rawPlaybackRate)

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
        if mode == .aetherEngine, expectedRoute != nil {
            throw SmokeConfigurationError.expectedRouteRequiresHybrid
        }

        return SmokeConfiguration(
            mode: mode,
            sourceURL: sourceURL,
            httpHeaders: headers,
            seekSeconds: seekSeconds,
            playbackRate: playbackRate,
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

    private static func parsePlaybackRate(
        _ rawValue: String
    ) throws -> Float {
        let value = rawValue.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard let rate = Float(value),
              rate.isFinite,
              rate > 0,
              rate <= 4 else {
            throw SmokeConfigurationError.invalidPlaybackRate
        }
        return rate
    }
}

enum SmokeConfigurationError:
    Error,
    Sendable,
    Equatable,
    LocalizedError
{
    case missingURL
    case missingMode
    case invalidURL
    case invalidMode(String)
    case invalidHeadersJSON
    case invalidSeekSeconds
    case invalidPlaybackRate
    case invalidExpectedRoute(String)
    case expectedRouteRequiresHybrid

    var errorDescription: String? {
        switch self {
        case .missingURL:
            "HYBRID_SMOKE_URL or an interactive media URL is required"
        case .missingMode:
            "HYBRID_SMOKE_MODE is required for automated smoke runs"
        case .invalidURL:
            "Media URL must be an absolute http, https, or file URL"
        case .invalidMode(let value):
            "Playback mode must be aetherEngine or hybridAVKit, not \(value)"
        case .invalidHeadersJSON:
            "HTTP headers must be a JSON object with string values"
        case .invalidSeekSeconds:
            "Seek seconds must be finite and greater than zero"
        case .invalidPlaybackRate:
            "Playback rate must be finite, greater than zero, and at most 4"
        case .invalidExpectedRoute(let value):
            "Expected route must be nativeAVPlayer or avKitProxy, not \(value)"
        case .expectedRouteRequiresHybrid:
            "HYBRID_SMOKE_EXPECTED_ROUTE is valid only in hybridAVKit mode"
        }
    }
}

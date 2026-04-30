import Foundation

/// Parameter set for a single OpenAI image-generation call. Mirrors the
/// `/v1/images/generations` request body for `gpt-image-1`. Discrete
/// enums where the API constrains values; free-form `String` for the
/// model id so `dall-e-3` etc. could be plumbed later without schema
/// surgery.
public struct CloudImageParams: Sendable, Equatable {
    public var model: String
    public var size: Size
    public var quality: Quality
    public var outputFormat: OutputFormat
    public var background: Background
    public var n: Int

    public enum Size: String, Sendable, Equatable, CaseIterable {
        case auto
        case s1024x1024 = "1024x1024"
        case s1536x1024 = "1536x1024"
        case s1024x1536 = "1024x1536"

        /// Pixel width parsed from the raw value. `auto` returns 0
        /// (unknown until generation completes); callers persisting
        /// width/height can read the actual values from the response.
        public var width: Int {
            switch self {
            case .auto: return 0
            case .s1024x1024, .s1024x1536: return 1024
            case .s1536x1024: return 1536
            }
        }
        public var height: Int {
            switch self {
            case .auto: return 0
            case .s1024x1024, .s1536x1024: return 1024
            case .s1024x1536: return 1536
            }
        }

        public var label: String {
            switch self {
            case .auto: return "Auto"
            case .s1024x1024: return "Square (1024×1024)"
            case .s1536x1024: return "Landscape (1536×1024)"
            case .s1024x1536: return "Portrait (1024×1536)"
            }
        }
    }

    public enum Quality: String, Sendable, Equatable, CaseIterable {
        case auto, low, medium, high
    }

    public enum OutputFormat: String, Sendable, Equatable, CaseIterable {
        case png, jpeg, webp
    }

    public enum Background: String, Sendable, Equatable, CaseIterable {
        case auto, transparent, opaque
    }

    public init(
        model: String = "gpt-image-1",
        size: Size = .auto,
        quality: Quality = .auto,
        outputFormat: OutputFormat = .png,
        background: Background = .auto,
        n: Int = 1
    ) {
        self.model = model
        self.size = size
        self.quality = quality
        self.outputFormat = outputFormat
        self.background = background
        self.n = n
    }
}

/// One generated image from a `CloudImageClient.generate(...)` call.
/// `data` is the decoded image bytes (always PNG/JPEG/WebP per the
/// requested `outputFormat`); width/height are populated when the
/// provider returns them in the response, otherwise left at zero so
/// the caller can probe the image bytes for dimensions.
public struct CloudImageResult: Sendable {
    public let data: Data
    public let width: Int
    public let height: Int
    public let revisedPrompt: String?

    public init(data: Data, width: Int = 0, height: Int = 0, revisedPrompt: String? = nil) {
        self.data = data
        self.width = width
        self.height = height
        self.revisedPrompt = revisedPrompt
    }
}

/// Minimal interface the runner sees. One verb today (`generate`); we
/// can add `edit` / `variation` later with default no-op implementations
/// if non-OpenAI backends grow image support.
public protocol CloudImageClient: Sendable {
    func generate(prompt: String, params: CloudImageParams) async throws -> [CloudImageResult]
}

// MARK: - OpenAI

/// Hits `POST /v1/images/generations` for `gpt-image-1`. The model
/// always returns inline base64 bytes — `response_format` is a
/// DALL-E-era parameter that gpt-image-1 explicitly rejects, so we
/// never send it.
public struct OpenAIImageClient: CloudImageClient {
    public let apiKey: String
    public let baseURL: URL
    public let session: URLSession

    public init(
        apiKey: String,
        baseURL: URL = URL(string: "https://api.openai.com")!,
        session: URLSession = CloudClients.sharedSession
    ) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
    }

    public func generate(prompt: String, params: CloudImageParams) async throws -> [CloudImageResult] {
        let url = baseURL.appendingPathComponent("/v1/images/generations")
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = 120
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")

        var body: [String: Any] = [
            "model": params.model,
            "prompt": prompt,
            "n": params.n,
        ]
        if params.size != .auto {
            body["size"] = params.size.rawValue
        } else {
            body["size"] = "auto"
        }
        if params.quality != .auto {
            body["quality"] = params.quality.rawValue
        }
        if params.outputFormat != .png {
            body["output_format"] = params.outputFormat.rawValue
        }
        if params.background != .auto {
            body["background"] = params.background.rawValue
        }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: req)
        try Self.checkHTTP(response: response, body: data, apiKey: apiKey)

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = obj["data"] as? [[String: Any]]
        else {
            throw CloudError.invalidResponse
        }

        var results: [CloudImageResult] = []
        for item in items {
            guard let b64 = item["b64_json"] as? String,
                  let bytes = Data(base64Encoded: b64)
            else { continue }
            results.append(CloudImageResult(
                data: bytes,
                width: params.size.width,
                height: params.size.height,
                revisedPrompt: item["revised_prompt"] as? String
            ))
        }
        if results.isEmpty {
            throw CloudError.invalidResponse
        }
        return results
    }

    /// Verify a 2xx, otherwise scrub the key out of the body and surface
    /// as `CloudError.http`. Distinct from `CloudClients.checkHTTP` —
    /// that one is shaped for SSE streams (drains a bytes iterator).
    /// Image gen returns one body, so this is the simpler single-shot
    /// variant.
    static func checkHTTP(response: URLResponse, body: Data, apiKey: String) throws {
        guard let http = response as? HTTPURLResponse else {
            throw CloudError.invalidResponse
        }
        if (200..<300).contains(http.statusCode) { return }
        let raw = String(data: body, encoding: .utf8) ?? ""
        throw CloudError.http(
            status: http.statusCode,
            body: CloudClients.scrubKey(from: raw, apiKey: apiKey)
        )
    }
}

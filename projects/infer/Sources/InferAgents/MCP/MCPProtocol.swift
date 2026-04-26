import Foundation

/// JSON-RPC 2.0 + MCP wire types used by the in-tree MCP client.
///
/// MCP (Model Context Protocol) is Anthropic's stdio/JSON-RPC protocol for
/// connecting LLM applications to external tools and data sources. This
/// file is the typed view of the wire format the rest of the MCP layer
/// (`MCPTransport`, `MCPClient`, `MCPBuiltinTool`) operates on. Decoding
/// is tolerant — unknown fields are dropped, optional fields default
/// safely — so a server that ships ahead of the spec we coded against
/// still works for the parts we do understand.
///
/// **Scope.** Only what's needed for the v1 tools-only integration:
/// JSON-RPC envelopes, the `initialize` handshake, `tools/list`, and
/// `tools/call`. Resources, prompts, sampling, subscriptions, and
/// roots are out of scope for v1; adding them later is additive (new
/// method names, new payload structs) and won't break callers.
public enum MCP {

    // MARK: - JSON-RPC 2.0 envelopes

    /// Outbound request — id, method, optional params. Encoded with
    /// `params` omitted when nil so a server expecting `params` to be
    /// absent on no-arg methods accepts the message.
    public struct Request: Encodable, Sendable {
        public let jsonrpc: String = "2.0"
        public let id: Int
        public let method: String
        public let params: AnyJSON?

        public init(id: Int, method: String, params: AnyJSON? = nil) {
            self.id = id
            self.method = method
            self.params = params
        }

        private enum CodingKeys: String, CodingKey {
            case jsonrpc, id, method, params
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(jsonrpc, forKey: .jsonrpc)
            try c.encode(id, forKey: .id)
            try c.encode(method, forKey: .method)
            if let params {
                try c.encode(params, forKey: .params)
            }
        }
    }

    /// Outbound notification — like `Request` but no `id` (servers don't
    /// reply). Used for `notifications/initialized` after the handshake.
    public struct Notification: Encodable, Sendable {
        public let jsonrpc: String = "2.0"
        public let method: String
        public let params: AnyJSON?

        public init(method: String, params: AnyJSON? = nil) {
            self.method = method
            self.params = params
        }

        private enum CodingKeys: String, CodingKey {
            case jsonrpc, method, params
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(jsonrpc, forKey: .jsonrpc)
            try c.encode(method, forKey: .method)
            if let params {
                try c.encode(params, forKey: .params)
            }
        }
    }

    /// Inbound response — exactly one of `result` / `error` is non-nil
    /// per spec. We don't enforce that at decode time (defensive: a
    /// non-conformant server shouldn't crash the client); callers
    /// pattern-match on whichever is present.
    public struct Response: Decodable, Sendable {
        public let jsonrpc: String
        public let id: Int?
        public let result: AnyJSON?
        public let error: ErrorObject?
    }

    public struct ErrorObject: Decodable, Sendable, Equatable {
        public let code: Int
        public let message: String
        public let data: AnyJSON?
    }

    // MARK: - MCP method payloads (v1 subset)

    public struct InitializeParams: Encodable, Sendable {
        public let protocolVersion: String
        public let capabilities: ClientCapabilities
        public let clientInfo: ClientInfo

        public init(
            protocolVersion: String,
            capabilities: ClientCapabilities,
            clientInfo: ClientInfo
        ) {
            self.protocolVersion = protocolVersion
            self.capabilities = capabilities
            self.clientInfo = clientInfo
        }
    }

    public struct ClientCapabilities: Encodable, Sendable {
        /// Filesystem-roots capability. Present when the client is
        /// going to respond to inbound `roots/list` requests with a
        /// non-empty list. `listChanged: false` means we don't push
        /// notifications when roots change mid-session — sufficient
        /// for v1 since roots are configured at server launch and
        /// don't drift.
        public let roots: RootsCapability?

        public init(roots: RootsCapability? = nil) {
            self.roots = roots
        }
    }

    public struct RootsCapability: Encodable, Sendable, Equatable {
        public let listChanged: Bool

        public init(listChanged: Bool = false) {
            self.listChanged = listChanged
        }
    }

    /// One filesystem root advertised to the server. `uri` is a
    /// `file://` URI; `name` is an optional human-readable label.
    public struct Root: Encodable, Sendable, Equatable {
        public let uri: String
        public let name: String?

        public init(uri: String, name: String? = nil) {
            self.uri = uri
            self.name = name
        }

        private enum CodingKeys: String, CodingKey { case uri, name }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(uri, forKey: .uri)
            if let name { try c.encode(name, forKey: .name) }
        }
    }

    /// Response payload for an inbound `roots/list` request from the
    /// server. The client sends one back when `roots` are configured.
    public struct ListRootsResult: Encodable, Sendable {
        public let roots: [Root]
        public init(roots: [Root]) { self.roots = roots }
    }

    /// JSON-RPC response envelope the client sends back to the server
    /// when handling an inbound request (e.g. `roots/list`). Same
    /// shape as a JSON-RPC response — `id` echoes the inbound id,
    /// `result` carries the typed payload.
    public struct OutboundResponse<R: Encodable & Sendable>: Encodable, Sendable {
        public let jsonrpc: String = "2.0"
        public let id: Int
        public let result: R

        public init(id: Int, result: R) {
            self.id = id
            self.result = result
        }
    }

    /// JSON-RPC error response envelope for inbound requests we
    /// can't handle (e.g. method not in our v1 set). Mirrors the
    /// inbound `Response.error` shape.
    public struct OutboundErrorResponse: Encodable, Sendable {
        public let jsonrpc: String = "2.0"
        public let id: Int
        public let error: OutboundError

        public init(id: Int, code: Int, message: String) {
            self.id = id
            self.error = OutboundError(code: code, message: message)
        }
    }

    public struct OutboundError: Encodable, Sendable {
        public let code: Int
        public let message: String
    }

    public struct ClientInfo: Encodable, Sendable {
        public let name: String
        public let version: String
        public init(name: String, version: String) {
            self.name = name
            self.version = version
        }
    }

    public struct InitializeResult: Decodable, Sendable {
        public let protocolVersion: String?
        public let serverInfo: ServerInfo?
        // capabilities is tolerated as opaque — we don't gate v1
        // tools-only flow on capability advertising. A server that
        // omits `tools` from capabilities still has tools/list called
        // against it; if it doesn't support tools the call surfaces a
        // standard JSON-RPC error and we degrade gracefully.
    }

    public struct ServerInfo: Decodable, Sendable {
        public let name: String?
        public let version: String?
    }

    /// `tools/list` result. Each tool carries name + description +
    /// optional JSON Schema for the input. We preserve the schema as
    /// `AnyJSON` and don't validate against it — the model is the one
    /// emitting calls and the server is the one validating; the bridge
    /// stays out of the middle.
    public struct ListToolsResult: Decodable, Sendable {
        public let tools: [Tool]
    }

    public struct Tool: Decodable, Sendable, Equatable {
        public let name: String
        public let description: String?
        public let inputSchema: AnyJSON?
    }

    /// `tools/call` result. MCP returns content blocks (text, image,
    /// resource); for v1 we only consume text blocks and concatenate
    /// them. Non-text blocks are ignored with a marker so the model
    /// sees something rather than nothing.
    public struct CallToolResult: Decodable, Sendable {
        public let content: [ContentBlock]?
        public let isError: Bool?
    }

    public struct ContentBlock: Decodable, Sendable {
        public let type: String
        public let text: String?
    }

    /// Encode `tools/call` arguments as a JSON object on the wire.
    /// Accepts the agent layer's raw JSON-string arguments and either
    /// re-parses them into a `[String: AnyJSON]` or sends an empty
    /// object if the model emitted blank/garbled args.
    public struct CallToolParams: Encodable, Sendable {
        public let name: String
        public let arguments: AnyJSON

        public init(name: String, argumentsJSON: String) {
            self.name = name
            // Try to parse; on failure fall back to {} so the server
            // sees a well-formed object (most tools tolerate unknown
            // keys but reject malformed JSON outright).
            if let data = argumentsJSON.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                self.arguments = AnyJSON.fromAny(obj)
            } else {
                self.arguments = .object([:])
            }
        }
    }
}

// MARK: - AnyJSON (typed JSON value)

/// Type-erased JSON value used wherever the wire schema is dynamic
/// (`Request.params`, `Tool.inputSchema`, `Response.result`). Codable
/// + Sendable + Equatable so test assertions and JSON-RPC plumbing
/// share one representation.
///
/// Built explicitly rather than via a third-party `AnyCodable` because
/// the project avoids unnecessary deps and the surface we need is
/// small (six cases, encode + decode).
public indirect enum AnyJSON: Codable, Sendable, Equatable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([AnyJSON])
    case object([String: AnyJSON])

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
        } else if let v = try? c.decode(Bool.self) {
            self = .bool(v)
        } else if let v = try? c.decode(Int.self) {
            self = .int(v)
        } else if let v = try? c.decode(Double.self) {
            self = .double(v)
        } else if let v = try? c.decode(String.self) {
            self = .string(v)
        } else if let v = try? c.decode([AnyJSON].self) {
            self = .array(v)
        } else if let v = try? c.decode([String: AnyJSON].self) {
            self = .object(v)
        } else {
            throw DecodingError.dataCorruptedError(
                in: c, debugDescription: "AnyJSON could not decode value"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let v): try c.encode(v)
        case .int(let v): try c.encode(v)
        case .double(let v): try c.encode(v)
        case .string(let v): try c.encode(v)
        case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v)
        }
    }

    /// Project to the loose `Any` representation `JSONSerialization`
    /// uses. Lets a bridge layer hand a parsed JSON tree to legacy
    /// `Any`-typed call sites without re-stringifying.
    public func toAny() -> Any {
        switch self {
        case .null: return NSNull()
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        case .array(let v): return v.map { $0.toAny() }
        case .object(let v): return v.mapValues { $0.toAny() }
        }
    }

    /// Lift a `JSONSerialization`-style `Any` tree into `AnyJSON`.
    /// `NSNumber` values are coerced to `Int` when they round-trip
    /// exactly (so wire integers don't decay to `Double`); other
    /// numerics fall through to `Double`.
    public static func fromAny(_ value: Any) -> AnyJSON {
        if value is NSNull { return .null }
        if let v = value as? Bool { return .bool(v) }
        if let v = value as? Int { return .int(v) }
        if let v = value as? Double {
            if let asInt = Int(exactly: v) { return .int(asInt) }
            return .double(v)
        }
        if let v = value as? NSNumber {
            // NSNumber covers both Int and Double on Darwin.
            let s = String(cString: v.objCType)
            if s == "i" || s == "l" || s == "q" || s == "s" {
                return .int(v.intValue)
            }
            return .double(v.doubleValue)
        }
        if let v = value as? String { return .string(v) }
        if let v = value as? [Any] { return .array(v.map { AnyJSON.fromAny($0) }) }
        if let v = value as? [String: Any] {
            return .object(v.mapValues { AnyJSON.fromAny($0) })
        }
        return .null
    }
}

// MARK: - Errors

/// Errors raised by the MCP client layer. JSON-RPC error codes are
/// passed through verbatim; transport / framing / timeout failures
/// have their own cases so callers can decide whether to retry.
public enum MCPError: Error, Sendable, Equatable {
    /// Server replied with a JSON-RPC error.
    case rpcError(code: Int, message: String)
    /// We failed to parse a frame or response.
    case decodingFailed(String)
    /// The transport closed before our request was answered.
    case transportClosed
    /// Request sent, no response received within the timeout.
    case timeout
    /// Tried to send before `initialize` completed (or after shutdown).
    case notReady(String)
    /// The server's `tools/call` result carried `isError == true`. The
    /// concatenated text is the error message the model should see.
    case toolErrored(String)
}

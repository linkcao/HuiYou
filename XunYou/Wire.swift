import Foundation

// MARK: - Wire 格式（OpenAI 兼容协议，DeepSeek 直接可用）

struct WireToolCall: Codable, Hashable {
    struct FunctionSpec: Codable, Hashable {
        let name: String
        let arguments: String
    }
    let id: String
    let type: String
    let function: FunctionSpec
}

struct WireMessage: Encodable {
    var role: String
    var content: String? = nil
    var tool_calls: [WireToolCall]? = nil
    var tool_call_id: String? = nil
    var name: String? = nil
}

// MARK: - 请求

struct ChatCompletionRequest: Encodable {
    let model: String
    let messages: [WireMessage]
    let tools: [ToolSchema]
    let tool_choice: String
    let stream: Bool
}

// MARK: - 响应

struct ChatCompletionResponse: Decodable {
    struct Choice: Decodable {
        struct Message: Decodable {
            let role: String?
            let content: String?
            let tool_calls: [WireToolCall]?
        }
        let message: Message
        let finish_reason: String?
    }
    let choices: [Choice]
}

struct ErrorResponse: Decodable {
    struct Err: Decodable { let message: String? }
    let error: Err?
}

// MARK: - Tool 定义（JSON Schema）

struct ToolSchema: Encodable {
    let type = "function"
    let function: FunctionDef
}

struct FunctionDef: Encodable {
    let name: String
    let description: String
    let parameters: Parameters
}

struct Parameters: Encodable {
    let type = "object"
    var properties: [String: SchemaProperty]
    var required: [String]? = nil
}

struct SchemaProperty: Encodable {
    let type: String
    let description: String
    let enumValues: [String]?

    enum CodingKeys: String, CodingKey {
        case type, description
        case enumValues = "enum"
    }

    init(type: String, description: String, enumValues: [String]? = nil) {
        self.type = type
        self.description = description
        self.enumValues = enumValues
    }
}

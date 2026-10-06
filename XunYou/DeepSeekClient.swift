import Foundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - 全局配置

struct AppSettings {
    static let shared = AppSettings()

    var baseURL: String { UserDefaults.standard.string(forKey: "base_url") ?? "https://api.deepseek.com" }
    var model: String { UserDefaults.standard.string(forKey: "model") ?? "deepseek-chat" }
    var apiKey: String { Keychain.get("api_key") ?? "" }

    private init() {}
}

// MARK: - 错误

enum AgentError: LocalizedError {
    case noAPIKey
    case badURL
    case http(Int, String)
    case emptyResponse
    /// 断网
    case offline
    /// 连接被系统掐断（App 切后台 / 锁屏 / 切网络时最常见）
    case connectionLost
    case timeout
    case cancelled
    case other(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return "还没配置 API Key，去「设置」里填一下"
        case .badURL:
            return "Base URL 不合法，去「设置」检查"
        case .http(let code, let msg):
            return "服务端返回 \(code)：\(msg)"
        case .emptyResponse:
            return "模型这次没吐内容，点「重试」再来一次"
        case .offline:
            return "现在好像没网。连上 Wi-Fi 或流量后，点下面的「重试」接着聊。"
        case .connectionLost:
            return "连接被系统断开了（一般是切到后台、锁屏或换了网络）。\n刚才那句我还留着，点「重试」接着来就行，不用重新打。"
        case .timeout:
            return "等太久了（超过 2 分钟）。可能网络慢或者模型在排队，点「重试」再来一次。"
        case .cancelled:
            return "这次请求被取消了。点「重试」可以重新发。"
        case .other(let msg):
            return msg
        }
    }

    /// 把系统抛出来的 URLError 翻成人话（原来直接显示 "The network connection was lost"）
    static func from(_ error: Error) -> AgentError {
        if let e = error as? AgentError { return e }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .networkConnectionLost:
                return .connectionLost
            case .notConnectedToInternet, .cannotConnectToHost, .cannotFindHost, .dataNotAllowed, .internationalRoamingOff:
                return .offline
            case .timedOut:
                return .timeout
            case .cancelled:
                return .cancelled
            default:
                return .other("网络出错：\(urlError.localizedDescription)")
            }
        }
        return .other(error.localizedDescription)
    }

    /// 网络类错误：重试也没意义的情况交给用户决定，别自动重发
    var isNetworkIssue: Bool {
        switch self {
        case .offline, .connectionLost, .timeout, .cancelled: return true
        default: return false
        }
    }
}

// MARK: - 后台保活

#if canImport(UIKit)
/// 给正在进行的 AI 请求争取一点后台时间。
///
/// App 一切到后台，系统很快会挂起进程；连接被掐断时 URLSession 抛的就是
/// `URLError.networkConnectionLost`。`beginBackgroundTask` 能让请求在被挂起前
/// 多活约 30 秒——用户切出去回个消息再回来，这一轮就不会白等。
@MainActor
enum BackgroundAssertion {
    static func begin(_ name: String) -> UIBackgroundTaskIdentifier {
        var id = UIBackgroundTaskIdentifier.invalid
        id = UIApplication.shared.beginBackgroundTask(withName: name) {
            // 系统要回收了：主动结束，避免被强杀
            if id != .invalid {
                UIApplication.shared.endBackgroundTask(id)
                id = .invalid
            }
        }
        return id
    }

    static func end(_ id: UIBackgroundTaskIdentifier) {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
    }
}
#endif

// MARK: - 流式（SSE）解析

/// DeepSeek / OpenAI 兼容的流式分片
struct StreamChunk: Decodable {
    struct Choice: Decodable {
        struct Delta: Decodable {
            struct ToolCall: Decodable {
                struct Function: Decodable {
                    let name: String?
                    let arguments: String?
                }
                let index: Int?
                let id: String?
                let function: Function?
            }
            let content: String?
            let tool_calls: [ToolCall]?
        }
        let delta: Delta?
        let finish_reason: String?
    }
    let choices: [Choice]
}

/// 把一行行 SSE 数据拼成一条完整回复。
///
/// 单独拆出来的原因：分片会从中间切开（一个 tool_call 的 arguments 可能分几十次到达），
/// 这段拼接逻辑必须能脱离网络单独测。
struct StreamAccumulator {
    private(set) var content = ""
    /// index → (id, name, arguments)
    private var calls: [Int: (id: String, name: String, args: String)] = [:]

    var isEmpty: Bool { content.isEmpty && calls.isEmpty }

    /// 吃一行 SSE，返回这一行新增的可见文本
    mutating func consume(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("data:") else { return nil }
        let payload = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
        guard payload != "[DONE]" else { return nil }
        guard let data = payload.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(StreamChunk.self, from: data),
              let delta = chunk.choices.first?.delta else { return nil }

        var text = ""
        if let piece = delta.content, !piece.isEmpty {
            content += piece
            text = piece
        }
        if let toolCalls = delta.tool_calls {
            for call in toolCalls { merge(call) }
        }
        return text.isEmpty ? nil : text
    }

    private mutating func merge(_ call: StreamChunk.Choice.Delta.ToolCall) {
        let index = call.index ?? 0
        var entry = calls[index] ?? (id: "", name: "", args: "")
        if let id = call.id, !id.isEmpty { entry.id = id }
        if let name = call.function?.name, !name.isEmpty { entry.name += name }
        if let args = call.function?.arguments { entry.args += args }
        calls[index] = entry
    }

    /// 拼成和「非流式」一模一样的消息结构，上层的 agent 循环不用区分两种模式
    func message() -> ChatCompletionResponse.Choice.Message {
        let toolCalls = calls.keys.sorted().map { index -> WireToolCall in
            let entry = calls[index] ?? (id: "", name: "", args: "")
            return WireToolCall(id: entry.id.isEmpty ? "call_\(index)" : entry.id,
                                type: "function",
                                function: WireToolCall.FunctionSpec(name: entry.name, arguments: entry.args))
        }
        return ChatCompletionResponse.Choice.Message(role: "assistant",
                                                     content: content.isEmpty ? nil : content,
                                                     tool_calls: toolCalls.isEmpty ? nil : toolCalls)
    }
}

// MARK: - DeepSeek 客户端（OpenAI 兼容协议）

final class DeepSeekClient {

    /// 独立 session：网络短暂抖动时让它自己等一会儿重连，而不是直接报错
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.waitsForConnectivity = true
        cfg.timeoutIntervalForRequest = 120
        cfg.timeoutIntervalForResource = 300
        return URLSession(configuration: cfg)
    }()

    /// 单轮对话：发消息 + 工具定义，拿回模型回复（可能带 tool_calls）。
    ///
    /// 传了 `onDelta` 就走流式（SSE）：模型吐一点文字就回调一次，UI 可以边收边显示；
    /// 自建网关不支持流式时自动退回普通请求（功能不变，只是没有边收边显示）。
    func chat(_ messages: [WireMessage],
              tools: [ToolSchema],
              onDelta: (@MainActor (String) -> Void)? = nil) async throws -> ChatCompletionResponse.Choice.Message {
        do {
            return try await withBackgroundTime {
                guard let onDelta else {
                    return try await performChat(messages, tools: tools, stream: false, onDelta: nil)
                }
                do {
                    return try await performChat(messages, tools: tools, stream: true, onDelta: onDelta)
                } catch {
                    let mapped = AgentError.from(error)
                    if mapped.isNetworkIssue { throw mapped }
                    // 流式不被支持 / 返回内容不合法 → 退回普通请求
                    return try await performChat(messages, tools: tools, stream: false, onDelta: nil)
                }
            }
        } catch {
            throw AgentError.from(error)
        }
    }

    /// 请求期间持有后台任务，别让 App 一切后台就被掐断
    private func withBackgroundTime<T>(_ body: () async throws -> T) async throws -> T {
        #if canImport(UIKit)
        let assertion = await BackgroundAssertion.begin("ai-chat")
        do {
            let value = try await body()
            await BackgroundAssertion.end(assertion)
            return value
        } catch {
            await BackgroundAssertion.end(assertion)
            throw error
        }
        #else
        return try await body()
        #endif
    }

    private func performChat(_ messages: [WireMessage],
                             tools: [ToolSchema],
                             stream: Bool,
                             onDelta: (@MainActor (String) -> Void)?) async throws -> ChatCompletionResponse.Choice.Message {
        let settings = AppSettings.shared
        guard !settings.apiKey.isEmpty else { throw AgentError.noAPIKey }
        guard let base = URL(string: settings.baseURL) else { throw AgentError.badURL }

        var req = URLRequest(url: base.appendingPathComponent("chat/completions"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue(stream ? "text/event-stream" : "application/json", forHTTPHeaderField: "Accept")
        req.timeoutInterval = 120
        req.httpBody = try JSONEncoder().encode(
            ChatCompletionRequest(model: settings.model, messages: messages, tools: tools,
                                  tool_choice: "auto", stream: stream)
        )

        guard stream else {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse else { throw AgentError.emptyResponse }
            guard (200..<300).contains(http.statusCode) else { throw Self.httpError(http.statusCode, data) }
            let decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
            guard let m = decoded.choices.first?.message else { throw AgentError.emptyResponse }
            return m
        }

        let (bytes, resp) = try await session.bytes(for: req)
        guard let http = resp as? HTTPURLResponse else { throw AgentError.emptyResponse }
        guard (200..<300).contains(http.statusCode) else {
            // 出错时返回的不是 SSE，得先把 body 收完才看得到原因
            var data = Data()
            for try await byte in bytes { data.append(byte) }
            throw Self.httpError(http.statusCode, data)
        }

        return try await Self.consumeSSE(bytes, onDelta: onDelta)
    }

    /// 把一段 SSE 响应流拼成完整回复。
    /// 单独抽出来是为了能脱离鉴权和真实 API 单独验证（本地起个 SSE 服务就能测）。
    static func consumeSSE(_ bytes: URLSession.AsyncBytes,
                           onDelta: (@MainActor (String) -> Void)?) async throws -> ChatCompletionResponse.Choice.Message {
        var accumulator = StreamAccumulator()
        for try await line in bytes.lines {
            if let delta = accumulator.consume(line: line) {
                await onDelta?(delta)
            }
        }
        guard !accumulator.isEmpty else { throw AgentError.emptyResponse }
        return accumulator.message()
    }

    private static func httpError(_ code: Int, _ data: Data) -> AgentError {
        let msg = (try? JSONDecoder().decode(ErrorResponse.self, from: data))?.error?.message
            ?? String(data: data, encoding: .utf8)
            ?? ""
        return .http(code, String(msg.prefix(300)))
    }

    /// 测试连接：GET /models
    func listModels() async throws -> String {
        let settings = AppSettings.shared
        guard !settings.apiKey.isEmpty else { throw AgentError.noAPIKey }
        guard let url = URL(string: settings.baseURL) else { throw AgentError.badURL }

        var req = URLRequest(url: url.appendingPathComponent("models"))
        req.setValue("Bearer \(settings.apiKey)", forHTTPHeaderField: "Authorization")

        do {
            let (data, resp) = try await session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                throw AgentError.http(code, String(data: data, encoding: .utf8) ?? "")
            }

            struct ModelsResp: Decodable {
                struct M: Decodable { let id: String }
                let data: [M]
            }
            let decoded = try JSONDecoder().decode(ModelsResp.self, from: data)
            return decoded.data.map(\.id).joined(separator: ", ")
        } catch let e as AgentError {
            throw e
        } catch {
            throw AgentError.from(error)
        }
    }
}

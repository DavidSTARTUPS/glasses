import Foundation
import UIKit

public typealias GeminiAIService = OpenRouterService

public final class OpenRouterService {
    public static let shared = OpenRouterService()

    private let endpoint = URL(string: "https://openrouter.ai/api/v1/chat/completions")!
    // Google Gemma 4 31B: state-of-the-art vision & conversational model (~0.66s response time)
    private let model = "google/gemma-4-31b-it"

    private static let apiKeyDefaultsKey = "openRouterApiKey"

    /// Default fallback if injected; empty by default for public repositories
    private let defaultApiKey = ""

    /// Active API key. Initialized from `UserDefaults`; Settings screen can override.
    public var apiKey: String = ""

    init() {
        if let savedKey = UserDefaults.standard.string(forKey: Self.apiKeyDefaultsKey),
           !savedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            apiKey = savedKey
        } else {
            apiKey = defaultApiKey
        }
    }

    public func setApiKey(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        apiKey = trimmed
        UserDefaults.standard.set(trimmed, forKey: Self.apiKeyDefaultsKey)
    }

    public func sendQuery(prompt: String, image: UIImage?, completion: @escaping (Result<String, Error>) -> Void) {
        if apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let savedKey = UserDefaults.standard.string(forKey: Self.apiKeyDefaultsKey),
               !savedKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                apiKey = savedKey
            } else {
                apiKey = defaultApiKey
            }
        }
        guard !apiKey.isEmpty else {
            logAI("OpenRouter API Key missing — please configure your API key in Settings.", level: .error)
            completion(.failure(NSError(domain: "OpenRouter", code: 401, userInfo: [NSLocalizedDescriptionKey: "OpenRouter API Key missing. Please set your key in Settings."])))
            return
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var contentArray: [[String: Any]] = []
        var imageBytes = 0

        if let image = image, let jpegData = image.jpegData(compressionQuality: 0.7) {
            imageBytes = jpegData.count
            let base64Image = jpegData.base64EncodedString()
            contentArray.append([
                "type": "image_url",
                "image_url": ["url": "data:image/jpeg;base64,\(base64Image)"]
            ])
        }

        let systemInstruction = """
        You are Jarvis, the smart voice assistant embedded in the user's smart glasses. Answer concisely in plain English (maximum 1-2 short natural sentences), without any markdown formatting or bullet points, exactly like a voice assistant in earbuds.
        IMPORTANT RULES:
        1. You cannot physically trigger cameras or capture photos yourself. Photos are captured by the glasses hardware and provided directly to you as an attached image.
        2. If an image is attached, describe what is in front of the user clearly, accurately, and concisely.
        3. If NO image is attached and the user asks what is in front of them or asks you to take a photo, NEVER claim that you took a picture or will take a picture. Explicitly inform the user that no photo was received from the glasses camera.
        """

        contentArray.append([
            "type": "text",
            "text": "\(systemInstruction)\n\nUser Question: \(prompt)"
        ])

        let body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "user", "content": contentArray]
            ],
            "temperature": 0.4,
            "max_tokens": 300
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            logAI("Body serialization failed: \(error.localizedDescription)", level: .error)
            completion(.failure(error))
            return
        }

        logAI("Request → model=\(model), image=\(image != nil ? "YES (\(imageBytes) B JPEG)" : "NO"), prompt=\(prompt.count) chars.", level: .tx)

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self = self else { return }
            let statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0

            if let error = error {
                self.logAI("Transport error (HTTP \(statusCode)): \(error.localizedDescription)", level: .error)
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }

            guard let data = data else {
                self.logAI("Empty response body (HTTP \(statusCode)).", level: .error)
                DispatchQueue.main.async {
                    completion(.failure(NSError(domain: "OpenRouter", code: 500, userInfo: [NSLocalizedDescriptionKey: "No data received"])))
                }
                return
            }

            do {
                if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let choices = json["choices"] as? [[String: Any]],
                   let firstChoice = choices.first,
                   let message = firstChoice["message"] as? [String: Any] {
                    var content = (message["content"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if content.isEmpty, let reasoning = (message["reasoning"] as? String) ?? (message["reasoning_content"] as? String) {
                        content = reasoning.trimmingCharacters(in: .whitespacesAndNewlines)
                    }
                    guard !content.isEmpty else {
                        self.logAI("Empty message content (HTTP \(statusCode)).", level: .error)
                        DispatchQueue.main.async {
                            completion(.failure(NSError(domain: "OpenRouter", code: 204, userInfo: [NSLocalizedDescriptionKey: "Empty response from AI."])))
                        }
                        return
                    }
                    self.logAI("Response OK (HTTP \(statusCode), \(content.count) chars): \"\(content.prefix(60))...\".", level: .rx)
                    DispatchQueue.main.async {
                        completion(.success(content))
                    }
                } else {
                    let serverMessage = Self.extractServerErrorMessage(from: data) ?? "Invalid server response"
                    self.logAI("Request rejected (HTTP \(statusCode)): \(serverMessage)", level: .error)
                    DispatchQueue.main.async {
                        completion(.failure(NSError(
                            domain: "OpenRouter",
                            code: statusCode == 0 ? 422 : statusCode,
                            userInfo: [NSLocalizedDescriptionKey: "OpenRouter (HTTP \(statusCode)): \(serverMessage)"]
                        )))
                    }
                }
            } catch {
                self.logAI("JSON parse error (HTTP \(statusCode)): \(error.localizedDescription)", level: .error)
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }.resume()
    }

    private static func extractServerErrorMessage(from data: Data) -> String? {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let errorObject = json["error"] as? [String: Any],
           let message = errorObject["message"] as? String,
           !message.isEmpty {
            return message
        }
        if let text = String(data: data, encoding: .utf8), !text.isEmpty {
            return text.prefix(300).description
        }
        return nil
    }

    private func logAI(_ message: String, level: DebugLogLevel) {
        print("[DEBUG - AI] \(message)")
        DebugLogger.shared.log(message, level: level)
    }
}

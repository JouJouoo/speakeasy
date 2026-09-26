import SwiftUI
import UIKit
import Security
import Speech
import AVFoundation

@main
struct SpeakEasyApp: App {
    @StateObject private var library = PhraseLibrary()

    var body: some Scene {
        WindowGroup {
            MainView()
                .environmentObject(library)
        }
    }
}

struct Phrase: Identifiable, Hashable, Codable {
    var id = UUID()
    let chinese: String
    let english: String
    let note: String
    let example: String
}

struct PracticeTurn: Identifiable, Codable {
    let id: UUID
    let chinese: String
    var phrases: [Phrase] = []
    var message: String?
    var isLoading = true
    var isExpanded = true

    init(chinese: String) {
        id = UUID()
        self.chinese = chinese
    }
}

struct WordHistoryEntry: Identifiable, Codable {
    let id: UUID
    var word: String
    var ipa: String
    var meaning: String
    var count: Int
    var date: Date

    private enum CodingKeys: String, CodingKey { case id, word, ipa, meaning, count, date }

    init(id: UUID, word: String, ipa: String, meaning: String, count: Int = 1, date: Date) {
        self.id = id
        self.word = word
        self.ipa = ipa
        self.meaning = meaning
        self.count = count
        self.date = date
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        word = try values.decode(String.self, forKey: .word)
        ipa = try values.decode(String.self, forKey: .ipa)
        meaning = try values.decode(String.self, forKey: .meaning)
        count = try values.decodeIfPresent(Int.self, forKey: .count) ?? 1
        date = try values.decode(Date.self, forKey: .date)
    }
}

struct GrammarHistoryEntry: Identifiable, Codable {
    let id: UUID
    var chinese: String
    var english: String
    var analysis: String
    var count: Int
    var date: Date

    private enum CodingKeys: String, CodingKey { case id, chinese, english, analysis, count, date }

    init(id: UUID, chinese: String, english: String, analysis: String, count: Int = 1, date: Date) {
        self.id = id
        self.chinese = chinese
        self.english = english
        self.analysis = analysis
        self.count = count
        self.date = date
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        chinese = try values.decode(String.self, forKey: .chinese)
        english = try values.decode(String.self, forKey: .english)
        analysis = try values.decode(String.self, forKey: .analysis)
        count = try values.decodeIfPresent(Int.self, forKey: .count) ?? 1
        date = try values.decode(Date.self, forKey: .date)
    }
}

private enum PromptDefaults {
    static let role = "你是一位友善、耐心的英语口语教练，帮助中文学习者把想表达的意思说成自然、地道的日常英语。给出三种常用说法，并体现不同语气或场景。解释使用简体中文，例句简短自然。"
    static let request = "请把下面的中文改写成自然的英语口语表达。每种说法说明适用语气或场景，并给一个简短例句。"
}

@MainActor
final class PhraseLibrary: ObservableObject {
    @Published var saved: [Phrase] = [] {
        didSet {
            guard let data = try? JSONEncoder().encode(saved) else { return }
            UserDefaults.standard.set(data, forKey: "savedPhrases")
        }
    }
    @Published var turns: [PracticeTurn] = [] {
        didSet {
            guard let data = try? JSONEncoder().encode(turns) else { return }
            UserDefaults.standard.set(data, forKey: "practiceHistory")
        }
    }
    @Published fileprivate(set) var wordHistory: [WordHistoryEntry] = [] {
        didSet {
            guard let data = try? JSONEncoder().encode(wordHistory) else { return }
            UserDefaults.standard.set(data, forKey: "wordLookupHistory")
        }
    }
    @Published fileprivate(set) var grammarHistory: [GrammarHistoryEntry] = [] {
        didSet {
            guard let data = try? JSONEncoder().encode(grammarHistory) else { return }
            UserDefaults.standard.set(data, forKey: "grammarAnalysisHistory")
        }
    }
    @Published var isLoading = false
    @Published private(set) var apiKeyConfigured: Bool
    @Published var systemPrompt: String {
        didSet { UserDefaults.standard.set(systemPrompt, forKey: "systemPrompt") }
    }
    @Published var requestPrompt: String {
        didSet { UserDefaults.standard.set(requestPrompt, forKey: "requestPrompt") }
    }
    @Published fileprivate var activeWordAnchor: UUID?
    @Published fileprivate var activeWord = ""
    @Published fileprivate var activeWordInfo: WordInfo?
    @Published fileprivate var isWordLookupLoading = false
    @Published fileprivate var wordLookupError: String?
    @Published fileprivate var activeGrammarPhraseID: UUID?
    @Published fileprivate var grammarAnalysis: String?
    @Published fileprivate var isGrammarAnalysisLoading = false
    @Published fileprivate var grammarAnalysisError: String?
    @Published private(set) var speakingPhraseID: UUID?
    @Published fileprivate var speakingWordAnchor: UUID?
    private var wordCache: [String: WordInfo] = [:]
    private var activeWordTask: Task<Void, Never>?
    private var grammarCache: [String: String] = [:]
    private var grammarTask: Task<Void, Never>?
    private let speechSynthesizer = AVSpeechSynthesizer()
    private var speechMonitor: Task<Void, Never>?

    init() {
        apiKeyConfigured = KeychainStore.load() != nil
        systemPrompt = UserDefaults.standard.string(forKey: "systemPrompt") ?? PromptDefaults.role
        requestPrompt = UserDefaults.standard.string(forKey: "requestPrompt") ?? PromptDefaults.request
        if let data = UserDefaults.standard.data(forKey: "wordLookupCache"),
           let cache = try? JSONDecoder().decode([String: WordInfo].self, from: data) {
            wordCache = cache
        }
        if let data = UserDefaults.standard.data(forKey: "practiceHistory"),
           let history = try? JSONDecoder().decode([PracticeTurn].self, from: data) {
            turns = history.map { savedTurn in
                var turn = savedTurn
                turn.isLoading = false
                turn.isExpanded = false
                if turn.phrases.isEmpty && turn.message == nil {
                    turn.message = "这条练习上次没有完成，可以重新发送。"
                }
                return turn
            }
        }
        if let data = UserDefaults.standard.data(forKey: "savedPhrases"),
           let phrases = try? JSONDecoder().decode([Phrase].self, from: data) {
            saved = phrases
        }
        if let data = UserDefaults.standard.data(forKey: "wordLookupHistory"),
           let history = try? JSONDecoder().decode([WordHistoryEntry].self, from: data) {
            wordHistory = deduplicatedWordHistory(history)
        }
        if let data = UserDefaults.standard.data(forKey: "grammarAnalysisHistory"),
           let history = try? JSONDecoder().decode([GrammarHistoryEntry].self, from: data) {
            grammarHistory = deduplicatedGrammarHistory(history)
        }
        for entry in grammarHistory {
            let key = entry.english.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if grammarCache[key] == nil { grammarCache[key] = entry.analysis }
        }
    }

    func practice(_ text: String) async {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else {
            return
        }

        guard let apiKey = KeychainStore.load(), !apiKey.isEmpty else {
            return
        }

        isLoading = true
        for index in turns.indices { turns[index].isExpanded = false }
        let turn = PracticeTurn(chinese: input)
        turns.append(turn)
        do {
            let phrases = try await DeepSeekClient.complete(
                chinese: input,
                apiKey: apiKey,
                systemPrompt: systemPrompt,
                requestPrompt: requestPrompt
            )
            if let index = turns.firstIndex(where: { $0.id == turn.id }) {
                turns[index].phrases = phrases
            }
        } catch {
            if let index = turns.firstIndex(where: { $0.id == turn.id }) {
                turns[index].message = error.localizedDescription
            }
        }
        if let index = turns.firstIndex(where: { $0.id == turn.id }) {
            turns[index].isLoading = false
        }
        isLoading = false
    }

    func toggleExpanded(_ id: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == id }) else { return }
        turns[index].isExpanded.toggle()
    }

    func collapse(_ id: UUID) {
        guard let index = turns.firstIndex(where: { $0.id == id }), turns[index].isExpanded else { return }
        turns[index].isExpanded = false
    }

    func collapseAllTurns() {
        guard turns.contains(where: { $0.isExpanded }) else { return }
        turns = turns.map { turn in
            var collapsed = turn
            collapsed.isExpanded = false
            return collapsed
        }
    }

    func deleteTurn(_ id: UUID) {
        turns.removeAll { $0.id == id }
    }

    func deleteTurns(_ ids: Set<UUID>) {
        turns.removeAll { ids.contains($0.id) }
    }

    func deleteWordHistory(_ ids: Set<UUID>) {
        wordHistory.removeAll { ids.contains($0.id) }
    }

    func deleteGrammarHistory(_ ids: Set<UUID>) {
        grammarHistory.removeAll { ids.contains($0.id) }
    }

    fileprivate func lookupWord(_ word: String) async throws -> WordInfo {
        let cacheKey = word.lowercased()
        if let cached = wordCache[cacheKey] { return cached }
        guard let apiKey = KeychainStore.load(), !apiKey.isEmpty else {
            throw DeepSeekError.service("请先在设置中连接 DeepSeek。")
        }
        let result = try await DeepSeekClient.lookupWord(word, apiKey: apiKey)
        wordCache[cacheKey] = result
        if let data = try? JSONEncoder().encode(wordCache) {
            UserDefaults.standard.set(data, forKey: "wordLookupCache")
        }
        return result
    }

    fileprivate func startWordLookup(_ word: String, anchor: UUID) {
        activeWordTask?.cancel()
        activeWordAnchor = anchor
        activeWord = word
        activeWordInfo = nil
        wordLookupError = nil

        let cacheKey = word.lowercased()
        if let cached = wordCache[cacheKey] {
            activeWordInfo = cached
            isWordLookupLoading = false
            recordWordLookup(cached)
            return
        }

        isWordLookupLoading = true
        activeWordTask = Task { @MainActor in
            do {
                let result = try await lookupWord(word)
                guard !Task.isCancelled, activeWordAnchor == anchor else { return }
                activeWordInfo = result
                recordWordLookup(result)
            } catch {
                guard !Task.isCancelled, activeWordAnchor == anchor else { return }
                wordLookupError = error.localizedDescription
            }
            isWordLookupLoading = false
        }
    }

    fileprivate func dismissWordLookup(anchor: UUID) {
        guard activeWordAnchor == anchor else { return }
        activeWordTask?.cancel()
        activeWordTask = nil
        if speakingWordAnchor == anchor { stopCurrentSpeech() }
        activeWordAnchor = nil
        activeWord = ""
        activeWordInfo = nil
        wordLookupError = nil
        isWordLookupLoading = false
    }

    fileprivate func startGrammarAnalysis(for phrase: Phrase) {
        grammarTask?.cancel()
        activeGrammarPhraseID = phrase.id
        grammarAnalysis = nil
        grammarAnalysisError = nil

        let cacheKey = phrase.english.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let cached = grammarCache[cacheKey] {
            grammarAnalysis = cached
            isGrammarAnalysisLoading = false
            recordGrammarAnalysis(phrase, analysis: cached)
            return
        }

        guard let apiKey = KeychainStore.load(), !apiKey.isEmpty else {
            isGrammarAnalysisLoading = false
            grammarAnalysisError = "请先连接 DeepSeek。"
            return
        }

        isGrammarAnalysisLoading = true
        grammarTask = Task { @MainActor in
            do {
                let result = try await DeepSeekClient.analyzeGrammar(phrase.english, apiKey: apiKey)
                guard !Task.isCancelled, activeGrammarPhraseID == phrase.id else { return }
                grammarCache[cacheKey] = result
                grammarAnalysis = result
                recordGrammarAnalysis(phrase, analysis: result)
            } catch {
                guard !Task.isCancelled, activeGrammarPhraseID == phrase.id else { return }
                grammarAnalysisError = error.localizedDescription
            }
            isGrammarAnalysisLoading = false
        }
    }

    fileprivate func dismissGrammarAnalysis(phraseID: UUID) {
        guard activeGrammarPhraseID == phraseID else { return }
        grammarTask?.cancel()
        grammarTask = nil
        activeGrammarPhraseID = nil
        grammarAnalysis = nil
        grammarAnalysisError = nil
        isGrammarAnalysisLoading = false
    }

    private func recordWordLookup(_ wordInfo: WordInfo) {
        if let index = wordHistory.firstIndex(where: { $0.word.caseInsensitiveCompare(wordInfo.word) == .orderedSame }) {
            var entry = wordHistory.remove(at: index)
            entry.count += 1
            entry.ipa = wordInfo.ipa
            entry.meaning = wordInfo.meaning
            entry.date = Date()
            wordHistory.insert(entry, at: 0)
        } else {
            wordHistory.insert(
                WordHistoryEntry(id: UUID(), word: wordInfo.word, ipa: wordInfo.ipa, meaning: wordInfo.meaning, date: Date()),
                at: 0
            )
        }
    }

    private func deduplicatedWordHistory(_ entries: [WordHistoryEntry]) -> [WordHistoryEntry] {
        let newestFirst = entries.sorted { $0.date > $1.date }
        var order: [String] = []
        var grouped: [String: WordHistoryEntry] = [:]
        for entry in newestFirst {
            let key = entry.word.lowercased()
            if var existing = grouped[key] {
                existing.count += entry.count
                grouped[key] = existing
            } else {
                order.append(key)
                grouped[key] = entry
            }
        }
        return order.compactMap { grouped[$0] }
    }

    private func deduplicatedGrammarHistory(_ entries: [GrammarHistoryEntry]) -> [GrammarHistoryEntry] {
        let newestFirst = entries.sorted { $0.date > $1.date }
        var order: [String] = []
        var grouped: [String: GrammarHistoryEntry] = [:]
        for entry in newestFirst {
            let key = entry.english.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if var existing = grouped[key] {
                existing.count += entry.count
                grouped[key] = existing
            } else {
                order.append(key)
                grouped[key] = entry
            }
        }
        return order.compactMap { grouped[$0] }
    }

    private func recordGrammarAnalysis(_ phrase: Phrase, analysis: String) {
        let key = phrase.english.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let index = grammarHistory.firstIndex(where: { $0.english.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == key }) {
            var entry = grammarHistory.remove(at: index)
            entry.count += 1
            entry.chinese = phrase.chinese
            entry.analysis = analysis
            entry.date = Date()
            grammarHistory.insert(entry, at: 0)
        } else {
            grammarHistory.insert(
                GrammarHistoryEntry(id: UUID(), chinese: phrase.chinese, english: phrase.english, analysis: analysis, date: Date()),
                at: 0
            )
        }
    }

    func saveAPIKey(_ key: String) throws {
        try KeychainStore.save(key.trimmingCharacters(in: .whitespacesAndNewlines))
        apiKeyConfigured = true
    }

    func removeAPIKey() throws {
        try KeychainStore.remove()
        apiKeyConfigured = false
    }

    func toggleSaved(_ phrase: Phrase) {
        if let index = saved.firstIndex(where: { $0.english == phrase.english }) {
            saved.remove(at: index)
        } else {
            saved.insert(phrase, at: 0)
        }
    }

    func deleteSavedPhrases(_ ids: Set<UUID>) {
        saved.removeAll { ids.contains($0.id) }
    }

    func contains(_ phrase: Phrase) -> Bool {
        saved.contains { $0.english == phrase.english }
    }

    func speak(_ phrase: Phrase) {
        if speakingPhraseID == phrase.id, speechSynthesizer.isSpeaking {
            stopCurrentSpeech()
            return
        }
        speakText(phrase.english, phraseID: phrase.id)
    }

    func speakWord(_ word: String, anchor: UUID) {
        guard !word.isEmpty else { return }
        if speakingWordAnchor == anchor, speechSynthesizer.isSpeaking {
            stopCurrentSpeech()
            return
        }
        speakText(word, wordAnchor: anchor)
    }

    private func speakText(_ text: String, phraseID: UUID? = nil, wordAnchor: UUID? = nil) {
        speechMonitor?.cancel()
        speechSynthesizer.stopSpeaking(at: .immediate)
        // Speech input configures the app's shared audio session for recording.
        // Let iOS manage a separate playback session so TTS remains audible and
        // the hardware volume buttons control media volume normally.
        speechSynthesizer.usesApplicationAudioSession = false
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-GB")
        utterance.rate = AVSpeechUtteranceDefaultSpeechRate * 0.92
        utterance.volume = 1.0
        speechSynthesizer.speak(utterance)
        speakingPhraseID = phraseID
        speakingWordAnchor = wordAnchor

        speechMonitor = Task { @MainActor [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(120))
                guard !Task.isCancelled else { return }
                if !self.speechSynthesizer.isSpeaking {
                    self.speakingPhraseID = nil
                    self.speakingWordAnchor = nil
                    return
                }
            }
        }
    }

    private func stopCurrentSpeech() {
        speechMonitor?.cancel()
        speechSynthesizer.stopSpeaking(at: .immediate)
        speakingPhraseID = nil
        speakingWordAnchor = nil
    }
}

private enum KeychainStore {
    private static let service = "com.spokenenglish.SpeakEasy"
    private static let account = "deepseek-api-key"

    static func load() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func save(_ value: String) throws {
        guard let data = value.data(using: .utf8), !value.isEmpty else {
            throw DeepSeekError.emptyKey
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = query
            insert[kSecValueData as String] = data
            let addStatus = SecItemAdd(insert as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw DeepSeekError.keychain }
        } else if status != errSecSuccess {
            throw DeepSeekError.keychain
        }
    }

    static func remove() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw DeepSeekError.keychain
        }
    }
}

private enum DeepSeekError: LocalizedError, Sendable {
    case emptyKey, keychain, badResponse, service(String), noPhrases

    var errorDescription: String? {
        switch self {
        case .emptyKey: return "API 密钥不能为空。"
        case .keychain: return "密钥保存失败，请稍后重试。"
        case .badResponse: return "DeepSeek 返回内容无法识别，请再试一次。"
        case .service(let detail): return detail
        case .noPhrases: return "这次没有生成表达，请再试一次。"
        }
    }
}

private enum DeepSeekClient {
    private struct ChatRequest: Encodable {
        struct Message: Encodable { let role: String; let content: String }
        struct Thinking: Encodable { let type: String }
        let model = "deepseek-flash"
        let messages: [Message]
        let response_format = ResponseFormat(type: "json_object")
        let max_tokens: Int
        let temperature = 0.2
        let thinking = Thinking(type: "disabled")
        struct ResponseFormat: Encodable { let type: String }
    }

    private struct ChatResponse: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable { let content: String? }
            let message: Message
        }
        let choices: [Choice]
    }

    private struct PhraseResponse: Decodable {
        struct Item: Decodable { let english: String; let note: String; let example: String }
        let phrases: [Item]
    }

    private struct WordResponse: Decodable {
        let ipa: String
        let meaning: String
    }

    private struct GrammarResponse: Decodable {
        let analysis: String
    }

    private struct LookupHTTPResult: @unchecked Sendable {
        let data: Data
        let response: URLResponse
    }

    private struct APIErrorResponse: Decodable {
        struct Detail: Decodable { let message: String? }
        let error: Detail?
    }

    static func complete(chinese: String, apiKey: String, systemPrompt: String, requestPrompt: String) async throws -> [Phrase] {
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(ChatRequest(messages: [
            .init(role: "system", content: "\(systemPrompt)\n\n请务必以 json 格式返回，不要添加 Markdown 或其他文字，并严格遵循此结构：{\"phrases\":[{\"english\":\"英文表达\",\"note\":\"简体中文说明\",\"example\":\"英文例句\"}]}。phrases 必须包含三项，每项都必须有 english、note、example。"),
            .init(role: "user", content: "\(requestPrompt)\n\n中文原句：\(chinese)")
        ], max_tokens: 650))

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw DeepSeekError.service("连接 DeepSeek 失败，请检查网络后重试。")
        }
        guard let http = response as? HTTPURLResponse else { throw DeepSeekError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = try? JSONDecoder().decode(APIErrorResponse.self, from: data).error?.message
            if http.statusCode == 401 { throw DeepSeekError.service("API 密钥无效，请到设置中检查。") }
            if http.statusCode == 402 { throw DeepSeekError.service("DeepSeek 账户余额不足，请检查账户余额。") }
            if http.statusCode == 429 { throw DeepSeekError.service("请求太频繁了，请稍等片刻再试。") }
            throw DeepSeekError.service(detail ?? "DeepSeek 暂时无法处理请求，请稍后重试。")
        }
        let chat = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = chat.choices.first?.message.content,
              let json = content.data(using: .utf8) else { throw DeepSeekError.badResponse }
        let result = try JSONDecoder().decode(PhraseResponse.self, from: json)
        let phrases = result.phrases.prefix(3).map {
            Phrase(chinese: chinese, english: $0.english, note: $0.note, example: $0.example)
        }
        guard !phrases.isEmpty else { throw DeepSeekError.noPhrases }
        return phrases
    }

    static func lookupWord(_ word: String, apiKey: String) async throws -> WordInfo {
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 6
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(ChatRequest(messages: [
            .init(role: "system", content: "You are a concise English-Chinese dictionary. Reply only in json with exactly these keys: ipa and meaning. Give the standard IPA pronunciation and the one or two most common meanings in Simplified Chinese. Do not include examples, phrases, collocations, etymology, or any other explanation. Example format: {\"ipa\":\"/ˈlɪsənɪŋ/\",\"meaning\":\"听；倾听\"}. Use lowercase json in this instruction."),
            .init(role: "user", content: word)
        ], max_tokens: 64))

        let httpResult: LookupHTTPResult
        do {
            httpResult = try await withThrowingTaskGroup(of: LookupHTTPResult.self) { group in
                group.addTask {
                    let (data, response) = try await URLSession.shared.data(for: request)
                    return LookupHTTPResult(data: data, response: response)
                }
                group.addTask {
                    try await Task.sleep(for: .seconds(6))
                    throw DeepSeekError.service("查询超过 6 秒仍未响应，请点重试。")
                }
                guard let first = try await group.next() else {
                    throw DeepSeekError.service("单词查询暂时失败，请重试。")
                }
                group.cancelAll()
                return first
            }
        } catch {
            if let lookupError = error as? DeepSeekError { throw lookupError }
            throw DeepSeekError.service("查询超时或网络连接失败，请重试。")
        }
        let data = httpResult.data
        let response = httpResult.response
        guard let http = response as? HTTPURLResponse else {
            throw DeepSeekError.service("单词查询暂时失败，请重试。")
        }
        guard (200..<300).contains(http.statusCode) else {
            let detail = try? JSONDecoder().decode(APIErrorResponse.self, from: data).error?.message
            if http.statusCode == 401 { throw DeepSeekError.service("DeepSeek 密钥无效，请到设置中检查。") }
            if http.statusCode == 402 { throw DeepSeekError.service("DeepSeek 账户余额不足，请检查账户余额。") }
            if http.statusCode == 429 { throw DeepSeekError.service("请求太频繁了，请稍等片刻再试。") }
            throw DeepSeekError.service(detail ?? "单词查询失败（\(http.statusCode)），请重试。")
        }
        let chat = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = chat.choices.first?.message.content,
              let json = content.data(using: .utf8),
              let result = try? JSONDecoder().decode(WordResponse.self, from: json),
              !result.ipa.isEmpty, !result.meaning.isEmpty else {
            throw DeepSeekError.service("暂时查不到这个单词，请稍后再试。")
        }
        return WordInfo(word: word, ipa: result.ipa, meaning: result.meaning)
    }

    static func analyzeGrammar(_ sentence: String, apiKey: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://api.deepseek.com/chat/completions")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(ChatRequest(messages: [
            .init(role: "system", content: "You are an English grammar tutor for Chinese learners. Return only valid json with exactly one key named analysis. The value must be concise Simplified Chinese, explaining the sentence's core structure, tense, and important clauses or phrases. Do not rewrite the sentence or add examples. Include the word json in your response format instructions."),
            .init(role: "user", content: "请分析这句英语的语法结构，用简洁的简体中文说明主干、时态以及关键从句或短语。只分析这整句话，不要例句。请用 json 格式返回。\n句子：\(sentence)")
        ], max_tokens: 220))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw DeepSeekError.service("语法分析连接失败，请检查网络后重试。")
        }
        guard let http = response as? HTTPURLResponse else { throw DeepSeekError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let detail = try? JSONDecoder().decode(APIErrorResponse.self, from: data).error?.message
            if http.statusCode == 401 { throw DeepSeekError.service("DeepSeek 密钥无效，请到设置中检查。") }
            if http.statusCode == 402 { throw DeepSeekError.service("DeepSeek 账户余额不足，请检查账户余额。") }
            if http.statusCode == 429 { throw DeepSeekError.service("请求太频繁了，请稍等片刻再试。") }
            throw DeepSeekError.service(detail ?? "语法分析暂时失败，请稍后重试。")
        }
        let chat = try JSONDecoder().decode(ChatResponse.self, from: data)
        guard let content = chat.choices.first?.message.content,
              let json = content.data(using: .utf8),
              let result = try? JSONDecoder().decode(GrammarResponse.self, from: json),
              !result.analysis.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeepSeekError.service("暂时无法解析语法分析结果，请重试。")
        }
        return result.analysis
    }
}

struct WordInfo: Codable {
    let word: String
    let ipa: String
    let meaning: String
}

private struct WordFlowLayout: Layout {
    var spacing: CGFloat = 5
    var rowSpacing: CGFloat = 0

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let limit = proposal.width ?? 360
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0 && x + spacing + size.width > limit {
                y += rowHeight + rowSpacing
                x = 0
                rowHeight = 0
            }
            if x > 0 { x += spacing }
            x += size.width
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX && x + spacing + size.width > bounds.maxX {
                y += rowHeight + rowSpacing
                x = bounds.minX
                rowHeight = 0
            }
            if x > bounds.minX { x += spacing }
            subview.place(at: CGPoint(x: x, y: y), proposal: .unspecified)
            x += size.width
            rowHeight = max(rowHeight, size.height)
        }
    }
}

private struct WordTokenButton: View {
    @EnvironmentObject private var library: PhraseLibrary
    let token: String
    let color: Color
    let interactionDisabled: Bool
    @State private var anchorID = UUID()

    private var lookupWord: String {
        token.trimmingCharacters(in: .punctuationCharacters)
    }

    private var isActiveLookup: Bool {
        library.activeWordAnchor == anchorID
    }

    private var popoverBinding: Binding<Bool> {
        Binding(
            get: { library.activeWordAnchor == anchorID },
            set: { isPresented in
                if !isPresented { library.dismissWordLookup(anchor: anchorID) }
            }
        )
    }

    private var popoverWidth: CGFloat {
        let wordWidth = (library.activeWord as NSString).size(
            withAttributes: [.font: UIFont.systemFont(ofSize: 18, weight: .semibold)]
        ).width
        let ipaWidth = ((library.activeWordInfo?.ipa ?? "") as NSString).size(
            withAttributes: [.font: UIFont.systemFont(ofSize: 15)]
        ).width
        let meaningWidth = ((library.activeWordInfo?.meaning ?? library.wordLookupError ?? "") as NSString).size(
            withAttributes: [.font: UIFont.systemFont(ofSize: 15)]
        ).width
        return min(360, max(236, ceil(max(wordWidth + 208, ipaWidth + 40, meaningWidth + 40))))
    }

    var body: some View {
        Button {
            guard !lookupWord.isEmpty, !interactionDisabled else { return }
            library.startWordLookup(lookupWord, anchor: anchorID)
        } label: {
            Text(token)
                .font(.system(size: 24, weight: .medium, design: .serif))
                .foregroundStyle(isActiveLookup ? Color.accentColor : color)
                .padding(.horizontal, 3)
                .padding(.vertical, 2)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.accentColor.opacity(isActiveLookup ? 0.14 : 0))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.accentColor.opacity(isActiveLookup ? 0.25 : 0), lineWidth: 1)
                }
                .scaleEffect(isActiveLookup ? 1.06 : 1)
                .animation(.easeOut(duration: isActiveLookup ? 0.16 : 0.08), value: isActiveLookup)
                .fixedSize()
        }
        .buttonStyle(.plain)
        .disabled(lookupWord.isEmpty)
        .popover(isPresented: popoverBinding, attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
            VStack(alignment: .center, spacing: 12) {
                HStack(spacing: 0) {
                    Color.clear
                        .frame(width: 82, height: 32)
                    Text(library.activeWord)
                        .font(.system(size: 18, weight: .semibold, design: .serif))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                    HStack(spacing: 18) {
                        Button {
                            library.speakWord(library.activeWord, anchor: anchorID)
                        } label: {
                            Image(systemName: library.speakingWordAnchor == anchorID ? "stop.fill" : "speaker.wave.2.fill")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(library.speakingWordAnchor == anchorID ? Color.accentColor : .secondary)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(library.speakingWordAnchor == anchorID ? "停止单词发音" : "朗读单词")
                        Button { library.dismissWordLookup(anchor: anchorID) } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                                .frame(width: 32, height: 32)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("关闭")
                    }
                }
                if library.isWordLookupLoading {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("正在查询…")
                            .font(.system(size: 14))
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                } else if let info = library.activeWordInfo {
                    Text(info.ipa)
                        .font(.system(size: 15))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: .infinity)
                    Text(info.meaning)
                        .font(.system(size: 15))
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                } else if let error = library.wordLookupError {
                    Text(error)
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity)
                    Button("重试") {
                        library.startWordLookup(lookupWord, anchor: anchorID)
                    }
                    .font(.system(size: 14, weight: .medium))
                }
            }
            .padding(16)
            .frame(width: popoverWidth, alignment: .center)
            .presentationCompactAdaptation(.popover)
        }
    }
}

struct SettingsView: View {
    var body: some View {
        SettingsContentView()
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(.visible, for: .navigationBar)
    }
}

private struct SettingsContentView: View {
    @EnvironmentObject private var library: PhraseLibrary
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @State private var expandedPrompt: String?

    private var appearanceName: String {
        switch appearanceMode {
        case "light": "浅色"
        case "dark": "深色"
        default: "跟随系统"
        }
    }

    @ViewBuilder
    private func glassCard<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 26.0, *) {
            Color.clear.glassEffect(.regular, in: shape)
        } else {
            shape.fill(Color(uiColor: .secondarySystemGroupedBackground))
        }
    }

    private func promptCard(_ title: String, symbol: String, text: Binding<String>, id: String) -> some View {
        let isExpanded = expandedPrompt == id
        return VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    expandedPrompt = isExpanded ? nil : id
                }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .medium))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(title)
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                        if !isExpanded {
                            Text(text.wrappedValue)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isExpanded {
                TextEditor(text: text)
                    .font(.system(size: 14))
                    .scrollContentBackground(.hidden)
                    .frame(height: id == "role" ? 132 : 112)
                    .padding(8)
                    .background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 14))
                    .padding(.top, 14)
                    .transition(.opacity)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background { glassCard(RoundedRectangle(cornerRadius: 22)) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("显示")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)

                    VStack(alignment: .leading, spacing: 18) {
                        HStack(spacing: 12) {
                            Image(systemName: "circle.lefthalf.filled")
                                .font(.system(size: 17, weight: .medium))
                                .frame(width: 36, height: 36)
                                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 11))
                            Text("外观")
                                .font(.system(size: 16, weight: .semibold))
                            Spacer()
                            Text(appearanceName)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                        }
                        Picker("外观", selection: $appearanceMode) {
                        Text("跟随系统").tag("system")
                        Text("浅色").tag("light")
                        Text("深色").tag("dark")
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    .padding(16)
                    .background { glassCard(RoundedRectangle(cornerRadius: 22)) }
                }

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("AI 回复")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.leading, 12)
                        Spacer()
                        Button {
                            library.systemPrompt = PromptDefaults.role
                            library.requestPrompt = PromptDefaults.request
                        } label: {
                            Label("恢复默认", systemImage: "arrow.counterclockwise")
                                .font(.system(size: 12, weight: .medium))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 12)
                                .frame(height: 30)
                                .background { glassCard(Capsule()) }
                        }
                        .buttonStyle(.plain)
                    }

                    promptCard("角色设定", symbol: "person.text.rectangle", text: $library.systemPrompt, id: "role")
                    promptCard("生成要求", symbol: "text.alignleft", text: $library.requestPrompt, id: "request")
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 36)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Color(uiColor: .systemGroupedBackground).ignoresSafeArea())
    }
}

struct MainView: View {
    @EnvironmentObject private var library: PhraseLibrary
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("appearanceMode") private var appearanceMode = "system"
    @State private var input = ""
    @State private var settingsPresented = false
    @State private var savedPresented = false
    @State private var edgeSettingsPresented = false
    @State private var wordHistoryPresented = false
    @State private var grammarHistoryPresented = false
    @StateObject private var speech = SpeechInputController()
    @State private var toast: String?
    @State private var didInitialHistoryScroll = false
    @State private var ignoreLateSpeechTranscript = false
    @State private var openPhraseSwipeID: UUID?
    @State private var phraseSwipeOffset: CGFloat = 0
    @State private var phraseSwipeStartOffset: CGFloat = 0
    @State private var phraseSwipeDragID: UUID?
    @State private var suppressPhraseActions = false
    @State private var phraseActionSuppressionToken: UUID?
    @State private var isSelectingTurns = false
    @State private var selectedTurnIDs: Set<UUID> = []
    @State private var pendingExpandedTurnID: UUID?
    @State private var openSwipeTurnID: UUID?
    @State private var swipeDragTurnID: UUID?
    @State private var swipeOffset: CGFloat = 0
    @State private var swipeStartOffset: CGFloat = 0
    private let swipeRevealWidth: CGFloat = 96
    private let phraseSaveRevealWidth: CGFloat = 88
    @FocusState private var inputFocused: Bool

    private let ink = Color.primary
    private let secondary = Color.secondary
    private let canvas = Color(uiColor: .systemBackground)
    private let control = Color(uiColor: .secondarySystemBackground)

    private var preferredAppearance: ColorScheme? {
        switch appearanceMode {
        case "light": .light
        case "dark": .dark
        default: nil
        }
    }

    private var inputIsEmpty: Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var latestTurnScrollKey: String {
        guard let latest = library.turns.last else { return "empty" }
        return "\(library.turns.count)-\(latest.id.uuidString)-\(latest.isLoading)-\(latest.phrases.count)-\(latest.message ?? "")"
    }

    @ViewBuilder
    private func glassSurface<S: Shape>(_ shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(iOS 26.0, *) {
            let baseGlass = tint.map { Glass.regular.tint($0) } ?? Glass.regular
            Color.clear.glassEffect(interactive ? baseGlass.interactive() : baseGlass, in: shape)
        } else {
            shape.fill(.ultraThinMaterial)
                .overlay {
                    if let tint {
                        shape.fill(tint.opacity(0.14))
                    }
                }
        }
    }

    private func headerButtonIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(secondary.opacity(0.82))
            .frame(width: 38, height: 38)
            .background { glassSurface(Circle(), interactive: true) }
            .contentShape(Circle())
    }

    private func selectionButtonLabel(_ title: String, symbol: String, color: Color = .primary, glassTint: Color? = nil) -> some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, 13)
            .frame(height: 38)
            .background { glassSurface(Capsule(), tint: glassTint, interactive: true) }
            .contentShape(Capsule())
    }

    private func showEdgeSettings() {
        withAnimation(.easeInOut(duration: 0.28)) {
            edgeSettingsPresented = true
        }
    }

    private func closeEdgeSettings() {
        withAnimation(.easeInOut(duration: 0.28)) {
            edgeSettingsPresented = false
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    if isSelectingTurns {
                        Button {
                            isSelectingTurns = false
                            selectedTurnIDs.removeAll()
                        } label: {
                            selectionButtonLabel("取消", symbol: "xmark", color: secondary)
                        }
                        .buttonStyle(.plain)

                        Button {
                            selectedTurnIDs = Set(library.turns.map(\.id))
                        } label: {
                            selectionButtonLabel("全选", symbol: "checkmark.circle")
                        }
                        .buttonStyle(.plain)
                        .disabled(library.turns.isEmpty)

                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                library.deleteTurns(selectedTurnIDs)
                                selectedTurnIDs.removeAll()
                                isSelectingTurns = false
                            }
                        } label: {
                            selectionButtonLabel(
                                "删除 \(selectedTurnIDs.count)",
                                symbol: "trash",
                                color: selectedTurnIDs.isEmpty ? secondary : .red,
                                glassTint: selectedTurnIDs.isEmpty ? nil : .red.opacity(0.12)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(selectedTurnIDs.isEmpty)
                        .accessibilityLabel("删除所选记录")
                    } else {
                        Button {
                            isSelectingTurns = true
                            selectedTurnIDs.removeAll()
                            openSwipeTurnID = nil
                            swipeOffset = 0
                        } label: {
                            headerButtonIcon("checklist")
                        }
                        .accessibilityLabel("多选记录")

                        Button { wordHistoryPresented = true } label: {
                            headerButtonIcon("text.magnifyingglass")
                        }
                        .accessibilityLabel("单词查询记录")

                        Button { grammarHistoryPresented = true } label: {
                            headerButtonIcon("text.alignleft")
                        }
                        .accessibilityLabel("语法分析记录")

                    }
                }
                .padding(.horizontal, 26)
                .padding(.top, 10)
                .padding(.bottom, 10)
                .background(canvas)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded { inputFocused = false })

                ScrollViewReader { scrollProxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            ForEach(Array(library.turns.enumerated()), id: \.element.id) { turnIndex, turn in
                                historyRow(turn, index: turnIndex, total: library.turns.count) { turnID, targetID in
                                    pendingExpandedTurnID = turnID
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.22) {
                                        guard pendingExpandedTurnID == turnID,
                                              library.turns.first(where: { $0.id == turnID })?.isExpanded == true else { return }
                                        pendingExpandedTurnID = nil
                                        withAnimation(.easeInOut(duration: 0.22)) {
                                            scrollProxy.scrollTo(targetID, anchor: .bottom)
                                        }
                                    }
                                }
                                .id(turn.id)
                            }
                        }
                        .frame(maxWidth: .infinity, minHeight: 1, alignment: .topLeading)
                        .padding(.horizontal, 26)
                        .padding(.top, 18)
                        .padding(.bottom, 28)

                        Color.clear
                            .frame(height: 1)
                            .id("history-bottom")
                    }
                    .scrollIndicators(.hidden)
                    .scrollDismissesKeyboard(.immediately)
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { inputFocused = false })
                    .onChange(of: latestTurnScrollKey) { _, _ in
                        DispatchQueue.main.async {
                            withAnimation(.easeOut(duration: 0.25)) {
                                scrollProxy.scrollTo("history-bottom", anchor: .bottom)
                            }
                        }
                    }
                    .onAppear {
                        guard !didInitialHistoryScroll else { return }
                        didInitialHistoryScroll = true
                        DispatchQueue.main.async {
                            scrollProxy.scrollTo("history-bottom", anchor: .bottom)
                        }
                    }
                    .onChange(of: scenePhase) { _, phase in
                        guard phase == .active else { return }
                        library.collapseAllTurns()
                        DispatchQueue.main.async {
                            scrollProxy.scrollTo("history-bottom", anchor: .bottom)
                        }
                    }
                }

                inputBar
            }
            .background(canvas.ignoresSafeArea())
            .overlay {
                GeometryReader { geometry in
                    ZStack {
                        HStack(spacing: 0) {
                            Color.clear
                                .frame(width: 24)
                                .contentShape(Rectangle())
                                .simultaneousGesture(
                                    DragGesture(minimumDistance: 18, coordinateSpace: .global)
                                        .onEnded { value in
                                            guard value.translation.width > 64,
                                                  value.translation.width > abs(value.translation.height) * 1.3 else { return }
                                            showEdgeSettings()
                                        }
                                )

                            Spacer(minLength: 0)

                            Color.clear
                                .frame(width: 24)
                                .contentShape(Rectangle())
                                .simultaneousGesture(
                                    DragGesture(minimumDistance: 18, coordinateSpace: .global)
                                        .onEnded { value in
                                            guard value.translation.width < -64,
                                                  abs(value.translation.width) > abs(value.translation.height) * 1.3 else { return }
                                            savedPresented = true
                                        }
                                )
                        }

                        if edgeSettingsPresented {
                            VStack(spacing: 0) {
                                HStack {
                                    Button(action: closeEdgeSettings) {
                                        Image(systemName: "chevron.left")
                                            .font(.system(size: 16, weight: .semibold))
                                            .foregroundStyle(ink)
                                            .frame(width: 38, height: 38)
                                            .background { glassSurface(Circle(), interactive: true) }
                                            .contentShape(Circle())
                                    }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("返回")
                                    Spacer()
                                    Text("设置")
                                        .font(.system(size: 17, weight: .semibold))
                                    Spacer()
                                    Color.clear.frame(width: 38, height: 38)
                                }
                                .padding(.horizontal, 16)
                                .frame(height: 56)
                                .background(canvas)

                                SettingsContentView().environmentObject(library)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(canvas.ignoresSafeArea())
                            .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading)))
                            .simultaneousGesture(
                                DragGesture(minimumDistance: 20)
                                    .onEnded { value in
                                        guard value.startLocation.x >= geometry.size.width - 28,
                                              value.translation.width < -70,
                                              abs(value.translation.width) > abs(value.translation.height) * 1.3 else { return }
                                        closeEdgeSettings()
                                    }
                            )
                            .zIndex(1)
                        }
                    }
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .navigationDestination(isPresented: $settingsPresented) {
                SettingsView().environmentObject(library)
            }
            .navigationDestination(isPresented: $savedPresented) {
                SavedPhrasesView().environmentObject(library)
            }
            .navigationDestination(isPresented: $wordHistoryPresented) {
                WordHistoryView().environmentObject(library)
            }
            .navigationDestination(isPresented: $grammarHistoryPresented) {
                GrammarHistoryView().environmentObject(library)
            }
            .toolbar(.hidden, for: .navigationBar)
        }
        .foregroundStyle(ink)
        .preferredColorScheme(preferredAppearance)
        .onChange(of: speech.transcript) { _, transcript in
            if !ignoreLateSpeechTranscript && !transcript.isEmpty {
                input = transcript
            }
        }
    }

    private func historyRow(_ turn: PracticeTurn, index: Int, total: Int, onExpand: @escaping (UUID, UUID) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack(alignment: .leading) {
                if isSelectingTurns {
                    Button {
                        if selectedTurnIDs.contains(turn.id) {
                            selectedTurnIDs.remove(turn.id)
                        } else {
                            selectedTurnIDs.insert(turn.id)
                        }
                    } label: {
                        HStack(alignment: .firstTextBaseline, spacing: 12) {
                            Image(systemName: selectedTurnIDs.contains(turn.id) ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 19, weight: .regular))
                                .foregroundStyle(selectedTurnIDs.contains(turn.id) ? ink : secondary.opacity(0.45))
                            Text(turn.chinese)
                                .font(.system(size: 16, weight: .medium))
                                .foregroundStyle(ink)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 44)
                    .background(canvas)
                } else {
                    HStack(alignment: .center, spacing: 10) {
                        Text(turn.chinese)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(ink)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            let willExpand = !turn.isExpanded
                            withAnimation(.easeInOut(duration: 0.2)) {
                                library.toggleExpanded(turn.id)
                            }
                            if willExpand {
                                onExpand(turn.id, turn.phrases.last?.id ?? turn.id)
                            }
                        } label: {
                            Image(systemName: turn.isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(secondary.opacity(0.75))
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(turn.isExpanded ? "折叠这条记录" : "展开这条记录")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .frame(minHeight: 44)
                    .background(canvas)
                    .offset(x: openSwipeTurnID == turn.id ? swipeOffset : 0)
                    .contentShape(Rectangle())
                }

                if !isSelectingTurns {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            library.deleteTurn(turn.id)
                            openSwipeTurnID = nil
                            swipeOffset = 0
                        }
                    } label: {
                        HStack(spacing: 0) {
                            Spacer(minLength: 0)
                            VStack(spacing: 4) {
                                Image(systemName: "trash")
                                    .font(.system(size: 15, weight: .semibold))
                                Text("删除")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                            .foregroundStyle(.white)
                            .frame(width: 68, height: 54)
                            .background(
                                Color(red: 0.84, green: 0.27, blue: 0.27),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                            )
                            .shadow(color: Color.red.opacity(0.12), radius: 5, y: 2)
                        }
                        .padding(.trailing, 16)
                        .frame(width: swipeRevealWidth)
                        .frame(maxHeight: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("删除这条记录")
                    .offset(x: openSwipeTurnID == turn.id ? swipeOffset - swipeRevealWidth : -swipeRevealWidth)
                    .allowsHitTesting(openSwipeTurnID == turn.id)
                    .zIndex(1)
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(
                    DragGesture(minimumDistance: 24)
                        .onChanged { value in
                            guard !isSelectingTurns else { return }
                            guard abs(value.translation.width) > max(24, abs(value.translation.height) * 1.7) else { return }
                            if swipeDragTurnID != turn.id {
                                swipeDragTurnID = turn.id
                                swipeStartOffset = openSwipeTurnID == turn.id ? swipeOffset : 0
                                openSwipeTurnID = turn.id
                            }
                            swipeOffset = min(swipeRevealWidth, max(0, swipeStartOffset + value.translation.width))
                        }
                        .onEnded { value in
                            guard !isSelectingTurns else { return }
                            guard abs(value.translation.width) > max(24, abs(value.translation.height) * 1.7) else {
                                swipeDragTurnID = nil
                                return
                            }
                            let shouldOpenDelete = value.translation.width > 44
                            withAnimation(.spring(response: 0.32, dampingFraction: 0.88)) {
                                swipeOffset = shouldOpenDelete ? swipeRevealWidth : 0
                                openSwipeTurnID = swipeOffset == 0 ? nil : turn.id
                                if shouldOpenDelete {
                                    library.collapse(turn.id)
                                }
                            }
                            swipeDragTurnID = nil
                        }
                )
            .clipped()

            if turn.isExpanded {
                if turn.isLoading {
                    ProgressView()
                        .tint(secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if !turn.phrases.isEmpty {
                    VStack(alignment: .leading, spacing: 24) {
                        ForEach(Array(turn.phrases.enumerated()), id: \.element.id) { phraseIndex, phrase in
                            expression(phrase, index: phraseIndex + 1, count: turn.phrases.count)
                                .id(phrase.id)
                        }
                    }
                } else if let message = turn.message {
                    Text(message)
                        .font(.system(size: 14))
                        .foregroundStyle(secondary)
                }
            }

            if index < total - 1 {
                Rectangle()
                    .fill(Color.primary.opacity(0.07))
                    .frame(height: 1)
                    .padding(.top, 4)
            }
        }
    }

    private var inputBar: some View {
        VStack(spacing: 8) {
            if let toast {
                Text(toast)
                    .font(.system(size: 12))
                    .foregroundStyle(secondary)
                    .transition(.opacity)
            }
            if !speech.status.isEmpty {
                Text(speech.status)
                    .font(.system(size: 12))
                    .foregroundStyle(secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(alignment: .center, spacing: 10) {
                TextField("", text: $input, axis: .vertical)
                    .font(.system(size: 16))
                    .lineLimit(1...4)
                    .multilineTextAlignment(.leading)
                    .submitLabel(.send)
                    .focused($inputFocused)
                    .onSubmit {
                        if inputIsEmpty { inputFocused = false }
                        else { submit() }
                    }
                    .onChange(of: input) { _, newValue in
                        guard newValue.contains("\n") else { return }
                        input = newValue.replacingOccurrences(of: "\n", with: " ")
                        submit()
                    }
                    .padding(.leading, 12)
                    .padding(.vertical, 12)
                    .frame(minHeight: 54)

                    Button {
                        inputFocused = false
                        if speech.isRecording { speech.stop() }
                        else {
                            ignoreLateSpeechTranscript = false
                            speech.start()
                        }
                    } label: {
                        Image(systemName: speech.isRecording ? "waveform" : "mic")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(speech.isRecording ? Color(uiColor: .systemBackground) : secondary)
                            .frame(width: 40, height: 40)
                            .background { glassSurface(Circle(), tint: speech.isRecording ? ink : nil, interactive: true) }
                    }
                    .accessibilityLabel(speech.isRecording ? "停止语音输入" : "开始语音输入")
                    .contextMenu {
                        Button("DeepSeek 设置", systemImage: "key") { settingsPresented = true }
                    }

                    Button(action: submit) {
                        Image(systemName: "arrow.up")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(!inputIsEmpty && !library.isLoading ? Color.white : secondary.opacity(0.55))
                            .frame(width: 40, height: 40)
                            .background {
                                glassSurface(
                                    Circle(),
                                    tint: !inputIsEmpty && !library.isLoading ? Color.accentColor : nil,
                                    interactive: true
                                )
                            }
                    }
                    .accessibilityLabel("发送")
                    .padding(.trailing, 6)
            }
            .frame(minHeight: 58)
            .background { glassSurface(RoundedRectangle(cornerRadius: 28)) }
        }
        .padding(.horizontal, 14)
        .padding(.top, 10)
        .padding(.bottom, 8)
        .background(canvas)
    }

    private func submit() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !library.isLoading else { return }
        guard library.apiKeyConfigured else {
            settingsPresented = true
            return
        }
        ignoreLateSpeechTranscript = true
        if speech.isRecording { speech.stop() }
        inputFocused = false
        input = ""
        Task { await library.practice(text) }
    }

    private func expression(_ phrase: Phrase, index: Int, count: Int) -> some View {
        let isPhraseSwipeOpen = openPhraseSwipeID == phrase.id
        let isSaved = library.contains(phrase)
        return VStack(alignment: .leading, spacing: 9) {
            ZStack(alignment: .trailing) {
                Button {
                    library.toggleSaved(phrase)
                    showToast(isSaved ? "已取消收藏" : "已收藏")
                    closePhraseSwipe(phrase.id)
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                            .font(.system(size: 15, weight: .semibold))
                        Text(isSaved ? "已收藏" : "收藏")
                            .font(.system(size: 11, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .frame(width: 68, height: 54)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isSaved ? "取消收藏表达" : "收藏表达")
                .frame(width: phraseSaveRevealWidth)
                .frame(maxHeight: .infinity)
                .offset(x: phraseSaveRevealWidth + (isPhraseSwipeOpen ? phraseSwipeOffset : 0))
                .allowsHitTesting(isPhraseSwipeOpen && phraseSwipeOffset < -phraseSaveRevealWidth / 2)
                .zIndex(1)

                WordFlowLayout(spacing: 5) {
                    ForEach(Array(phrase.english.split(whereSeparator: \.isWhitespace).enumerated()), id: \.offset) { _, token in
                        WordTokenButton(token: String(token), color: ink, interactionDisabled: suppressPhraseActions)
                    }
                    Button {
                        guard !suppressPhraseActions else { return }
                        library.speak(phrase)
                    } label: {
                        Image(systemName: library.speakingPhraseID == phrase.id ? "stop.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(secondary)
                            .frame(width: 28, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(library.speakingPhraseID == phrase.id ? "停止朗读" : "播放英式英语发音")
                    Button {
                        guard !suppressPhraseActions else { return }
                        library.startGrammarAnalysis(for: phrase)
                    } label: {
                        Image(systemName: "textformat.abc")
                            .font(.system(size: 15, weight: .medium))
                            .foregroundStyle(secondary)
                            .frame(width: 28, height: 30)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("分析英语语法")
                    .popover(isPresented: grammarPopoverBinding(for: phrase.id), attachmentAnchor: .rect(.bounds), arrowEdge: .top) {
                        grammarPopover(for: phrase)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 6)
                .background {
                    RoundedRectangle(cornerRadius: 11)
                        .fill(Color.primary.opacity(isPhraseSwipeOpen ? 0.06 : 0))
                        .padding(-6)
                }
                .offset(x: isPhraseSwipeOpen ? phraseSwipeOffset : 0)
                .contentShape(Rectangle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipped()
            .simultaneousGesture(
                DragGesture(minimumDistance: 22)
                    .onChanged { value in
                        guard abs(value.translation.width) > max(22, abs(value.translation.height) * 1.6) else { return }
                        suppressPhraseActions = true
                        if phraseSwipeDragID != phrase.id {
                            phraseSwipeDragID = phrase.id
                            phraseSwipeStartOffset = openPhraseSwipeID == phrase.id ? phraseSwipeOffset : 0
                        }
                        if openPhraseSwipeID != phrase.id {
                            guard value.translation.width < 0 else { return }
                            openPhraseSwipeID = phrase.id
                        }
                        phraseSwipeOffset = min(0, max(-phraseSaveRevealWidth, phraseSwipeStartOffset + value.translation.width))
                    }
                    .onEnded { value in
                        if abs(value.translation.width) > max(22, abs(value.translation.height) * 1.6) {
                            let endingOffset = min(0, max(-phraseSaveRevealWidth, phraseSwipeStartOffset + value.translation.width))
                            let shouldRemainOpen = phraseSwipeStartOffset < 0
                                ? endingOffset < -phraseSaveRevealWidth / 2
                                : value.translation.width < -36
                            if shouldRemainOpen {
                                withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
                                    openPhraseSwipeID = phrase.id
                                    phraseSwipeOffset = -phraseSaveRevealWidth
                                }
                            } else {
                                closePhraseSwipe(phrase.id)
                            }
                        }
                        phraseSwipeDragID = nil
                        releasePhraseActionSuppressionSoon()
                    }
            )
            Text(phrase.note)
                .font(.system(size: 13))
                .foregroundStyle(secondary)
            Text(phrase.example)
                .font(.system(size: 14))
                .foregroundStyle(secondary)
                .fixedSize(horizontal: false, vertical: true)
            if index < count {
                Rectangle()
                    .fill(Color.primary.opacity(0.08))
                    .frame(height: 1)
                    .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func showToast(_ text: String) {
        withAnimation { toast = text }
        Task {
            try? await Task.sleep(for: .seconds(1.8))
            withAnimation { toast = nil }
        }
    }

    private func grammarPopoverBinding(for phraseID: UUID) -> Binding<Bool> {
        Binding(
            get: { library.activeGrammarPhraseID == phraseID },
            set: { isPresented in
                if !isPresented { library.dismissGrammarAnalysis(phraseID: phraseID) }
            }
        )
    }

    private func grammarPopover(for phrase: Phrase) -> some View {
        VStack(alignment: .center, spacing: 12) {
            Text("语法分析")
                .font(.system(size: 17, weight: .semibold))
            Text(phrase.english)
                .font(.system(size: 14, weight: .medium, design: .serif))
                .foregroundStyle(secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Rectangle()
                .fill(Color.primary.opacity(0.08))
                .frame(height: 1)
            if library.isGrammarAnalysisLoading {
                ProgressView()
                Text("正在分析句子结构…")
                    .font(.system(size: 13))
                    .foregroundStyle(secondary)
            } else if let analysis = library.grammarAnalysis {
                ScrollView {
                    Text(analysis)
                        .font(.system(size: 14))
                        .foregroundStyle(ink)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 240)
            } else if let error = library.grammarAnalysisError {
                Text(error)
                    .font(.system(size: 14))
                    .foregroundStyle(secondary)
                    .multilineTextAlignment(.center)
                Button("重试") {
                    library.startGrammarAnalysis(for: phrase)
                }
                .font(.system(size: 14, weight: .medium))
            }
        }
        .padding(16)
        .frame(width: 280)
        .presentationCompactAdaptation(.popover)
    }

    private func releasePhraseActionSuppressionSoon() {
        let token = UUID()
        phraseActionSuppressionToken = token
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            guard phraseActionSuppressionToken == token else { return }
            suppressPhraseActions = false
            phraseActionSuppressionToken = nil
        }
    }

    private func closePhraseSwipe(_ id: UUID) {
        guard openPhraseSwipeID == id else { return }
        withAnimation(.spring(response: 0.32, dampingFraction: 0.86), completionCriteria: .logicallyComplete) {
            phraseSwipeOffset = 0
        } completion: {
            if openPhraseSwipeID == id {
                openPhraseSwipeID = nil
            }
        }
    }
}

private struct SavedPhrasesView: View {
    @EnvironmentObject private var library: PhraseLibrary
    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []

    var body: some View {
        Group {
            if library.saved.isEmpty {
                ContentUnavailableView("还没有收藏", systemImage: "bookmark", description: Text("左滑喜欢的英文表达即可收藏。"))
            } else {
                List {
                    ForEach(library.saved) { phrase in
                        HStack(spacing: 12) {
                            if isSelecting {
                                Button { toggleSelection(phrase.id) } label: {
                                    Image(systemName: selectedIDs.contains(phrase.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 21))
                                        .foregroundStyle(selectedIDs.contains(phrase.id) ? Color.accentColor : Color.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            VStack(alignment: .leading, spacing: 7) {
                                Text(phrase.english)
                                    .font(.system(size: 19, weight: .medium, design: .serif))
                                Text(phrase.chinese)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                                Text(phrase.note)
                                    .font(.system(size: 13))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 6)
                        .contextMenu {
                            Button("取消收藏", systemImage: "bookmark.slash", role: .destructive) {
                                library.toggleSaved(phrase)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("收藏")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if !library.saved.isEmpty {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if isSelecting {
                        Button("全选") {
                            selectedIDs = Set(library.saved.map(\.id))
                        }
                        Button(role: .destructive) {
                            library.deleteSavedPhrases(selectedIDs)
                            selectedIDs.removeAll()
                            isSelecting = false
                        } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(selectedIDs.isEmpty)
                        Button("完成") {
                            isSelecting = false
                            selectedIDs.removeAll()
                        }
                    } else {
                        Button("选择") { isSelecting = true }
                    }
                }
            }
        }
    }

    private func toggleSelection(_ id: UUID) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) }
        else { selectedIDs.insert(id) }
    }
}

private struct WordHistoryView: View {
    @EnvironmentObject private var library: PhraseLibrary
    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []

    var body: some View {
        Group {
            if library.wordHistory.isEmpty {
                ContentUnavailableView("还没有单词记录", systemImage: "text.magnifyingglass", description: Text("查询过的单词会保存在这里。"))
            } else {
                List {
                    ForEach(library.wordHistory) { entry in
                        HStack(spacing: 12) {
                            if isSelecting {
                                Button { toggleSelection(entry.id) } label: {
                                    Image(systemName: selectedIDs.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 21))
                                        .foregroundStyle(selectedIDs.contains(entry.id) ? Color.accentColor : Color.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            VStack(alignment: .leading, spacing: 6) {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text(entry.word)
                                        .font(.system(size: 20, weight: .semibold, design: .serif))
                                    Text(entry.ipa)
                                        .font(.system(size: 14))
                                        .foregroundStyle(.secondary)
                                }
                                Text(entry.meaning)
                                    .font(.system(size: 15))
                                Text("查询 \(entry.count) 次 · \(entry.date.formatted(date: .numeric, time: .shortened))")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.vertical, 5)
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("单词记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if !library.wordHistory.isEmpty {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if isSelecting {
                        Button("全选") {
                            selectedIDs = Set(library.wordHistory.map(\.id))
                        }
                        Button(role: .destructive) {
                            library.deleteWordHistory(selectedIDs)
                            selectedIDs.removeAll()
                            isSelecting = false
                        } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(selectedIDs.isEmpty)
                        Button("完成") {
                            isSelecting = false
                            selectedIDs.removeAll()
                        }
                    } else {
                        Button("选择") { isSelecting = true }
                    }
                }
            }
        }
    }

    private func toggleSelection(_ id: UUID) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) }
        else { selectedIDs.insert(id) }
    }
}

private struct GrammarHistoryView: View {
    @EnvironmentObject private var library: PhraseLibrary
    @State private var expandedIDs: Set<UUID> = []
    @State private var isSelecting = false
    @State private var selectedIDs: Set<UUID> = []

    var body: some View {
        Group {
            if library.grammarHistory.isEmpty {
                ContentUnavailableView("还没有语法记录", systemImage: "text.alignleft", description: Text("分析过的英语句子会保存在这里。"))
            } else {
                List {
                    ForEach(library.grammarHistory) { entry in
                        HStack(spacing: 12) {
                            if isSelecting {
                                Button { toggleSelection(entry.id) } label: {
                                    Image(systemName: selectedIDs.contains(entry.id) ? "checkmark.circle.fill" : "circle")
                                        .font(.system(size: 21))
                                        .foregroundStyle(selectedIDs.contains(entry.id) ? Color.accentColor : Color.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            VStack(alignment: .leading, spacing: 0) {
                                Button {
                                    if expandedIDs.contains(entry.id) { expandedIDs.remove(entry.id) }
                                    else { expandedIDs.insert(entry.id) }
                                } label: {
                                    HStack(spacing: 12) {
                                        VStack(alignment: .leading, spacing: 6) {
                                            Text(entry.english)
                                                .font(.system(size: 17, weight: .medium, design: .serif))
                                                .fixedSize(horizontal: false, vertical: true)
                                            Text(entry.chinese)
                                                .font(.system(size: 13))
                                                .foregroundStyle(.secondary)
                                            Text("分析 \(entry.count) 次 · \(entry.date.formatted(date: .numeric, time: .shortened))")
                                                .font(.system(size: 11))
                                                .foregroundStyle(.tertiary)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        Image(systemName: expandedIDs.contains(entry.id) ? "chevron.up" : "chevron.down")
                                            .font(.system(size: 12, weight: .medium))
                                            .foregroundStyle(.tertiary)
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                if expandedIDs.contains(entry.id) {
                                    Text(entry.analysis)
                                        .font(.system(size: 14))
                                        .foregroundStyle(.primary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.top, 12)
                                        .padding(.bottom, 4)
                                }
                            }
                            .padding(.vertical, 5)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
        .navigationTitle("语法记录")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(.visible, for: .navigationBar)
        .toolbar {
            if !library.grammarHistory.isEmpty {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if isSelecting {
                        Button("全选") {
                            selectedIDs = Set(library.grammarHistory.map(\.id))
                        }
                        Button(role: .destructive) {
                            expandedIDs.subtract(selectedIDs)
                            library.deleteGrammarHistory(selectedIDs)
                            selectedIDs.removeAll()
                            isSelecting = false
                        } label: {
                            Image(systemName: "trash")
                        }
                        .disabled(selectedIDs.isEmpty)
                        Button("完成") {
                            isSelecting = false
                            selectedIDs.removeAll()
                        }
                    } else {
                        Button("选择") { isSelecting = true }
                    }
                }
            }
        }
    }

    private func toggleSelection(_ id: UUID) {
        if selectedIDs.contains(id) { selectedIDs.remove(id) }
        else { selectedIDs.insert(id) }
    }
}

@MainActor
private final class SpeechInputController: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var transcript = ""
    @Published var status = ""

    private let engine = AVAudioEngine()
    private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "zh-CN"))
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var macRecorder: AVAudioRecorder?
    private var macRecordingURL: URL?

    private enum AudioCaptureError: LocalizedError {
        case activationFailed
        case inputUnavailable
        case recordingFailed

        var errorDescription: String? {
            switch self {
            case .activationFailed:
                return "系统未能启动麦克风音频会话。"
            case .inputUnavailable:
                return "系统没有提供可用的麦克风音频输入。"
            case .recordingFailed:
                return "系统没有开始录音，请检查麦克风后重试。"
            }
        }
    }

    func start() {
        guard !isRecording else { return }
        status = ""
        SFSpeechRecognizer.requestAuthorization { [weak self] authorization in
            Task { @MainActor in
                guard authorization == .authorized else {
                    self?.status = "请在系统设置中允许语音识别。"
                    return
                }
                AVAudioApplication.requestRecordPermission { granted in
                    Task { @MainActor in
                        guard granted else {
                            self?.status = "请在系统设置中允许麦克风访问。"
                            return
                        }
                        Task { await self?.beginRecording() }
                    }
                }
            }
        }
    }

    func stop() {
        guard isRecording else { return }
        if let recorder = macRecorder, let url = macRecordingURL {
            recorder.stop()
            macRecorder = nil
            isRecording = false
            transcribeMacRecording(at: url)
            return
        }
        engine.stop()
        engine.inputNode.removeTap(onBus: 0)
        recognitionRequest?.endAudio()
        isRecording = false
        Task { await deactivateAudioSession() }
    }

    private func beginRecording() async {
        guard let recognizer, recognizer.isAvailable else {
            status = "语音识别暂不可用，请稍后再试。"
            return
        }
        do {
            if ProcessInfo.processInfo.isiOSAppOnMac {
                let audioSession = AVAudioSession.sharedInstance()
                try audioSession.setCategory(.record, options: [])
                try audioSession.setActive(true)

                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("speakeasy-\(UUID().uuidString).wav")
                let settings: [String: Any] = [
                    AVFormatIDKey: Int(kAudioFormatLinearPCM),
                    AVLinearPCMIsNonInterleaved: false,
                    AVSampleRateKey: 44_100.0,
                    AVNumberOfChannelsKey: 1,
                    AVLinearPCMBitDepthKey: 16
                ]
                let recorder = try AVAudioRecorder(url: url, settings: settings)
                guard recorder.record() else { throw AudioCaptureError.recordingFailed }
                transcript = ""
                macRecordingURL = url
                macRecorder = recorder
                isRecording = true
                return
            }

            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try await activateAudioSession()

            let inputNode = engine.inputNode
            let format = inputNode.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else {
                throw AudioCaptureError.inputUnavailable
            }

            let request = SFSpeechAudioBufferRecognitionRequest()
            request.shouldReportPartialResults = true
            recognitionRequest = request
            inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
                request.append(buffer)
            }
            engine.prepare()
            try engine.start()
            transcript = ""
            isRecording = true
            recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
                Task { @MainActor in
                    if let result { self?.transcript = result.bestTranscription.formattedString }
                    if error != nil { self?.stop() }
                }
            }
        } catch {
            if let captureError = error as? AudioCaptureError,
               case .inputUnavailable = captureError {
                status = captureError.localizedDescription
            } else {
                status = "语音输入启动失败：\(error.localizedDescription)"
            }
            if engine.isRunning { engine.stop() }
            if recognitionRequest != nil { engine.inputNode.removeTap(onBus: 0) }
            recognitionRequest?.endAudio()
            recognitionTask?.cancel()
            recognitionRequest = nil
            isRecording = false
            Task { await deactivateAudioSession() }
        }
    }

    private func transcribeMacRecording(at url: URL) {
        guard let recognizer else {
            status = "语音识别暂不可用，请稍后再试。"
            finishMacRecording(at: url)
            return
        }

        status = "正在识别语音…"
        let request = SFSpeechURLRecognitionRequest(url: url)
        request.shouldReportPartialResults = false
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor in
                if let result {
                    self?.transcript = result.bestTranscription.formattedString
                    if result.isFinal {
                        self?.status = ""
                        self?.finishMacRecording(at: url)
                    }
                }
                if let error {
                    self?.status = "语音识别失败：\(error.localizedDescription)"
                    self?.finishMacRecording(at: url)
                }
            }
        }
    }

    private func finishMacRecording(at url: URL) {
        try? FileManager.default.removeItem(at: url)
        macRecordingURL = nil
        recognitionTask = nil
        Task { await deactivateAudioSession() }
    }

    private func activateAudioSession() async throws {
        let audioSession = AVAudioSession.sharedInstance()
        if #available(iOS 27.0, *) {
            let activated = try await audioSession.activate(options: [])
            guard activated else { throw AudioCaptureError.activationFailed }
        } else {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try audioSession.setActive(true)
                        continuation.resume()
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        }
    }

    private func deactivateAudioSession() async {
        let audioSession = AVAudioSession.sharedInstance()
        if ProcessInfo.processInfo.isiOSAppOnMac {
            try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
        } else if #available(iOS 27.0, *) {
            _ = try? await audioSession.deactivate(options: [.notifyOthersOnDeactivation])
        } else {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .utility).async {
                    try? audioSession.setActive(false, options: .notifyOthersOnDeactivation)
                    continuation.resume()
                }
            }
        }
    }
}

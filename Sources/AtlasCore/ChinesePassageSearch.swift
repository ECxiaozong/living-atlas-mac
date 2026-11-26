import Accelerate
import CoreML
import Foundation
import GRDB

/// Optional, offline retrieval over the same chunk IDs and permission set as the lexical index.
final class ChinesePassageSearch {
  static let shared = try? ChinesePassageSearch()
  private let vocabulary: [String: Int32]
  private let predictionLock = NSLock()
  private let model: MLModel
  private let compiledURL: URL
  private let length = 128

  private init() throws {
    guard let directory = Bundle.module.url(forResource: "ChineseSearch", withExtension: nil) else {
      throw CocoaError(.fileNoSuchFile)
    }
    let words = try String(contentsOf: directory.appendingPathComponent("vocab.txt"), encoding: .utf8)
    vocabulary = Dictionary(words.components(separatedBy: "\n").enumerated().map {
      (String($0.element), Int32($0.offset))
    }, uniquingKeysWith: { first, _ in first })
    compiledURL = try MLModel.compileModel(at: directory.appendingPathComponent("ChinesePassage.mlpackage"))
    let configuration = MLModelConfiguration()
    configuration.computeUnits = .cpuOnly
    model = try MLModel(contentsOf: compiledURL, configuration: configuration)
  }

  deinit { try? FileManager.default.removeItem(at: compiledURL) }

  static func han(_ text: String) -> [String] {
    var seen = Set<Unicode.Scalar>()
    return text.unicodeScalars.compactMap {
      isHan($0) && seen.insert($0).inserted ? String($0) : nil
    }
  }

  private static func isHan(_ scalar: Unicode.Scalar) -> Bool {
    (0x3400...0x9fff).contains(scalar.value) || (0x20000...0x323af).contains(scalar.value)
  }

  private func vector(_ text: String) throws -> [Float]? {
    var tokens: [Int32] = [101]
    var word = ""
    func finishWord() {
      defer { word = "" }
      guard !word.isEmpty, tokens.count < length - 1 else { return }
      if let id = vocabulary[word] { tokens.append(id); return }
      guard word.count <= 100 else { tokens.append(100); return }
      var pieces = [Int32]()
      var start = word.startIndex
      while start < word.endIndex {
        var end = word.endIndex
        while end > start {
          let piece = (start == word.startIndex ? "" : "##") + word[start..<end]
          if let id = vocabulary[piece] { pieces.append(id); break }
          end = word.index(before: end)
        }
        guard end > start else { tokens.append(100); return }
        start = end
      }
      tokens.append(contentsOf: pieces.prefix(length - 1 - tokens.count))
    }
    for ch in text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).unicodeScalars {
      if Self.isHan(ch) || CharacterSet.punctuationCharacters.contains(ch) {
        finishWord()
        if tokens.count < length - 1 { tokens.append(vocabulary[String(ch)] ?? 100) }
      } else if CharacterSet.whitespacesAndNewlines.contains(ch) || CharacterSet.controlCharacters.contains(ch) {
        finishWord()
      } else {
        word.unicodeScalars.append(ch)
      }
      if tokens.count >= length - 1 { break }
    }
    finishWord()
    tokens.append(102)
    let input = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
    let ptr = input.dataPointer.assumingMemoryBound(to: Int32.self)
    for i in 0..<length { ptr[i] = i < tokens.count ? tokens[i] : 0 }
    let features = try MLDictionaryFeatureProvider(dictionary: ["tokens": MLFeatureValue(multiArray: input)])
    let prediction = try predictionLock.withLock { try model.prediction(from: features) }
    guard let out = prediction.featureValue(for: "embedding")?.multiArrayValue,
      out.count == 512 else { return nil }
    let values = (0..<512).map { out[$0].floatValue }
    let norm = sqrt(vDSP.sumOfSquares(values))
    guard norm.isFinite && norm > 0 else { return nil }
    return vDSP.divide(values, norm)
  }

  struct Match { let chunk: Int64, key: String, score: Float }

  func rankedChunks(query: String, lexical: [Int64], db: Database) throws -> [Match] {
    guard let question = try? vector("为这个句子生成表示以用于检索相关文章：" + String(query.prefix(160))) else { return [] }
    let chars = Self.han(String(query.prefix(160)))
    guard !chars.isEmpty else { return [] }
    let allowed = "FROM search_chunk c JOIN search_allowed a ON a.key=c.source_reference_id"
    // Exhaust small scopes. In large workspaces bound cold inference as well as candidate memory.
    let small = try Int64.fetchAll(db, sql: "SELECT c.id " + allowed + " ORDER BY c.id LIMIT 97")
    var ids = small
    if small.count > 96 {
      let alternatives = chars.map { "\"" + $0 + "\"" }.joined(separator: " OR ")
      ids = Array(lexical.prefix(24)) + (try Int64.fetchAll(db, sql: """
        SELECT c.id FROM search_han JOIN search_chunk c ON c.id=search_han.rowid
        JOIN search_allowed a ON a.key=c.source_reference_id WHERE search_han MATCH ?
        ORDER BY bm25(search_han),c.id LIMIT 72
        """, arguments: [alternatives]))
    }
    let fetch = try db.cachedStatement(sql: "SELECT c.source_reference_id,c.folded_title,c.text,c.embedding " + allowed + " WHERE c.id=?")
    let save = try db.cachedStatement(sql: "UPDATE search_chunk SET embedding=? WHERE id=?")
    var scored = [Match]()
    for id in Set(ids).sorted() {
      try Task.checkCancellation()
      guard let row = try Row.fetchOne(fetch, arguments: [id]) else { continue }
      let passage: [Float]
      if let data: Data = row["embedding"], data.count == 512 * MemoryLayout<Float>.size {
        passage = data.withUnsafeBytes { buf in (0..<512).map {
          buf.loadUnaligned(fromByteOffset: $0 * MemoryLayout<Float>.size, as: Float.self)
        }}
      } else {
        let title: String = row["folded_title"], text: String = row["text"]
        guard let encoded = try? vector(String(title.prefix(32)) + "。" + String(text.prefix(400))) else { continue }
        passage = encoded
        try save.execute(arguments: [encoded.withUnsafeBytes { Data($0) }, id])
      }
      let similarity = vDSP.dot(question, passage)
      if similarity >= 0.40 {
        scored.append(Match(chunk: id, key: row["source_reference_id"], score: similarity))
      }
    }
    return scored.sorted { $0.score == $1.score ? $0.chunk < $1.chunk : $0.score > $1.score }
  }
}

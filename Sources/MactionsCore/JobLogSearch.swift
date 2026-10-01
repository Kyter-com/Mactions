import Foundation

/// Search preserves the original line numbers, including blank lines. Call off
/// the main actor: retained job logs can contain tens of thousands of lines.
public enum JobLogSearch {
  public struct Line: Identifiable, Sendable, Equatable {
    public let id: Int
    public let text: String
  }

  public static func matchingLines(in lines: [String], query: String) -> [Line] {
    let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    var result: [Line] = []
    for (index, text) in lines.enumerated() {
      guard !Task.isCancelled else { return [] }
      if query.isEmpty || text.range(of: query, options: .caseInsensitive) != nil {
        result.append(Line(id: index, text: text))
      }
    }
    return result
  }
}

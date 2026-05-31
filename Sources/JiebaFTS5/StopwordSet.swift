// StopwordSet.swift
// JiebaFTS5
//
// High-performance flat memory & binary search stopwords container.

import Foundation

/// High-performance container for stopwords.
public struct StopwordSet: Sendable {
    
    private struct WordRange: Sendable {
        let offset: Int
        let length: Int
    }
    
    private let flatBytes: [UInt8]
    private let ranges: [WordRange]

    /// Initializes and normalizes the stopwords.
    public init(stopwords: Set<String>, options: JiebaTokenizerOptions) {
        let normalizedWords = stopwords.compactMap { word -> [UInt8]? in
            let folded = StopwordSet.normalizeWord(word, options: options)
            guard !folded.isEmpty else { return nil }
            return Array(folded.utf8)
        }

        let uniqueNormalizedWords = Set(normalizedWords)

        var sortedWords = Array(uniqueNormalizedWords)
        sortedWords.sort { lhs, rhs in
            let minLen = min(lhs.count, rhs.count)
            for i in 0..<minLen {
                if lhs[i] != rhs[i] {
                    return lhs[i] < rhs[i]
                }
            }
            return lhs.count < rhs.count
        }

        var bytes: [UInt8] = []
        var wordRanges: [WordRange] = []
        bytes.reserveCapacity(sortedWords.reduce(0) { $0 + $1.count })
        wordRanges.reserveCapacity(sortedWords.count)

        for word in sortedWords {
            let offset = bytes.count
            bytes.append(contentsOf: word)
            wordRanges.append(WordRange(offset: offset, length: word.count))
        }

        self.flatBytes = bytes
        self.ranges = wordRanges
    }

    /// Performs a high-performance binary search for the target byte slice.
    @inline(__always)
    public func contains(_ target: UnsafeBufferPointer<UInt8>) -> Bool {
        guard !ranges.isEmpty else { return false }
        return flatBytes.withUnsafeBufferPointer { flatBuf in
            var low = 0
            var high = ranges.count - 1

            while low <= high {
                let mid = (low + high) / 2
                let range = ranges[mid]

                let cmp = compare(target: target, flatBuf: flatBuf, offset: range.offset, length: range.length)
                if cmp == 0 {
                    return true
                } else if cmp < 0 {
                    high = mid - 1
                } else {
                    low = mid + 1
                }
            }
            return false
        }
    }

    /// Search helper for CChar pointer.
    @inline(__always)
    public func contains(_ bytes: UnsafePointer<CChar>, count: Int) -> Bool {
        return bytes.withMemoryRebound(to: UInt8.self, capacity: count) { ptr in
            let buffer = UnsafeBufferPointer(start: ptr, count: count)
            return contains(buffer)
        }
    }

    /// Search helper for UInt8 pointer.
    @inline(__always)
    public func contains(_ bytes: UnsafePointer<UInt8>, count: Int) -> Bool {
        let buffer = UnsafeBufferPointer(start: bytes, count: count)
        return contains(buffer)
    }

    // MARK: - Normalization helper

    /// Normalizes a single stopword. The folding logic MUST exactly match the tokenizer emission logic.
    public static func normalizeWord(_ word: String, options: JiebaTokenizerOptions) -> String {
        var token = word
        if options.widthFolding {
            token = token.precomposedStringWithCompatibilityMapping
        }

        var compareOptions: String.CompareOptions = []
        if options.diacriticFolding {
            compareOptions.insert(.diacriticInsensitive)
        }
        if options.caseFolding {
            compareOptions.insert(.caseInsensitive)
        }

        if !compareOptions.isEmpty {
            token = token.folding(options: compareOptions, locale: nil)
        }
        return token
    }

    @inline(__always)
    private func compare(
        target: UnsafeBufferPointer<UInt8>,
        flatBuf: UnsafeBufferPointer<UInt8>,
        offset: Int,
        length: Int
    ) -> Int {
        let minLen = min(target.count, length)
        guard let tPtr = target.baseAddress,
              let sPtr = flatBuf.baseAddress else { return 0 }
        
        let sStart = sPtr.advanced(by: offset)
        for i in 0..<minLen {
            let tByte = tPtr[i]
            let sByte = sStart[i]
            if tByte < sByte { return -1 }
            if tByte > sByte { return 1 }
        }
        if target.count < length { return -1 }
        if target.count > length { return 1 }
        return 0
    }
}

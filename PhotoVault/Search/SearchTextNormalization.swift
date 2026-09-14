//
//  SearchTextNormalization.swift
//  PhotoVault
//
//  The single definition of what "the same text" means for search.
//
//  Two independent paths have to agree on this: the trigram FTS index and the
//  `instr()` fallback used for queries shorter than three characters. If they
//  normalise differently, a query matches through one path and not the other, and
//  the symptom is a result that appears or vanishes depending on the query's
//  length -- which is very hard to attribute to whitespace.
//
//  Case folding is applied here even though the *tokenizer* must not fold case
//  (SigLIP2 is case sensitive). These are different jobs: the tokenizer prepares
//  text for the model, which was trained to distinguish "CAT" from "cat"; OCR
//  matching is a user typing part of a receipt heading. Applying the model's
//  convention to the search index would be a category error.
//

import Foundation

enum SearchTextNormalization {

    /// Folds text so that both FTS paths agree on what "contains" means.
    ///
    /// - Case and width folding, so "ＩＮＶＯＩＣＥ" and "Invoice" are one thing.
    /// - Whitespace collapsed. Chinese OCR output usually has no spaces at all
    ///   ("发票报销凭证2023年5月"), so this must not *insert* any: the trigram
    ///   tokenizer works on the raw character run, and inserting spaces would
    ///   break matches that span the boundary.
    /// - `nil` for empty or whitespace-only input, so callers cannot accidentally
    ///   index a blank string that then matches every `instr()` query.
    static func normalize(_ text: String?) -> String? {
        guard let text else { return nil }
        let folded = text.folding(
            options: [.caseInsensitive, .widthInsensitive], locale: nil
        )
        let collapsed = folded.split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return collapsed.isEmpty ? nil : collapsed
    }

    /// Splits recognized text into indexable lines, dropping empties.
    ///
    /// Line structure is preserved as a single space rather than a newline: a
    /// phrase that wraps across two visual lines still needs to match.
    static func indexableLines(_ lines: [String]) -> [String] {
        lines.compactMap { normalize($0) }
    }
}

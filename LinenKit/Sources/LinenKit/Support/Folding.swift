import Foundation

extension String {
    /// The string in Unicode Normalization Form C.
    var nfc: String { precomposedStringWithCanonicalMapping }

    /// The comparison key used across the vault code: case folded, then NFC.
    var folded: String {
        folding(options: [.caseInsensitive], locale: nil).precomposedStringWithCanonicalMapping
    }
}

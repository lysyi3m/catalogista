import Foundation
import Testing
@testable import CatalogistaKit

@Suite("Token masking")
struct TokenMaskingTests {
    @Test("A real-length token keeps only its first and last four characters")
    func masksMiddle() {
        let token = "abcdWXYZ1234567890ijklmnop"
        let masked = AppServices.mask(token)

        #expect(masked.hasPrefix("abcd"))
        #expect(masked.hasSuffix("mnop"))
        #expect(!masked.contains("WXYZ1234567890ijkl"), "the middle must not survive")
        #expect(masked.contains("•"))
        #expect(masked != token)
    }

    @Test("A short token is hidden entirely rather than mostly revealed")
    func masksShortTokensCompletely() {
        for token in ["abc", "abcdefgh", "abcdefghijkl"] {
            let masked = AppServices.mask(token)
            #expect(masked.allSatisfy { $0 == "•" }, "\(token) leaked characters")
        }
    }
}

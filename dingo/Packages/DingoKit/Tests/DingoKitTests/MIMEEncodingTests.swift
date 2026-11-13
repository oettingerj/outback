import Foundation
import Testing
@testable import DingoKit

@Suite struct MIMEEncodingTests {
    // MARK: RFC 2047

    @Test func decodesBAndQWords() {
        #expect(EncodedWord.decode("=?UTF-8?B?Q2Fmw6k=?=") == "Café")
        #expect(EncodedWord.decode("=?iso-8859-1?q?caf=E9_au_lait?=") == "café au lait")
        #expect(EncodedWord.decode("=?windows-1252?Q?=80=96?=") == "€–")
        #expect(EncodedWord.decode("=?UTF-8*en?Q?hi?=") == "hi")
        #expect(EncodedWord.decode("plain subject") == "plain subject")
    }

    @Test func whitespaceBetweenAdjacentWordsIsDropped() {
        #expect(EncodedWord.decode("=?UTF-8?Q?a?= =?UTF-8?Q?b?=") == "ab")
        #expect(EncodedWord.decode("=?UTF-8?Q?a?=\r\n =?ISO-8859-1?Q?b?=") == "ab")
        #expect(EncodedWord.decode("=?UTF-8?Q?a?= text =?UTF-8?Q?b?=") == "a text b")
        #expect(EncodedWord.decode("Re: =?UTF-8?Q?Caf=C3=A9?= menu") == "Re: Café menu")
    }

    @Test func multiByteCharacterSplitAcrossWords() {
        // "é" is C3 A9; the sender split it between two words.
        #expect(EncodedWord.decode("=?UTF-8?Q?Caf=C3?= =?UTF-8?Q?=A9?=") == "Café")
    }

    @Test func malformedWordsStayAsWritten() {
        #expect(EncodedWord.decode("=?UTF-8?Q?bad=Z?=") == "=?UTF-8?Q?bad=Z?=")
        #expect(EncodedWord.decode("=?UTF-8?X?abc?=") == "=?UTF-8?X?abc?=")
        #expect(EncodedWord.decode("=?unknown-charset?Q?abc?=") == "abc")
    }

    @Test(arguments: ["Café", "ASCII only", "日本語のメールの件名はとても長くなることがありますので分割が必要です", "🎉 Party 👩‍👩‍👧‍👦", "Price =? maybe"])
    func encodeRoundTrips(_ text: String) {
        let encoded = EncodedWord.encode(text)
        #expect(encoded.allSatisfy { $0.isASCII })
        #expect(EncodedWord.decode(encoded) == text)
        for word in encoded.split(separator: " ") where word.hasPrefix("=?") {
            #expect(word.count <= 75)
        }
    }

    // MARK: Charsets

    @Test func charsetDecoding() {
        #expect(Charset.decode(Data([0x63, 0x61, 0x66, 0xE9]), charset: "iso-8859-1") == "café")
        #expect(Charset.decode(Data([0x80, 0x20, 0x93, 0x71, 0x94]), charset: "ISO-8859-1") == "€ “q”")
        #expect(Charset.decode(Data([0xB1, 0xB9]), charset: "iso-8859-2") == "ąš")
        #expect(Charset.decode(Data([0xC0, 0xE1]), charset: "windows-1251") == "Аб")
        #expect(Charset.decode(Data("Zoë".utf8), charset: "us-ascii") == "Zoë")
        #expect(Charset.decode(Data("Zoë".utf8), charset: "\"UTF-8\"") == "Zoë")
        #expect(Charset.decode(Data("Zoë".utf8), charset: "x-made-up") == "Zoë")
        #expect(Charset.decode(Data([0xEF, 0xBB, 0xBF, 0x68, 0x69]), charset: "utf-8") == "hi")
        // Invalid UTF-8 falls back to windows-1252 rather than failing.
        #expect(Charset.decode(Data([0x63, 0x61, 0x66, 0xE9]), charset: "utf-8") == "café")
        #expect(Charset.decode(Data([0x81, 0x8D]), charset: nil).count == 2)
    }

    // MARK: Quoted-printable and base64url

    @Test func quotedPrintableRoundTrip() {
        let text = "Café = coffee\nTrailing space \n" + String(repeating: "long line ", count: 30) + "\r\nend\t"
        let encoded = QuotedPrintable.encode(text)
        #expect(encoded.allSatisfy { $0.isASCII })
        for line in encoded.components(separatedBy: "\r\n") { #expect(line.utf8.count <= 76) }
        #expect(encoded.hasPrefix("Caf=C3=A9 =3D coffee\r\nTrailing space=20\r\n"))
        #expect(encoded.hasSuffix("end=09"))
        let expected = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
        #expect(String(decoding: QuotedPrintable.decode(encoded), as: UTF8.self) == expected)
    }

    @Test func quotedPrintableDecodesSoftBreaksAndBadEscapes() {
        #expect(String(decoding: QuotedPrintable.decode("soft=\r\nbreak=\nhere =ZZ =4"), as: UTF8.self) == "softbreakhere =ZZ =4")
    }

    @Test func base64URL() {
        let data = Data([0xFB, 0xFF, 0xBF, 0x00, 0x01])
        #expect(data.base64URLEncodedString() == "-_-_AAE")
        #expect(Data(base64URLEncoded: "-_-_AAE") == data)
        #expect(Data(base64URLEncoded: "-_-_AAE=") == data)
        #expect(Data(base64URLEncoded: "SGVs\nbG8") == Data("Hello".utf8))
        #expect(Data(base64URLEncoded: "!!!") == nil)
    }

    // MARK: MIME parameters

    @Test func headerParameters() {
        let type = MIMEHeaderValue(#"Text/HTML; Charset="UTF-8"; name="a;b.html""#)
        #expect(type.value == "text/html")
        #expect(type["charset"] == "UTF-8")
        #expect(type["name"] == "a;b.html")

        let disposition = MIMEHeaderValue("attachment; filename*0*=UTF-8''Re%C3%A7u; filename*1=\"-2041\"; filename*2*=.pdf; filename=\"fallback.pdf\"")
        #expect(disposition.value == "attachment")
        #expect(disposition["filename"] == "Reçu-2041.pdf")

        #expect(MIMEHeaderValue("image/png; name=\"=?UTF-8?B?w6lt?=.png\"")["name"] == "ém.png")
        #expect(MIMEHeaderValue.parameter("filename", "plain.pdf") == #"filename="plain.pdf""#)
        #expect(MIMEHeaderValue.parameter("filename", "Reçu 1.pdf") == "filename*=UTF-8''Re%C3%A7u%201.pdf")
        #expect(MIMEHeaderValue("x; " + MIMEHeaderValue.parameter("filename", "Reçu 1.pdf"))["filename"] == "Reçu 1.pdf")
    }
}

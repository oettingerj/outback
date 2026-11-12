import Foundation
import Testing
@testable import DingoKit

@Suite struct MIMEAddressParserTests {
    @Test func nameAndBareAddresses() {
        #expect(AddressParser.parse("Ada Lovelace <ada@example.com>, grace@example.org") == [
            EmailAddress(name: "Ada Lovelace", email: "ada@example.com"),
            EmailAddress(email: "grace@example.org"),
        ])
    }

    @Test func quotedNamesKeepCommasAndEscapes() {
        #expect(AddressParser.parse(#""Lovelace, Ada" <ada@example.com>, "Grace \"Amazing\" Hopper" <g@example.org>"#) == [
            EmailAddress(name: "Lovelace, Ada", email: "ada@example.com"),
            EmailAddress(name: #"Grace "Amazing" Hopper"#, email: "g@example.org"),
        ])
    }

    @Test func commentsAsNamesAndIgnoredElsewhere() {
        #expect(AddressParser.parse("ada@example.com (Ada Lovelace)") == [EmailAddress(name: "Ada Lovelace", email: "ada@example.com")])
        #expect(AddressParser.parse("Ada (the first (programmer)) Lovelace <ada@example.com>") == [
            EmailAddress(name: "Ada Lovelace", email: "ada@example.com"),
        ])
    }

    @Test func groups() {
        #expect(AddressParser.parse("undisclosed-recipients:;").isEmpty)
        #expect(AddressParser.parse("Team: ada@example.com, Grace <g@example.org>;, alan@example.net") == [
            EmailAddress(email: "ada@example.com"),
            EmailAddress(name: "Grace", email: "g@example.org"),
            EmailAddress(email: "alan@example.net"),
        ])
    }

    @Test func encodedWordNames() {
        #expect(AddressParser.parse("=?UTF-8?Q?Zo=C3=AB_D=C3=BCrr?= <zoe@example.com>") == [EmailAddress(name: "Zoë Dürr", email: "zoe@example.com")])
        // A comma inside an encoded word is part of the name, not a separator.
        #expect(AddressParser.parse("=?ISO-8859-1?Q?Caf=E9=2C_Paris?= <c@example.com>, b@example.com") == [
            EmailAddress(name: "Café, Paris", email: "c@example.com"),
            EmailAddress(email: "b@example.com"),
        ])
    }

    @Test func malformedInput() {
        #expect(AddressParser.parse("").isEmpty)
        #expect(AddressParser.parse(",, ,").isEmpty)
        #expect(AddressParser.parse("not an address").isEmpty)
        #expect(AddressParser.parse("Ada Lovelace ada@example.com") == [EmailAddress(name: "Ada Lovelace", email: "ada@example.com")])
        #expect(AddressParser.parse("'Ada' <ada@example.com>") == [EmailAddress(name: "Ada", email: "ada@example.com")])
        #expect(AddressParser.parse("<ada@example.com>") == [EmailAddress(email: "ada@example.com")])
        #expect(AddressParser.parse("Ada <ada@example.com") == [EmailAddress(name: "Ada", email: "ada@example.com")])
        #expect(AddressParser.parse("<@relay.example:ada@example.com>") == [EmailAddress(email: "ada@example.com")])
        #expect(AddressParser.parse("\"ada lovelace\"@example.com") == [EmailAddress(email: "\"ada lovelace\"@example.com")])
        #expect(AddressParser.parse("Ada\r\n Lovelace <ada@example.com>") == [EmailAddress(name: "Ada Lovelace", email: "ada@example.com")])
    }

    @Test func formattedRoundTrips() {
        let addresses = [
            EmailAddress(name: "Lovelace, Ada", email: "ada@example.com"),
            EmailAddress(name: "Zoë", email: "zoe@example.com"),
            EmailAddress(email: "bare@example.com"),
        ]
        #expect(addresses.map(\.formatted) == [#""Lovelace, Ada" <ada@example.com>"#, "Zoë <zoe@example.com>", "bare@example.com"])
        #expect(AddressParser.parse(addresses.map(\.formatted).joined(separator: ", ")) == addresses)
        #expect(AddressParser.parse(addresses.map(\.headerValue).joined(separator: ", ")) == addresses)
    }
}

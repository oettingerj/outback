import Foundation
import Testing
@testable import DingoKit

@Suite struct ReceiptParserTests {
    typealias F = BucketFixtures

    func parse(from: String, subject: String, html: String? = nil, text: String? = nil) -> Receipt {
        ReceiptParser.parse(F.message(from: from, subject: subject, html: html, text: text))
    }

    @Test func amazonJSONLD() throws {
        let receipt = parse(from: "\"Amazon.com\" <auto-confirm@amazon.com>", subject: "Your Amazon.com order of \"USB-C cable\"",
                            html: try F.fixture("amazon-order.html"))
        #expect(receipt.merchant == "Amazon.com")
        #expect(receipt.amount == Decimal(string: "41.07"))
        #expect(receipt.currency == "USD")
        #expect(receipt.orderNumber == "112-4455667-8899001")
        #expect(receipt.status == .ordered)
    }

    @Test func invoiceJSONLDWithPriceSpecification() {
        let html = """
            <script type="application/ld+json">{"@context":"https://schema.org","@graph":[{"@type":"Organization","name":"x"},
            {"@type":"Invoice","provider":{"@type":"Organization","name":"Fly.io"},"confirmationNumber":"INV-77",
             "paymentStatus":"https://schema.org/PaymentComplete",
             "totalPaymentDue":{"@type":"PriceSpecification","price":1234.5,"priceCurrency":"eur"}}]}</script>
            """
        let receipt = parse(from: "Billing <billing@fly.io>", subject: "Invoice", html: html)
        #expect(receipt.merchant == "Fly.io")
        #expect(receipt.amount == Decimal(string: "1234.5"))
        #expect(receipt.currency == "EUR")
        #expect(receipt.orderNumber == "INV-77")
        #expect(receipt.status == .paid)
    }

    @Test func parcelDeliveryTakesOrderFields() {
        let html = """
            <script type="application/ld+json">{"@type":"ParcelDelivery","deliveryStatus":"http://schema.org/OrderDelivered",
            "carrier":{"name":"UPS"},"partOfOrder":{"@type":"Order","orderNumber":"A-555","merchant":{"name":"Tiny Shop"}}}</script>
            """
        let receipt = parse(from: "Tiny Shop <ship@tinyshop.example>", subject: "Your package", html: html)
        #expect(receipt.merchant == "Tiny Shop")
        #expect(receipt.orderNumber == "A-555")
        #expect(receipt.status == .delivered)
    }

    @Test func stripeInvoiceText() {
        let text = """
            Invoice from Acme, Inc.
            Invoice number INV-0042
            Subtotal  $90.00
            Tax       $9.00
            Amount due  $99.00
            Pay this invoice
            """
        let receipt = parse(from: "\"Acme, Inc.\" <invoice+statements+acct_1AbC@stripe.com>", subject: "Your invoice from Acme, Inc.", text: text)
        #expect(receipt.merchant == "Acme, Inc.")
        #expect(receipt.amount == 99)
        #expect(receipt.currency == "USD")
        #expect(receipt.orderNumber == "INV-0042")
    }

    @Test func totalInTableHTML() {
        let html = """
            <table><tr><td>Subtotal</td><td>US$18.00</td></tr><tr><td>Shipping</td><td>US$4.50</td></tr>
            <tr><td><b>Total</b></td><td><b>US$22.50</b></td></tr><tr><td>You saved</td><td>US$30.00</td></tr></table>
            <p>Order #W123456</p>
            """
        let receipt = parse(from: "Tiny Shop Orders <orders@tinyshop.example>", subject: "Order confirmation", html: html)
        #expect(receipt.amount == Decimal(string: "22.50"))
        #expect(receipt.currency == "USD")
        #expect(receipt.orderNumber == "W123456")
        #expect(receipt.merchant == "Tiny Shop")
        #expect(receipt.status == .ordered)
    }

    @Test func grandTotalBeatsTotal() {
        let receipt = parse(from: "Hotel <stay@hotel.example>", subject: "Your stay",
                            text: "Room total: £300.00\nTaxes: £60.00\nGrand total: £1,234.56\n")
        #expect(receipt.amount == Decimal(string: "1234.56"))
        #expect(receipt.currency == "GBP")
    }

    @Test(arguments: [
        ("Total: €12,50", "12.50", "EUR"),
        ("Gesamtbetrag 12,50 €", "12.50", "EUR"),
        ("Amount charged USD 12.00", "12.00", "USD"),
        ("Total 45.00 CAD", "45.00", "CAD"),
        ("Total charged: A$19.95", "19.95", "AUD"),
        ("合計 ¥1,200", "1200", "JPY"),
        ("Total paid $1,049.99", "1049.99", "USD"),
    ])
    func currencyForms(text: String, amount: String, currency: String) {
        let receipt = parse(from: "Shop <shop@example.com>", subject: "Receipt", text: text)
        #expect(receipt.amount == Decimal(string: amount))
        #expect(receipt.currency == currency)
    }

    @Test func uberMerchantFromDisplayName() {
        let receipt = parse(from: "Uber Receipts <noreply@uber.com>", subject: "Your Thursday evening trip with Uber",
                            text: "Total $23.17\nThanks for riding")
        #expect(receipt.merchant == "Uber")
        #expect(receipt.amount == Decimal(string: "23.17"))
    }

    @Test func merchantFromDomainWhenNameIsOnlyNoise() {
        #expect(ReceiptParser.merchant(from: EmailAddress(name: "no-reply", email: "no-reply@billing.acme.co.uk")) == "Acme")
        #expect(ReceiptParser.merchant(from: EmailAddress(email: "receipts@squareup.com")) == "Squareup")
    }

    @Test(arguments: [
        ("Your refund has been processed", ReceiptStatus.refunded),
        ("Delivered: \"USB-C cable\"", .delivered),
        ("Your order has shipped", .shipped),
        ("Out for delivery today", .shipped),
        ("Your receipt from Apple.", .paid),
        ("Payment received", .paid),
        ("Order confirmation #1001", .ordered),
        ("Unpaid invoice INV-1", .unknown),
    ])
    func statusFromWording(subject: String, status: ReceiptStatus) {
        #expect(ReceiptParser.status(in: subject) == status)
    }

    @Test func noAmountWhenOnlyDiscounts() {
        let receipt = parse(from: "Shop <shop@example.com>", subject: "Your order", text: "You saved $5.00")
        #expect(receipt.amount == nil)
    }
}

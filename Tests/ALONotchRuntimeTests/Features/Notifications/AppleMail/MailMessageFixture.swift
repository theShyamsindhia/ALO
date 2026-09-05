import Foundation
@testable import ALONotchRuntime

func makeTestMailMessage(
    rowID: Int64,
    messageIDHeader: String,
    sender: String,
    subject: String,
    summary: String?,
    receivedDate: Date
) -> MailMessage {
    MailMessage(
        rowID: rowID, messageIDHeader: messageIDHeader, sender: sender,
        subject: subject, summary: summary, receivedDate: receivedDate,
        senderInfo: MailSenderFormatter.format(
            rawSender: sender,
            resolver: MessagesContactResolver(contactStore: DeniedMessagesContactStore())
        )
    )
}

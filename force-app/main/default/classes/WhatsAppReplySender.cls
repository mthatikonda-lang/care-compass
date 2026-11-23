public class WhatsAppReplySender implements Queueable, Database.AllowsCallouts {

    private String toNumber;
    private String messageText;

    public WhatsAppReplySender(String toNumber, String messageText) {
        this.toNumber = toNumber;
        this.messageText = messageText;
    }

    public void execute(QueueableContext context) {
        try {
            WhatsAppSender.sendTextMessage(toNumber, messageText);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'WhatsAppReplySender failed: ' + e.getMessage()
                + ' | ' + e.getStackTraceString());
            ErrorLogger.log(
                'WhatsAppReplySender.execute',
                'Error',
                'Failed to send WhatsApp reply',
                'phone ending ' + (toNumber == null ? '' : toNumber.right(4))
                    + '\n' + e.getMessage() + '\n' + e.getStackTraceString(),
                null
            );
        }
    }
}
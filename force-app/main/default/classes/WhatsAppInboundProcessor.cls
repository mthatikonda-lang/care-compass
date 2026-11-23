/**
 * Runs the WhatsApp booking chat from the Platform Event trigger, in a Queueable so the
 * AI callout (SpecialtyAiMatcher) is allowed. The callout goes through the Self_Org_API
 * Named Credential, so it works whichever user runs this.
 */
public class WhatsAppInboundProcessor implements Queueable, Database.AllowsCallouts {

    private String fromNumber;
    private String messageBody;

    public WhatsAppInboundProcessor(String fromNumber, String messageBody) {
        this.fromNumber = fromNumber;
        this.messageBody = messageBody;
    }

    public void execute(QueueableContext context) {
        try {
            WhatsAppConversationRouter.route(fromNumber, messageBody);
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'WhatsAppInboundProcessor failed: ' + e.getMessage()
                + ' | ' + e.getStackTraceString());
            ErrorLogger.logException('WhatsAppInboundProcessor.execute', e, null);
        }
    }
}
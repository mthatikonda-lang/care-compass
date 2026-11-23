/**
 * Sends the proactive "we're reaching out to you" template message to each contact.
 * Runs in its own fresh Queueable transaction (chained from WhatsAppInitialContactSender),
 * which is what makes the callout legal — see that class's header for why.
 *
 * >>> REQUIRES A META-APPROVED TEMPLATE <<<
 * WhatsApp does not allow free-form text to someone who hasn't messaged you first (or
 * within the last 24 hours) — Meta requires a pre-approved message TEMPLATE for this kind
 * of proactive outreach. Create one in Meta Business Manager (WhatsApp Manager > Message
 * Templates) with a single body variable for the patient's first name, e.g.:
 *   "Hi {{1}}, this is Care Compass. What brings you in today?"
 * and update TEMPLATE_NAME below to match its exact name once approved. Sending will fail
 * silently (logged via WhatsAppSender's existing error debug) until the template exists
 * and is approved.
 */
public class WhatsAppTemplateSender implements Queueable, Database.AllowsCallouts {

    // TODO: replace with your actual approved template name once created in Meta.
    private static final String TEMPLATE_NAME = 'care_compass_welcome';
    private static final String LANGUAGE_CODE = 'en_IN'; // matches "English (IND)" in WhatsApp Manager

    private List<WhatsAppOutboundContact> contacts;

    public WhatsAppTemplateSender(List<WhatsAppOutboundContact> contacts) {
        this.contacts = contacts;
    }

    public void execute(QueueableContext context) {
        for (WhatsAppOutboundContact contact : contacts) {
            WhatsAppSender.sendTemplateMessage(
                contact.phoneNumber,
                TEMPLATE_NAME,
                LANGUAGE_CODE,
                new List<String>{ contact.patientFirstName }
            );
        }
    }
}
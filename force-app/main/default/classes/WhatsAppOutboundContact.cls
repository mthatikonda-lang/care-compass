/**
 * Carries just what WhatsAppTemplateSender needs to fire off a template message —
 * kept separate from WhatsApp_Conversation__c/Patient__c so the second queueable doesn't
 * need another query.
 */
public class WhatsAppOutboundContact {
    public String phoneNumber;
    public String patientFirstName;

    public WhatsAppOutboundContact(String phoneNumber, String patientFirstName) {
        this.phoneNumber = phoneNumber;
        this.patientFirstName = patientFirstName;
    }
}
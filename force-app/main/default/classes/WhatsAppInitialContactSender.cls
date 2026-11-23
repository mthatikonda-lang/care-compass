/**
 * Runs after a Patient__c is inserted or has its phone number changed. Does the DML side
 * of proactive outreach: creates a WhatsApp_Conversation__c for each patient who doesn't
 * already have one on this number (so re-editing an unrelated field, or a phone edit that
 * happens to fire twice, doesn't re-welcome someone mid-conversation), then chains
 * WhatsAppTemplateSender to actually send the template message.
 *
 * DML-before-callout: this class does no callouts itself, only DML + a chained enqueue —
 * WhatsAppTemplateSender (the next link) is the one that makes the HTTP callout, in its
 * own fresh transaction, same pattern as WhatsAppReplySender elsewhere in this integration.
 *
 * >>> PHONE FORMAT ASSUMPTION — VERIFY AGAINST YOUR REAL DATA <<<
 * Patient__c.Phone__c has been seen stored two ways: a bare US-style 10-digit number like
 * "(986) 757-7698", and an international one like "+918074266404". normalizeForWhatsApp()
 * below assumes: 10 digits -> US number, prepend "1"; 11+ digits -> already has a country
 * code, use as-is. This is a heuristic, not a guarantee — if your patient data includes
 * other country formats stored as bare 10-digit numbers, this will misdial them. Tighten
 * this once you know your real data's conventions.
 */
public without sharing class WhatsAppInitialContactSender implements Queueable {

    private List<Id> patientIds;

    public WhatsAppInitialContactSender(List<Id> patientIds) {
        this.patientIds = patientIds;
    }

    public void execute(QueueableContext context) {
        List<Patient__c> patients = [
            SELECT Id, First_Name__c, Phone__c
            FROM Patient__c
            WHERE Id IN :patientIds AND Phone__c != null
        ];

        List<WhatsApp_Conversation__c> conversationsToUpsert = new List<WhatsApp_Conversation__c>();
        List<WhatsAppOutboundContact> contactsToMessage = new List<WhatsAppOutboundContact>();

        for (Patient__c p : patients) {
            String whatsAppNumber = normalizeForWhatsApp(p.Phone__c);
            if (String.isBlank(whatsAppNumber)) {
                System.debug(LoggingLevel.WARN, 'Could not normalize phone for Patient ' + p.Id + ': ' + p.Phone__c);
                continue;
            }

            // Skip if a conversation already exists for this number — don't re-welcome
            // someone who's already mid-conversation just because an unrelated field changed.
            List<WhatsApp_Conversation__c> existing = [
                SELECT Id FROM WhatsApp_Conversation__c WHERE Phone_Number__c = :whatsAppNumber LIMIT 1
            ];
            if (!existing.isEmpty()) {
                continue;
            }

            conversationsToUpsert.add(new WhatsApp_Conversation__c(
                Phone_Number__c = whatsAppNumber,
                Patient__c = p.Id,
                Step__c = 'AwaitingIssue',   // skip Started — we already know who they are
                Last_Message_At__c = System.now()
            ));
            contactsToMessage.add(new WhatsAppOutboundContact(whatsAppNumber, p.First_Name__c));
        }

        if (!conversationsToUpsert.isEmpty()) {
            upsert conversationsToUpsert Phone_Number__c;
        }

        if (!contactsToMessage.isEmpty()) {
            System.enqueueJob(new WhatsAppTemplateSender(contactsToMessage));
        }
    }

    private static String normalizeForWhatsApp(String phone) {
        if (phone == null) {
            return null;
        }
        String digitsOnly = phone.replaceAll('[^0-9]', '');
        if (digitsOnly.length() == 10) {
            return '1' + digitsOnly;   // assumed US number, see class header
        } else if (digitsOnly.length() >= 11) {
            return digitsOnly;         // assumed to already include country code
        }
        return null;                    // too short to be a real number — skip
    }
}
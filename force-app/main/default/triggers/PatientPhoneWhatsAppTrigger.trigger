/**
 * Drives the WhatsApp onboarding flow for Patient__c. All logic lives in
 * PatientWhatsAppOnboarding — this trigger only routes to it:
 *
 *   Stage 1 (after insert): phone number present -> registration reminder
 *   Stage 3 (after update): profile + insurance setup just completed -> ready-to-book message
 *
 * Stage 2 (setup reminder after email verification) is turned off: email verification
 * was removed, so Email_Verified__c never changes.
 *
 * care_compass_welcome / WhatsAppInitialContactSender is no longer called from here —
 * care_compass_registration_reminder (stage 1) replaces it as the first proactive contact.
 */
trigger PatientPhoneWhatsAppTrigger on Patient__c (after insert, after update) {

    if (Trigger.isInsert) {
        PatientWhatsAppOnboarding.sendRegistrationReminder(Trigger.new);
    }

    if (Trigger.isUpdate) {
        // Stage 2 off: PatientWhatsAppOnboarding.sendSetupReminder(Trigger.new, Trigger.oldMap);
        PatientWhatsAppOnboarding.sendReadyToBook(Trigger.new, Trigger.oldMap);
    }
}
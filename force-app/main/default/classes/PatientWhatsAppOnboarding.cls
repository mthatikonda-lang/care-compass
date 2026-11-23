public without sharing class PatientWhatsAppOnboarding {
 
    private static final String LANGUAGE_CODE = 'en_IN';
    private static final String REGISTRATION_TEMPLATE = 'care_compass_registration_reminder';
    private static final String SETUP_REMINDER_TEMPLATE = 'care_compass_complete_setup';
    private static final String READY_TO_BOOK_TEMPLATE = 'care_compass_ready_to_book';
 
    // ---------------------------------------------------------------
    // Stage 1: fires on insert, if a phone number is present.
    // ---------------------------------------------------------------
    public static void sendRegistrationReminder(List<Patient__c> newPatients) {
        List<Patient__c> toUpdate = new List<Patient__c>();
        List<String> phones = new List<String>();
        List<String> paramSets = new List<String>();
 
        for (Patient__c p : newPatients) {
            if (String.isNotBlank(p.Phone__c) && p.Registration_Msg_Sent__c != true) {
                phones.add(p.Phone__c);
                paramSets.add(joinParams(new List<String>{ p.First_Name__c, p.Email__c }));
                toUpdate.add(new Patient__c(Id = p.Id, Registration_Msg_Sent__c = true));
            }
        }
 
        if (toUpdate.isEmpty()) {
            return;
        }
        update toUpdate;
        sendTemplatesAsync(REGISTRATION_TEMPLATE, phones, paramSets);
    }
 
    // ---------------------------------------------------------------
    // Stage 2: fires on update, when Email_Verified__c flips false/null -> true,
    // and profile/insurance setup isn't both done yet (if it already is, stage 3
    // covers it instead — no need to nudge about setup they've already finished).
    // ---------------------------------------------------------------
    public static void sendSetupReminder(List<Patient__c> newPatients, Map<Id, Patient__c> oldMap) {
        List<Patient__c> toUpdate = new List<Patient__c>();
        List<String> phones = new List<String>();
        List<String> paramSets = new List<String>();
 
        for (Patient__c p : newPatients) {
            Patient__c old = oldMap.get(p.Id);
            Boolean justVerified = p.Email_Verified__c == true && old.Email_Verified__c != true;
            Boolean setupIncomplete = p.Profile_Completed__c != true || p.Insurance_Setup_Completed__c != true;
 
            if (justVerified && setupIncomplete
                && String.isNotBlank(p.Phone__c) && p.Setup_Reminder_Sent__c != true) {
                phones.add(p.Phone__c);
                paramSets.add(joinParams(new List<String>{ p.First_Name__c }));
                toUpdate.add(new Patient__c(Id = p.Id, Setup_Reminder_Sent__c = true));
            }
        }
 
        if (toUpdate.isEmpty()) {
            return;
        }
        update toUpdate;
        sendTemplatesAsync(SETUP_REMINDER_TEMPLATE, phones, paramSets);
    }
 
    // ---------------------------------------------------------------
    // Stage 3: fires on update, when Profile_Completed__c AND Insurance_Setup_Completed__c
    // are both true now, and at least one of them wasn't true before this update.
    // ---------------------------------------------------------------
    public static void sendReadyToBook(List<Patient__c> newPatients, Map<Id, Patient__c> oldMap) {
        List<Patient__c> toUpdate = new List<Patient__c>();
        List<String> phones = new List<String>();
        List<String> paramSets = new List<String>();
 
        for (Patient__c p : newPatients) {
            Patient__c old = oldMap.get(p.Id);
            Boolean nowComplete = p.Profile_Completed__c == true && p.Insurance_Setup_Completed__c == true;
            Boolean wasComplete = old.Profile_Completed__c == true && old.Insurance_Setup_Completed__c == true;
 
            if (nowComplete && !wasComplete
                && String.isNotBlank(p.Phone__c) && p.Ready_To_Book_Msg_Sent__c != true) {
                phones.add(p.Phone__c);
                paramSets.add(joinParams(new List<String>{ p.First_Name__c }));
                toUpdate.add(new Patient__c(Id = p.Id, Ready_To_Book_Msg_Sent__c = true));
            }
        }
 
        if (toUpdate.isEmpty()) {
            return;
        }
        update toUpdate;
        sendTemplatesAsync(READY_TO_BOOK_TEMPLATE, phones, paramSets);
    }
 
    // ---------------------------------------------------------------
    @future(callout=true)
    private static void sendTemplatesAsync(String templateName, List<String> phones, List<String> paramSetsJoined) {
        for (Integer i = 0; i < phones.size(); i++) {
            try {
                List<String> params = paramSetsJoined[i].split('\u0001', -1);
                WhatsAppSender.sendTemplateMessage(phones[i], templateName, LANGUAGE_CODE, params);
            } catch (Exception e) {
                System.debug(LoggingLevel.ERROR,
                    'Failed to send ' + templateName + ' to ' + phones[i] + ': ' + e.getMessage());
            }
        }
    }
 
    // Joins a param list with a control character unlikely to appear in a name or email,
    // so it can be split back apart inside the future method (which can't take
    // List<List<String>> — future method params must be primitives or flat lists of them).
    private static String joinParams(List<String> params) {
        List<String> safe = new List<String>();
        for (String p : params) {
            safe.add(p == null ? '' : p);
        }
        return String.join(safe, '\u0001');
    }
}
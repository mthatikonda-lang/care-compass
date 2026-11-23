trigger SendVerificationEmailTrigger on Send_Verification_Email__e (after insert) {
    for (Send_Verification_Email__e evt : Trigger.new) {
        try {
            PatientEmailVerificationController.sendVerificationEmail(
                (Id) evt.Patient_Id__c, evt.Site_Base_Url__c, evt.Username__c
            );
        } catch (Exception e) {
            ErrorLogger.logException('SendVerificationEmailTrigger', e, evt.Patient_Id__c);
        }
    }
}
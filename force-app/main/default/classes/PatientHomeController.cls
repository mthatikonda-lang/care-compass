public with sharing class PatientHomeController {

    @AuraEnabled(cacheable=true)
    public static Patient__c getCurrentPatient() {
        String currentUserId = UserInfo.getUserId();
        System.debug('PatientHomeController.getCurrentPatient - currentUserId: ' + currentUserId + ' (length: ' + currentUserId.length() + ')');

        try {
            List<Patient__c> patients = [
                SELECT Id, First_Name__c, Last_Name__c, Email__c, Date_of_Birth__c,
                       Gender__c, Phone__c, Status__c, Insurance_Plan__c,
                       Insurance_Plan__r.Name, Insurance_Plan__r.Insurance_Carrier__c,
                       Insurance_Setup_Completed__c, Profile_Completed__c, Subscriber_ID__c, Insurance_Plan__r.Plan_Type__c
                FROM Patient__c
                WHERE Related_User__c = :currentUserId
                LIMIT 1
            ];

            System.debug('PatientHomeController.getCurrentPatient - rows returned: ' + patients.size());

            if (patients.isEmpty()) {
                // Diagnostic only: bypasses sharing/FLS to check whether a Patient__c with this
                // Related_User__c exists at all, and if so, what's actually stored there.
                // Remove this block once the root cause is confirmed.
                List<Patient__c> anyMatch = [
                    SELECT Id, Related_User__c
                    FROM Patient__c
                    WHERE Related_User__c = :currentUserId
                    LIMIT 1
                    ALL ROWS
                ];
                System.debug('PatientHomeController.getCurrentPatient - diagnostic anyMatch (should still be empty if truly no match): ' + anyMatch);

                List<Patient__c> allForDebug = [
                    SELECT Id, Related_User__c, Email__c
                    FROM Patient__c
                    WHERE Email__c != null
                    ORDER BY CreatedDate DESC
                    LIMIT 5
                ];
                System.debug('PatientHomeController.getCurrentPatient - most recent Patient__c records for comparison: ' + allForDebug);
                for (Patient__c p : allForDebug) {
                    System.debug('  Patient ' + p.Id + ' Related_User__c="' + p.Related_User__c + '" (length: ' +
                        (p.Related_User__c != null ? String.valueOf(p.Related_User__c.length()) : 'null') + ') vs currentUserId="' + currentUserId + '"');
                }
            }

            return patients.isEmpty() ? null : patients[0];

        } catch (Exception e) {
            System.debug('PatientHomeController.getCurrentPatient - EXCEPTION: ' + e.getTypeName() + ' - ' + e.getMessage());
            System.debug('PatientHomeController.getCurrentPatient - STACK: ' + e.getStackTraceString());
            throw e;
        }
    }
}
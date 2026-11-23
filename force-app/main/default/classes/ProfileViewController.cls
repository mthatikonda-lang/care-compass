public with sharing class ProfileViewController {

    public class ProfileData {
        @AuraEnabled public String fullName;
        @AuraEnabled public String patientId;
        @AuraEnabled public String planName;
        @AuraEnabled public String memberId;
        @AuraEnabled public Decimal deductible;
        @AuraEnabled public Decimal outOfPocketMax;
        @AuraEnabled public String email;
        @AuraEnabled public String phone;
        @AuraEnabled public Date dateOfBirth;
        @AuraEnabled public String gender;
    }

    @AuraEnabled(cacheable=true)
    public static ProfileData getProfile() {
        try {
            List<Patient__c> rows = [
                SELECT Id, Name, Email__c, Phone__c, Date_of_Birth__c, Gender__c, Subscriber_ID__c,
                       Insurance_Plan__r.Name, Insurance_Plan__r.Deductible__c, Insurance_Plan__r.Out_Of_Pocket_Max__c
                FROM Patient__c
                WHERE Related_User__c = :UserInfo.getUserId()
                LIMIT 1
            ];
            ProfileData d = new ProfileData();
            d.fullName = ((UserInfo.getFirstName() == null ? '' : UserInfo.getFirstName()) + ' '
                + (UserInfo.getLastName() == null ? '' : UserInfo.getLastName())).trim();
            if (rows.isEmpty()) {
                return d;
            }
            Patient__c p = rows[0];
            d.patientId = p.Name;
            d.email = p.Email__c;
            d.phone = p.Phone__c;
            d.dateOfBirth = p.Date_of_Birth__c;
            d.gender = p.Gender__c;
            d.memberId = p.Subscriber_ID__c;
            if (p.Insurance_Plan__r != null) {
                d.planName = p.Insurance_Plan__r.Name;
                d.deductible = p.Insurance_Plan__r.Deductible__c;
                d.outOfPocketMax = p.Insurance_Plan__r.Out_Of_Pocket_Max__c;
            }
            return d;
        } catch (Exception e) {
            ErrorLogger.log('ProfileViewController.getProfile', 'Error', 'Loading profile failed',
                e.getTypeName() + ': ' + e.getMessage() + ' | line ' + e.getLineNumber(), String.valueOf(UserInfo.getUserId()));
            throw new AuraHandledException('We could not load your profile. Please try again.');
        }
    }
}
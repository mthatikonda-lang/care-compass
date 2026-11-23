public with sharing class ProfileSetupController {

    private static final Set<String> GENDERS = new Set<String>{ 'Male', 'Female', 'Other', 'Prefer not to say' };

    // Same rules as the Profile Setup page and registration (BUG-23), checked on the server too.
    @TestVisible
    private static String detailsProblem(Date dateOfBirth, String gender, String phone) {
        if (dateOfBirth == null) {
            return 'Please enter your date of birth.';
        }
        if (dateOfBirth > Date.today()) {
            return 'Date of birth cannot be in the future.';
        }
        if (dateOfBirth < Date.today().addYears(-120)) {
            return 'Please enter a valid date of birth.';
        }
        if (String.isBlank(gender) || !GENDERS.contains(gender)) {
            return 'Please choose your gender.';
        }
        String digits = phone == null ? '' : phone.replaceAll('[\\s().\\-]', '');
        if (!Pattern.matches('(\\+1|\\+91)?[0-9]{10}', digits)) {
            return 'Mobile number must be 10 digits, optionally starting with +1 or +91.';
        }
        return null;
    }

    @AuraEnabled
    public static void saveProfileDetails(Date dateOfBirth, String gender, String phone) {
        String currentUserId = UserInfo.getUserId();
        System.debug('ProfileSetupController.saveProfileDetails - currentUserId: ' + currentUserId);

        try {
            String problem = detailsProblem(dateOfBirth, gender, phone);
            if (problem != null) {
                throw new AuraHandledException(problem);
            }

            List<Patient__c> patients = [
                SELECT Id, Related_User__c FROM Patient__c WHERE Related_User__c = :currentUserId LIMIT 1
            ];
            System.debug('ProfileSetupController.saveProfileDetails - rows returned: ' + patients.size());

            if (patients.isEmpty()) {
                throw new AuraHandledException('We could not find your patient profile.');
            }

            Patient__c patient = patients[0];
            patient.Date_of_Birth__c = dateOfBirth;
            patient.Gender__c = gender;
            patient.Phone__c = phone;
            patient.Profile_Completed__c = true;
            update patient;

        } catch (AuraHandledException ahe) {
            System.debug('ProfileSetupController.saveProfileDetails - AuraHandledException: ' + ahe.getMessage());
            throw ahe;
        } catch (Exception e) {
            System.debug('ProfileSetupController.saveProfileDetails - EXCEPTION: ' + e.getTypeName() + ' - ' + e.getMessage());
            throw new AuraHandledException('Error saving profile details: ' + e.getMessage());
        }
    }
}
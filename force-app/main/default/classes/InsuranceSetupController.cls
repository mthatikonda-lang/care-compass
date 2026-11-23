public with sharing class InsuranceSetupController {

public class PlanOption {
    @AuraEnabled public String id;
    @AuraEnabled public String label;
}

@AuraEnabled(cacheable=true)
public static List<PlanOption> getInsurancePlans() {
    List<PlanOption> options = new List<PlanOption>();
    for (Insurance_Plan__c plan : [
        SELECT Id, Name, Insurance_Carrier__c, Plan_Type__c
        FROM Insurance_Plan__c
        ORDER BY Insurance_Carrier__c, Name
    ]) {
        PlanOption opt = new PlanOption();
        opt.id = plan.Id;
        opt.label = plan.Insurance_Carrier__c + ' — ' + plan.Name
                    + (String.isNotBlank(plan.Plan_Type__c) ? ' (' + plan.Plan_Type__c + ')' : '');
        options.add(opt);
    }
    return options;
}

// Same rule as the Subscriber ID check on the insurance page (BUG-23): 5 to 20 characters of
// letters, numbers, dashes and spaces. Checked here too, so the page rules can't be bypassed.
@TestVisible
private static String subscriberIdProblem(String value) {
    String id = value == null ? '' : value.trim();
    if (String.isBlank(id)) {
        return 'Please enter your Subscriber ID. You can find it on your insurance card.';
    }
    if (id.length() < 5 || id.length() > 20) {
        return 'Subscriber ID should be 5 to 20 characters. Check it against your insurance card.';
    }
    if (!Pattern.matches('[A-Za-z0-9 \\-]+', id)) {
        return 'Subscriber ID can only have letters, numbers, dashes and spaces.';
    }
    return null;
}

// True when the signed-in patient has finished insurance setup (or has a plan from before the flag existed).
// Returns true for anyone who is not a patient, so guests and staff are never redirected.
@AuraEnabled
public static Boolean isSetupComplete() {
try {
    List<Patient__c> patients = [
        SELECT Insurance_Plan__c, Insurance_Setup_Completed__c
        FROM Patient__c WHERE Related_User__c = :UserInfo.getUserId() LIMIT 1
    ];
    if (patients.isEmpty()) {
        return true;
    }
    return patients[0].Insurance_Setup_Completed__c == true || patients[0].Insurance_Plan__c != null;
} catch (Exception e) {
    return true; // never trap a user because of an error
}
}

@AuraEnabled
public static void saveInsuranceSetup(Boolean hasInsurance, String planId, String subscriberId) {
    try {
        String currentUserId = UserInfo.getUserId();
        List<Patient__c> patients = [
            SELECT Id FROM Patient__c WHERE Related_User__c = :currentUserId LIMIT 1
        ];
        if (patients.isEmpty()) {
            throw new AuraHandledException('We could not find your patient profile.');
        }

        Patient__c patient = patients[0];
        if (hasInsurance) {
            if (String.isBlank(planId)) {
                throw new AuraHandledException('Please select your insurance provider.');
            }
            if ([SELECT COUNT() FROM Insurance_Plan__c WHERE Id = :planId] == 0) {
                throw new AuraHandledException('That insurance plan was not found. Please choose it again.');
            }
            String idProblem = subscriberIdProblem(subscriberId);
            if (idProblem != null) {
                throw new AuraHandledException(idProblem);
            }
            patient.Insurance_Plan__c = planId;
            patient.Subscriber_ID__c = subscriberId.trim();
        } else {
            patient.Insurance_Plan__c = null;
            patient.Subscriber_ID__c = null;
        }
        patient.Insurance_Setup_Completed__c = true;
        update patient;

    } catch (AuraHandledException ahe) {
        throw ahe;
    } catch (Exception e) {
        throw new AuraHandledException('Error saving insurance details: ' + e.getMessage());
    }
}
}
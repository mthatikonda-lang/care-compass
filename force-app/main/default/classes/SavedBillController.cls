// Loads a bill the patient already checked, so the dashboard can open its summary.
// Returns the numbers exactly as they were saved. Only the signed-in user's own bills are returned.
public without sharing class SavedBillController {

    public class SavedCharge {
        @AuraEnabled public String description;
        @AuraEnabled public Decimal billedAmount;
        @AuraEnabled public Decimal patientResponsibility;
        @AuraEnabled public Boolean flaggedAsUnreasonable;
    }

    public class SavedBill {
        @AuraEnabled public String billId;
        @AuraEnabled public String providerName;
        @AuraEnabled public String billNumber;
        @AuraEnabled public String billDate;        // yyyy-mm-dd
        @AuraEnabled public String planName;
        @AuraEnabled public Decimal totalBilled;
        @AuraEnabled public Decimal totalPatientResponsibility;
        @AuraEnabled public Decimal insurancePays;
        @AuraEnabled public List<SavedCharge> charges;
    }

    @AuraEnabled
    public static SavedBill getSavedBill(Id billId) {
        try {
            if (billId == null) {
                throw new AuraHandledException('We could not find that bill.');
            }
            List<Bill__c> bills = [
                SELECT Id, Provider_Name__c, Bill_Number__c, Bill_Date__c
                FROM Bill__c
                WHERE Id = :billId AND CreatedById = :UserInfo.getUserId()
                LIMIT 1
            ];
            if (bills.isEmpty()) {
                throw new AuraHandledException('We could not find that bill.');
            }
            Bill__c b = bills[0];
            SavedBill r = new SavedBill();
            r.billId = b.Id;
            r.providerName = b.Provider_Name__c;
            r.billNumber = b.Bill_Number__c;
            r.billDate = b.Bill_Date__c == null ? null : String.valueOf(b.Bill_Date__c);
            r.charges = new List<SavedCharge>();
            Decimal billed = 0;
            Decimal owed = 0;
            for (Charge__c c : [
                SELECT Charge_Description__c, Billed_Amount__c, Patient_Responsibility__c, Flagged_As_Unreasonable__c
                FROM Charge__c
                WHERE Bill__c = :b.Id
                ORDER BY CreatedDate, Id
            ]) {
                SavedCharge sc = new SavedCharge();
                sc.description = c.Charge_Description__c;
                sc.billedAmount = c.Billed_Amount__c == null ? 0 : c.Billed_Amount__c;
                sc.patientResponsibility = c.Patient_Responsibility__c == null ? 0 : c.Patient_Responsibility__c;
                sc.flaggedAsUnreasonable = c.Flagged_As_Unreasonable__c == true;
                r.charges.add(sc);
                billed += sc.billedAmount;
                owed += sc.patientResponsibility;
            }
            r.totalBilled = billed.setScale(2, System.RoundingMode.HALF_UP);
            r.totalPatientResponsibility = owed.setScale(2, System.RoundingMode.HALF_UP);
            r.insurancePays = (billed - owed).setScale(2, System.RoundingMode.HALF_UP);
            List<Patient__c> pts = [
                SELECT Insurance_Plan__r.Name FROM Patient__c
                WHERE Related_User__c = :UserInfo.getUserId() LIMIT 1
            ];
            if (!pts.isEmpty() && pts[0].Insurance_Plan__r != null) {
                r.planName = pts[0].Insurance_Plan__r.Name;
            }
            return r;
        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            ErrorLogger.log('SavedBillController.getSavedBill', 'Error', e.getMessage(), 'bill=' + billId, String.valueOf(billId));
            throw new AuraHandledException('We could not open that bill. Please try again.');
        }
    }
}
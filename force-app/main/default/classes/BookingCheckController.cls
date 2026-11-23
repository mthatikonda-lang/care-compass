// Tells the booking screen whether the signed-in patient already has an open request
// (Call Requested or Confirmed, date not in the past) with the same doctor.
public with sharing class BookingCheckController {

    private static final List<String> OPEN_STATUSES = new List<String>{ 'Call Requested', 'Confirmed' };

    public class DuplicateInfo {
        @AuraEnabled public Boolean hasOpenRequest = false;
        @AuraEnabled public String status;
        @AuraEnabled public String dateText;
    }

    @AuraEnabled
    public static DuplicateInfo checkOpenRequest(Id doctorId) {
        DuplicateInfo info = new DuplicateInfo();
        try {
            if (doctorId == null) return info;
            List<Patient__c> patients = [
                SELECT Id FROM Patient__c WHERE Related_User__c = :UserInfo.getUserId() LIMIT 1
            ];
            if (patients.isEmpty()) return info;
            List<Appointment__c> rows = [
                SELECT Status__c, Appointment_Date__c
                FROM Appointment__c
                WHERE Patient__c = :patients[0].Id
                  AND Doctor__c = :doctorId
                  AND Status__c IN :OPEN_STATUSES
                  AND (Appointment_Date__c = null OR Appointment_Date__c >= TODAY)
                ORDER BY Appointment_Date__c ASC NULLS LAST
                LIMIT 1
            ];
            if (!rows.isEmpty()) {
                info.hasOpenRequest = true;
                info.status = rows[0].Status__c;
                if (rows[0].Appointment_Date__c != null) {
                    info.dateText = Datetime.newInstance(rows[0].Appointment_Date__c.year(),
                        rows[0].Appointment_Date__c.month(), rows[0].Appointment_Date__c.day()).format('MMM d, yyyy');
                }
            }
        } catch (Exception e) {
            // A failed check must never block booking.
            ErrorLogger.log('BookingCheckController.checkOpenRequest', 'Warning', e.getMessage(), '', '');
        }
        return info;
    }
}
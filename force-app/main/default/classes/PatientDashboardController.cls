public with sharing class PatientDashboardController {

    // Bill totals are summed from Charge__c (Billed_Amount__c, Patient_Responsibility__c).

    // Only appointments whose callback was actually requested count as requests.
    // An estimate that was only viewed (any other status) is never listed. (BUG-26)
    private static final String REQUESTED_STATUS = 'Call Requested';
    // Set when the patient confirms the date the office agreed on during the callback (BUG-44).
    private static final String CONFIRMED_STATUS = 'Confirmed';
    private static final List<String> ACTIVE_STATUSES = new List<String>{ 'Call Requested', 'Confirmed' };

    public class DashboardData {
        @AuraEnabled public String patientName;   // the patient record's name (an ID such as PAT-0053)
        @AuraEnabled public String firstName;     // the signed-in person's first name
        @AuraEnabled public String fullName;      // the signed-in person's full name
        @AuraEnabled public String planName;
        @AuraEnabled public String memberId;      // Patient__c.Subscriber_ID__c
        @AuraEnabled public Decimal deductible;
        @AuraEnabled public Decimal outOfPocketMax;
        @AuraEnabled public Decimal outOfPocketSpent;
        @AuraEnabled public Decimal totalBilled;
        @AuraEnabled public Decimal totalCovered;
        @AuraEnabled public Integer billsChecked;      // bills this patient has checked
        @AuraEnabled public Integer flaggedCount;      // charges priced above the typical rate
        @AuraEnabled public Decimal flaggedAmount;     // billed total of those charges
        @AuraEnabled public List<AppointmentRow> appointments;
        @AuraEnabled public List<HistoryRow> history;
        @AuraEnabled public List<BillRow> bills;
    }

    public class AppointmentRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String doctorName;
        @AuraEnabled public Date apptDate;
        @AuraEnabled public String procedureType;
        @AuraEnabled public Decimal estimatedCost;
        @AuraEnabled public Boolean inNetwork;
        @AuraEnabled public String status;
    }

    // BUG-35: one row per past or upcoming request.
    public class HistoryRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String doctorName;
        @AuraEnabled public Date requestedOn;
        @AuraEnabled public Date apptDate;
        @AuraEnabled public String procedureType;
        @AuraEnabled public String status;
    }

    public class BillRow {
        @AuraEnabled public Id id;
        @AuraEnabled public String provider;
        @AuraEnabled public String billNumber;
        @AuraEnabled public Date billDate;
        @AuraEnabled public Decimal billed;
        @AuraEnabled public Decimal covered;
        @AuraEnabled public Decimal patientOwes;
        @AuraEnabled public String status;
    }

    // After the office calls back, the patient enters the date they agreed on and the request
    // becomes a confirmed appointment. Only the patient's own requested appointments qualify.
    @AuraEnabled
    public static void confirmAppointment(Id appointmentId, Date confirmedDate) {
        if (appointmentId == null) {
            throw new AuraHandledException('We could not find that appointment.');
        }
        if (confirmedDate == null) {
            throw new AuraHandledException('Please choose the date the office confirmed.');
        }
        if (confirmedDate < Date.today()) {
            throw new AuraHandledException('The confirmed date cannot be in the past.');
        }
        if (confirmedDate > Date.today().addYears(1)) {
            throw new AuraHandledException('That date is more than a year away. Please check it.');
        }

        List<Appointment__c> found = [
            SELECT Id, Status__c, Appointment_Date__c
            FROM Appointment__c
            WHERE Id = :appointmentId
              AND Patient__r.Related_User__c = :UserInfo.getUserId()
            LIMIT 1
        ];
        if (found.isEmpty()) {
            throw new AuraHandledException('We could not find that appointment.');
        }
        Appointment__c appt = found[0];
        if (appt.Status__c != REQUESTED_STATUS) {
            throw new AuraHandledException('Only a requested appointment can be confirmed.');
        }

        appt.Appointment_Date__c = confirmedDate;
        appt.Status__c = CONFIRMED_STATUS;
        try {
            update appt;
        } catch (DmlException e) {
            ErrorLogger.log('PatientDashboardController.confirmAppointment', 'Error',
                'Confirming appointment failed', e.getDmlMessage(0), String.valueOf(appointmentId));
            throw new AuraHandledException('We could not confirm this appointment. ' + e.getDmlMessage(0));
        } catch (Exception e) {
            ErrorLogger.log('PatientDashboardController.confirmAppointment', 'Error',
                'Confirming appointment failed', e.getMessage(), String.valueOf(appointmentId));
            throw new AuraHandledException('We could not confirm this appointment. ' + e.getMessage());
        }
        // Tell the patient by email that the appointment is confirmed. A failed email never blocks the confirmation.
        AppointmentEmails.sendConfirmed(appt.Id);
    }

    @AuraEnabled(cacheable=true)
    public static DashboardData getDashboard() {
        List<Patient__c> patients = [
            SELECT Id, Name, Subscriber_ID__c, Insurance_Plan__r.Name,
                   Insurance_Plan__r.Deductible__c,
                   Insurance_Plan__r.Out_Of_Pocket_Max__c
            FROM Patient__c
            WHERE Related_User__c = :UserInfo.getUserId()
            LIMIT 1
        ];
        DashboardData d = new DashboardData();
        d.firstName = UserInfo.getFirstName();
        d.fullName = ((UserInfo.getFirstName() == null ? '' : UserInfo.getFirstName()) + ' '
            + (UserInfo.getLastName() == null ? '' : UserInfo.getLastName())).trim();
        d.appointments = new List<AppointmentRow>();
        d.history = new List<HistoryRow>();
        d.bills = new List<BillRow>();
        d.outOfPocketSpent = 0;
        d.totalBilled = 0;
        d.totalCovered = 0;
        if (patients.isEmpty()) {
            return d;
        }
        Patient__c p = patients[0];
        d.patientName = p.Name;
        d.memberId = p.Subscriber_ID__c;
        d.planName = p.Insurance_Plan__r?.Name;
        d.deductible = p.Insurance_Plan__r?.Deductible__c;
        d.outOfPocketMax = p.Insurance_Plan__r?.Out_Of_Pocket_Max__c;

        for (Appointment__c a : [
            SELECT Id, Doctor__r.Name, Appointment_Date__c, Procedure_Type__c,
                   Estimated_Patient_Cost__c, In_Network__c, Status__c
            FROM Appointment__c
            WHERE Patient__c = :p.Id
              AND Status__c IN :ACTIVE_STATUSES
              AND Appointment_Date__c >= TODAY
            ORDER BY Appointment_Date__c ASC
        ]) {
            AppointmentRow r = new AppointmentRow();
            r.id = a.Id;
            r.doctorName = a.Doctor__r?.Name;
            r.apptDate = a.Appointment_Date__c;
            r.procedureType = a.Procedure_Type__c;
            r.estimatedCost = a.Estimated_Patient_Cost__c;
            r.inNetwork = a.In_Network__c;
            r.status = a.Status__c;
            d.appointments.add(r);
        }

        // Request history: only expired requests (requested date before today), newest first.
        // Upcoming requests are shown under "Requested appointments" instead.
        for (Appointment__c a : [
            SELECT Id, Doctor__r.Name, Appointment_Date__c, Procedure_Type__c, Status__c, CreatedDate
            FROM Appointment__c
            WHERE Patient__c = :p.Id
              AND Status__c IN :ACTIVE_STATUSES
              AND Appointment_Date__c < TODAY
            ORDER BY Appointment_Date__c DESC
            LIMIT 20
        ]) {
            HistoryRow h = new HistoryRow();
            h.id = a.Id;
            h.doctorName = a.Doctor__r?.Name;
            h.requestedOn = a.CreatedDate.date();
            h.apptDate = a.Appointment_Date__c;
            h.procedureType = a.Procedure_Type__c;
            h.status = a.Status__c;
            d.history.add(h);
        }

        // Bill totals live on Charge__c. A bill belongs to the patient who created it.
        Id me = UserInfo.getUserId();
        Map<Id, Decimal> billedByBill = new Map<Id, Decimal>();
        Map<Id, Decimal> owesByBill = new Map<Id, Decimal>();
        for (AggregateResult ar : [
            SELECT Bill__c b, SUM(Billed_Amount__c) billed, SUM(Patient_Responsibility__c) owes
            FROM Charge__c
            WHERE Bill__r.CreatedById = :me
            GROUP BY Bill__c
        ]) {
            Id billId = (Id) ar.get('b');
            Decimal billed = (Decimal) ar.get('billed');
            Decimal owes = (Decimal) ar.get('owes');
            billedByBill.put(billId, billed == null ? 0 : billed);
            owesByBill.put(billId, owes == null ? 0 : owes);
            d.totalBilled += billed == null ? 0 : billed;
            d.outOfPocketSpent += owes == null ? 0 : owes;
        }
        // Once the yearly out-of-pocket maximum is reached the plan pays 100% of covered care,
        // so what the patient has paid toward it can never be shown above the maximum.
        if (d.outOfPocketMax != null && d.outOfPocketMax > 0 && d.outOfPocketSpent > d.outOfPocketMax) {
            d.outOfPocketSpent = d.outOfPocketMax;
        }
        d.totalCovered = d.totalBilled - d.outOfPocketSpent;

        // Savings view: how many bills were checked and how much was flagged for review.
        d.billsChecked = [SELECT COUNT() FROM Bill__c WHERE CreatedById = :me];
        d.flaggedCount = 0;
        d.flaggedAmount = 0;
        for (AggregateResult fr : [
            SELECT COUNT(Id) c, SUM(Billed_Amount__c) s
            FROM Charge__c
            WHERE Bill__r.CreatedById = :me AND Flagged_As_Unreasonable__c = true
        ]) {
            d.flaggedCount = (Integer) fr.get('c');
            d.flaggedAmount = (Decimal) fr.get('s');
            if (d.flaggedAmount == null) { d.flaggedAmount = 0; }
        }

        for (Bill__c b : [
            SELECT Id, Provider_Name__c, Bill_Number__c, Bill_Date__c, Status__c
            FROM Bill__c
            WHERE CreatedById = :me
            ORDER BY Bill_Date__c DESC NULLS LAST, CreatedDate DESC, Id DESC
            LIMIT 15
        ]) {
            Decimal billed = billedByBill.get(b.Id) == null ? 0 : billedByBill.get(b.Id);
            Decimal owes = owesByBill.get(b.Id) == null ? 0 : owesByBill.get(b.Id);
            BillRow r = new BillRow();
            r.id = b.Id;
            r.provider = b.Provider_Name__c;
            r.billNumber = b.Bill_Number__c;
            r.billDate = b.Bill_Date__c;
            r.billed = billed;
            r.covered = billed - owes;
            r.patientOwes = owes;
            r.status = b.Status__c;
            d.bills.add(r);
        }
        return d;
    }
}
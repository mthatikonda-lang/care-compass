@isTest
private class CareFinderControllerTest {

    @testSetup
    static void setup() {
        Provider__c prov = new Provider__c(
            Provider_Name__c = 'Test Ortho Clinic',
            Specialty__c = 'Orthopedics',
            City__c = 'Winter Garden',
            Office_Email__c = 'test@example.com'
        );
        insert prov;

        insert new Doctor__c(Name = 'Dr. Ortho Test', Provider__c = prov.Id, Specialty__c = 'Orthopedics');
        insert new Doctor__c(Name = 'Dr. Family Test', Specialty__c = 'Family Medicine');
    }

    @isTest
    static void testKneeIssueSuggestsOrthopedics() {
        Test.startTest();
        List<CareFinderController.DoctorSuggestion> results =
            CareFinderController.getSuggestedDoctors('My knee has been hurting', null);
        Test.stopTest();

        System.assertEquals(true, results[0].isSuggested);
        System.assertEquals('Orthopedics', results[0].specialty);
    }

    @isTest
    static void testUnmatchedIssueReturnsAllUnsuggested() {
        Test.startTest();
        List<CareFinderController.DoctorSuggestion> results =
            CareFinderController.getSuggestedDoctors('something very unusual', null);
        Test.stopTest();

        for (CareFinderController.DoctorSuggestion ds : results) {
            System.assertEquals(false, ds.isSuggested);
        }
    }

    @isTest
    static void testMatchingSpecialtyAndLocationRanksFirst() {
        Test.startTest();
        List<CareFinderController.DoctorSuggestion> results =
            CareFinderController.getSuggestedDoctors('My knee has been hurting', 'Winter Garden');
        Test.stopTest();

        System.assertEquals(true, results[0].isSuggested);
        System.assertEquals(true, results[0].matchesLocation);
    }

    @isTest
    static void testConfirmBookingSendsEmail() {
        Provider__c prov = [SELECT Id FROM Provider__c LIMIT 1];
        Doctor__c doc = [SELECT Id FROM Doctor__c WHERE Provider__c != null LIMIT 1];

        Patient__c patient = new Patient__c(
            First_Name__c = 'Test',
            Last_Name__c = 'Patient',
            Date_of_Birth__c = Date.newInstance(1990, 1, 1),
            Email__c = 'testpatient@example.com'
        );
        insert patient;

        Appointment__c appt = new Appointment__c(
            Patient__c = patient.Id,
            Provider__c = prov.Id,
            Doctor__c = doc.Id,
            Procedure_Type__c = 'Office Visit',
            Status__c = 'Requested'
        );
        insert appt;

        Test.startTest();
        CareFinderController.BookingResult result = CareFinderController.confirmBooking(appt.Id);
        Test.stopTest();

        System.assertEquals(true, result.success);

        Appointment__c updated = [SELECT Status__c FROM Appointment__c WHERE Id = :appt.Id];
        System.assertEquals('Call Requested', updated.Status__c);
    }

    @isTest
    static void testConfirmBookingWithNoProviderEmail() {
        Provider__c provNoEmail = new Provider__c(
            Provider_Name__c = 'No Email Clinic',
            Specialty__c = 'Family Medicine'
        );
        insert provNoEmail;

        Patient__c patient = new Patient__c(
            First_Name__c = 'Test',
            Last_Name__c = 'Patient',
            Date_of_Birth__c = Date.newInstance(1990, 1, 1),
            Email__c = 'testpatient2@example.com'
        );
        insert patient;

        Appointment__c appt = new Appointment__c(
            Patient__c = patient.Id,
            Provider__c = provNoEmail.Id,
            Procedure_Type__c = 'Office Visit',
            Status__c = 'Requested'
        );
        insert appt;

        Test.startTest();
        CareFinderController.BookingResult result = CareFinderController.confirmBooking(appt.Id);
        Test.stopTest();

        System.assertEquals(true, result.success);
        System.assert(result.message.contains('no office email'));
    }
}
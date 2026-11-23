trigger PatientProvisioningTrigger on User (after insert) {

    // Read from Custom Metadata rather than hardcoding, matching
    // PatientRegistrationController. Custom Metadata is safe to query from any
    // execution context, including ones tied to a guest-originated transaction.
    Registration_Setting__mdt settings = Registration_Setting__mdt.getInstance('Default');
    Id patientProfileId = settings != null ? settings.Patient_Profile_Id__c : null;

    List<User> newPatientUsers = new List<User>();
    for (User u : Trigger.new) {
        if (u.ProfileId == patientProfileId) {
            newPatientUsers.add(u);
        }
    }

    if (newPatientUsers.isEmpty()) {
        return;
    }

    // Step 1: create a personal Family Group per new patient, so they have
    // somewhere for Bills (Master-Detail to Family_Member__c) to attach to.
    /*List<Family_Group__c> familyGroups = new List<Family_Group__c>();
    for (User u : newPatientUsers) {
        familyGroups.add(new Family_Group__c(
            Name = u.FirstName + ' ' + u.LastName + '\'s Family',
            Shared_Out_of_Pocket_Max__c = 5000
        ));
    }
    Database.insert(familyGroups, AccessLevel.SYSTEM_MODE);*/

    // Step 2: create the Patient__c record, linked to its Family Group
    List<Patient__c> patientsToInsert = new List<Patient__c>();
    for (Integer i = 0; i < newPatientUsers.size(); i++) {
        User u = newPatientUsers[i];
        patientsToInsert.add(new Patient__c(
            First_Name__c        = u.FirstName,
            Last_Name__c         = u.LastName,
            Email__c             = u.Email,
            Phone__c             = u.Phone,
            Date_of_Birth__c     = u.Date_of_Birth__c,
            Gender__c            = u.Gender__c,
            Registration_Date__c = Date.today(),
            Status__c            = 'Active',
            Related_User__c      = u.Id
           // Family_Group__c      = familyGroups[i].Id
        ));
    }
    Database.insert(patientsToInsert, AccessLevel.SYSTEM_MODE);

    // Step 3: create the Family Member junction record (Self, primary holder)
   /* List<Family_Member__c> familyMembers = new List<Family_Member__c>();
    for (Integer i = 0; i < patientsToInsert.size(); i++) {
        familyMembers.add(new Family_Member__c(
            Family_Group__c              = familyGroups[i].Id,
            Patient__c                   = patientsToInsert[i].Id,
            Relationship_to_Primary__c   = 'Self',
            Is_Primary_Account_Holder__c = true
        ));
    }
    Database.insert(familyMembers, AccessLevel.SYSTEM_MODE);*/
}
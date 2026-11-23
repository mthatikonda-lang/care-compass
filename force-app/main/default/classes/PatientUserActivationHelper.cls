/**
 * Small helper isolating the User-object DML for activating/deactivating a patient's
 * portal User. Each method runs in @future context specifically to avoid
 * MIXED_DML_OPERATION errors — User is a "setup object" in Salesforce's DML rules, so it
 * cannot be updated in the same transaction as a non-setup object (Contact, Patient__c),
 * both of which get touched right before these calls (by Site.createExternalUser, and by
 * the Patient__c update in PatientEmailVerificationController). @future starts a fresh
 * transaction, sidestepping the conflict.
 *
 * AccessLevel.SYSTEM_MODE is used because both callers run as the Guest User (before the
 * patient has an active session), which doesn't have permission to modify User by default.
 */
public without sharing class PatientUserActivationHelper {

    @future
    public static void deactivateUser(Id userId) {
        Database.update(new User(Id = userId, IsActive = false), AccessLevel.SYSTEM_MODE);
    }

    @future
    public static void activateUser(Id userId) {
        Database.update(new User(Id = userId, IsActive = true), AccessLevel.SYSTEM_MODE);
    }
}
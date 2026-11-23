// Runs once a day. Emails the patient a reminder for every confirmed appointment that is tomorrow.
// Each appointment is marked Reminder_Sent__c once its reminder is accepted, so running the job
// again on the same day never sends a second reminder.
public without sharing class AppointmentReminderJob implements Schedulable {

    public void execute(SchedulableContext sc) {
        sendTomorrowsReminders();
    }

    // Also callable by hand, for example from Execute Anonymous, to test. Returns how many reminders were sent.
    public static Integer sendTomorrowsReminders() {
        Date tomorrow = Date.today().addDays(1);
        List<Id> ids = new List<Id>();
        for (Appointment__c a : [
            SELECT Id FROM Appointment__c
            WHERE Status__c = 'Confirmed'
              AND Appointment_Date__c = :tomorrow
              AND Reminder_Sent__c = false
            LIMIT 500
        ]) {
            ids.add(a.Id);
        }
        if (ids.isEmpty()) return 0;

        Set<Id> sent = AppointmentEmails.sendReminders(ids);
        List<Appointment__c> done = new List<Appointment__c>();
        for (Id id : sent) {
            done.add(new Appointment__c(Id = id, Reminder_Sent__c = true));
        }
        if (!done.isEmpty()) {
            update done;
        }
        return sent.size();
    }
}
// Emails to the patient about an appointment: one when it is confirmed, one the day before.
// HTML with a plain-text fallback, no health details: only the office, doctor, visit type, date and estimated cost.
public without sharing class AppointmentEmails {

    private static final String SENDER_ADDRESS = 'thatmanu602@gmail.com';

    // Sent right after the patient confirms the date the office agreed on.
    public static void sendConfirmed(Id appointmentId) {
        send(appointmentId, true);
    }

    // Used by the daily job.
    public static Boolean sendReminder(Id appointmentId) {
        return send(appointmentId, false);
    }

    private static List<Appointment__c> load(Set<Id> ids) {
        return [
            SELECT Id, Appointment_Date__c, Procedure_Type__c, Estimated_Patient_Cost__c,
                   Doctor__r.Name, Provider__r.Provider_Name__c,
                   Patient__r.Email__c, Patient__r.First_Name__c
            FROM Appointment__c
            WHERE Id IN :ids
        ];
    }

    private static Id senderId() {
        List<OrgWideEmailAddress> owa = [
            SELECT Id FROM OrgWideEmailAddress WHERE Address = :SENDER_ADDRESS LIMIT 1
        ];
        return owa.isEmpty() ? null : owa[0].Id;
    }

    // One appointment: confirmation or reminder. Returns true when Salesforce accepted the email.
    private static Boolean send(Id appointmentId, Boolean confirmation) {
        try {
            List<Appointment__c> rows = load(new Set<Id>{ appointmentId });
            if (rows.isEmpty()) return false;
            Messaging.SingleEmailMessage mail = build(rows[0], confirmation, senderId());
            if (mail == null) return false;
            Messaging.SendEmailResult[] res = Messaging.sendEmail(new Messaging.SingleEmailMessage[]{ mail }, false);
            return report(res[0], rows[0].Id);
        } catch (Exception e) {
            // Never block the patient's action because an email failed.
            ErrorLogger.log('AppointmentEmails.send', 'Error', 'Appointment email error: ' + e.getMessage(),
                'appt=' + appointmentId, String.valueOf(appointmentId));
            return false;
        }
    }

    // Many reminders in one send, because Salesforce allows only a few sendEmail calls per run.
    // Returns the ids whose email was accepted.
    public static Set<Id> sendReminders(List<Id> appointmentIds) {
        Set<Id> sent = new Set<Id>();
        try {
            if (appointmentIds == null || appointmentIds.isEmpty()) return sent;
            Id owaId = senderId();
            List<Messaging.SingleEmailMessage> mails = new List<Messaging.SingleEmailMessage>();
            List<Id> mailAppts = new List<Id>();
            for (Appointment__c a : load(new Set<Id>(appointmentIds))) {
                Messaging.SingleEmailMessage m = build(a, false, owaId);
                if (m != null) {
                    mails.add(m);
                    mailAppts.add(a.Id);
                }
            }
            if (mails.isEmpty()) return sent;
            Messaging.SendEmailResult[] res = Messaging.sendEmail(mails, false);
            for (Integer i = 0; i < res.size(); i++) {
                if (report(res[i], mailAppts[i])) {
                    sent.add(mailAppts[i]);
                }
            }
        } catch (Exception e) {
            ErrorLogger.log('AppointmentEmails.sendReminders', 'Error', 'Reminder batch error: ' + e.getMessage(),
                '', '');
        }
        return sent;
    }

    // Logs a failed send. Returns true when the email was accepted.
    private static Boolean report(Messaging.SendEmailResult sr, Id appointmentId) {
        if (sr.isSuccess()) return true;
        for (Messaging.SendEmailError err : sr.getErrors()) {
            ErrorLogger.log('AppointmentEmails.send', 'Warning',
                'Appointment email failed: ' + err.getStatusCode() + ' ' + err.getMessage(),
                'appt=' + appointmentId, String.valueOf(appointmentId));
        }
        return false;
    }

    // Builds the email for one appointment, or returns null (and logs) when it cannot be sent.
    private static Messaging.SingleEmailMessage build(Appointment__c appt, Boolean confirmation, Id owaId) {
        String to = appt.Patient__r?.Email__c;
        if (String.isBlank(to) || appt.Appointment_Date__c == null) {
            ErrorLogger.log('AppointmentEmails.send', 'Warning',
                'Appointment email skipped: no patient email or no date', 'appt=' + appt.Id, String.valueOf(appt.Id));
            return null;
        }
        String firstName = String.isNotBlank(appt.Patient__r.First_Name__c) ? appt.Patient__r.First_Name__c : 'there';
        String office = String.isNotBlank(appt.Provider__r?.Provider_Name__c) ? appt.Provider__r.Provider_Name__c : 'the office';
        String doctor = appt.Doctor__r?.Name != null ? appt.Doctor__r.Name : 'your doctor';
        String dateText = formatDate(appt.Appointment_Date__c);

        String details =
            'Doctor: ' + doctor + '\n' +
            'Office: ' + office + '\n' +
            'Visit type: ' + appt.Procedure_Type__c + '\n' +
            'Date: ' + dateText + '\n' +
            (appt.Estimated_Patient_Cost__c != null
                ? 'Estimated cost to you: $' + appt.Estimated_Patient_Cost__c.setScale(2) + ' (an estimate, not a final bill)\n'
                : '');

        String subject;
        String body;
        if (confirmation) {
            subject = 'Your appointment is confirmed for ' + dateText;
            body = 'Hi ' + firstName + ',\n\n' +
                'Your appointment is confirmed.\n\n' + details + '\n' +
                'We will send you a reminder the day before. If you need to change the time, please call the doctor\'s office.\n\n' +
                'Care Compass';
        } else {
            subject = 'Reminder: your appointment is tomorrow, ' + dateText;
            body = 'Hi ' + firstName + ',\n\n' +
                'This is a reminder that you have an appointment tomorrow.\n\n' + details + '\n' +
                'If you can no longer make it, please call the doctor\'s office as soon as you can.\n\n' +
                'Care Compass';
        }

        Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
        mail.setToAddresses(new String[]{ to });
        mail.setSubject(subject);
        mail.setPlainTextBody(body);
        mail.setHtmlBody(buildHtml(firstName, confirmation, doctor, office,
            String.valueOf(appt.Procedure_Type__c), dateText, appt.Estimated_Patient_Cost__c));
        mail.setSaveAsActivity(false);
        if (owaId != null) {
            mail.setOrgWideEmailAddressId(owaId);
        }
        return mail;
    }

    private static String row(String label, String value) {
        return '<tr><td style="padding:6px 16px 6px 0;color:#6b7280;font-size:14px;">' + label.escapeHtml4() +
            '</td><td style="padding:6px 0;color:#16213E;font-size:14px;font-weight:600;">' + value.escapeHtml4() + '</td></tr>';
    }

    private static String buildHtml(String firstName, Boolean confirmation, String doctor, String office,
                                    String visitType, String dateText, Decimal cost) {
        String headline = confirmation ? 'Your appointment is confirmed' : 'Your appointment is tomorrow';
        String intro = confirmation
            ? 'Your appointment is confirmed. We will send you a reminder the day before.'
            : 'This is a reminder that you have an appointment tomorrow.';
        String outro = confirmation
            ? 'If you need to change the time, please call the doctor\'s office.'
            : 'If you can no longer make it, please call the doctor\'s office as soon as you can.';
        String rows = row('Doctor', doctor) + row('Office', office) + row('Visit type', visitType == null ? '' : visitType) +
            row('Date', dateText);
        if (cost != null) {
            rows += row('Estimated cost', '$' + cost.setScale(2) + ' (an estimate, not a final bill)');
        }
        return '<div style="background:#f3f4f6;padding:24px 12px;font-family:Arial,Helvetica,sans-serif;">' +
            '<div style="max-width:520px;margin:0 auto;background:#ffffff;border-radius:12px;overflow:hidden;">' +
            '<div style="background:#16213E;padding:18px 24px;color:#ffffff;font-size:18px;font-weight:700;">Care Compass</div>' +
            '<div style="padding:24px;">' +
            '<h2 style="margin:0 0 12px;color:#16213E;font-size:20px;">' + headline + '</h2>' +
            '<p style="margin:0 0 6px;color:#374151;font-size:15px;">Hi ' + firstName.escapeHtml4() + ',</p>' +
            '<p style="margin:0 0 16px;color:#374151;font-size:15px;">' + intro + '</p>' +
            '<table style="border-collapse:collapse;border-top:1px solid #e5e7eb;border-bottom:1px solid #e5e7eb;width:100%;margin-bottom:16px;">' +
            rows + '</table>' +
            '<p style="margin:0;color:#374151;font-size:14px;">' + outro + '</p>' +
            '</div></div></div>';
    }

    // "Thursday, Oct 29, 2026"
    @TestVisible
    private static String formatDate(Date d) {
        return Datetime.newInstance(d.year(), d.month(), d.day()).format('EEEE, MMM d, yyyy');
    }
}
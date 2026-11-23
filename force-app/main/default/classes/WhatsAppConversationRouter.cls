/**
 * Routes an inbound WhatsApp message to the right step of the booking flow, using
 * WhatsApp_Conversation__c to remember where each phone number left off (webhook calls
 * are stateless — each POST from Meta knows nothing about the last one).
 *
 * Mirrors the same steps as the bookAppointment LWC wizard: issue -> doctor -> visit
 * details -> confirm. Reuses CareFinderController and EstimateRequestController for all
 * actual matching/pricing logic — this class only tracks state and formats messages.
 *
 * Phone-to-Patient__c identity matching is built into handleStart(): it looks up
 * Patient__c by the last 10 digits of Phone__c against the WhatsApp number, so
 * convo.Patient__c gets set automatically when a match exists. If several patients share
 * the same number (e.g. test data), the most recently modified one is used.
 *
 * Greeting handling: a plain greeting ("hi", "hello", ...) at ANY point restarts the flow.
 *
 * Declared "without sharing" so the Guest User can reliably read back the
 * WhatsApp_Conversation__c record it just created.
 *
 * CRITICAL ORDERING RULE — DML BEFORE CALLOUT: every handle* method returns the reply text
 * WITHOUT sending it. route() does all DML first, then enqueues WhatsAppReplySender (a
 * separate Queueable, fresh transaction) to make the WhatsApp callout.
 *
 * ERROR HANDLING: route() wraps the step dispatch in try/catch; unexpected exceptions go to
 * Error Log and the patient gets a fallback reply instead of silence. A System.LimitException
 * cannot be caught, so handleVisitDetails pre-checks the dental-plan/doctor combination.
 */
public without sharing class WhatsAppConversationRouter {

    private static final Set<String> GREETINGS = new Set<String>{
        'hi', 'hii', 'hiii', 'hello', 'hey', 'hola', 'hi there', 'hello there',
        'good morning', 'good afternoon', 'good evening'
    };

    // Number of doctors offered in a WhatsApp reply (BUG-19: at least 5).
    private static final Integer MAX_OPTIONS = 5;

    // BUG-29: short closing messages that should get a sign-off, not a doctor search.
    private static final Set<String> ACKNOWLEDGEMENTS = new Set<String>{
        'thanks', 'thank you', 'thankyou', 'thx', 'ty', 'ok', 'okay', 'k', 'kk', 'okie',
        'great', 'cool', 'got it', 'noted', 'perfect', 'nice', 'thanks a lot', 'thank you so much',
        'bye', 'goodbye', 'good night', 'done', 'all done', 'finished', 'thats all', 'that is all',
        'all good', 'alright', 'fine', 'thank u', 'thnx', 'tq', 'thanks bye', 'ok thanks', 'okay thanks',
        'ok thank you', 'okay thank you', 'awesome', 'sure', 'welcome', 'yes thanks'
    };

    // BUG-20: how far ahead a visit can be requested, in days (no same-day requests).
    private static final Integer MAX_DAYS_AHEAD = 365;

    private static final String WELCOME_PROMPT =
        'How can I help you? Please tell me the speciality you are looking for.';

    private static final String GENERIC_ERROR_REPLY =
        'Sorry, something went wrong on our side. Please try again, or reply "hi" to start over.';

    public static void route(String fromNumber, String messageBody) {
        WhatsApp_Conversation__c convo = getOrCreateConversation(fromNumber);
        String replyText;
        String normalized = messageBody == null ? '' : messageBody.trim().toLowerCase();

        // Same text with punctuation stripped, so "Hello!" and "hi." still count as greetings.
        String greetingCheck = normalized.replaceAll('[^a-z ]', '').trim();

        try {
            // Safety net: if this conversation somehow still has no Patient__c, retry the phone
            // match on every message.
            if (convo.Patient__c == null) {
                Patient__c matched = findPatientByPhone(convo.Phone_Number__c);
                if (matched != null) {
                    convo.Patient__c = matched.Id;
                }
            }

            Boolean idleStep = convo.Step__c == 'Booked' || convo.Step__c == 'Started' || convo.Step__c == 'AwaitingIssue';

            if (GREETINGS.contains(greetingCheck)) {
                convo.Step__c = 'Started';
                replyText = handleStart(convo, true);
            } else if (idleStep && ACKNOWLEDGEMENTS.contains(greetingCheck)) {
                // BUG-29: just say goodbye. No matching, and the step stays as it was.
                replyText = 'You\'re welcome! Reply "hi" any time to book another visit.';
            } else if (convo.Step__c == 'Started' && (normalized == 'new' || normalized == 'book another')) {
                replyText = handleStart(convo, false);
            } else if (normalized == 'check my bill') {
                replyText = handleCheckBill(convo);
            } else if (normalized == 'book a doctor') {
                convo.Step__c = 'AwaitingIssue';
                replyText = handleBookADoctorButton(convo);
            } else {
                switch on convo.Step__c {
                    when 'Started' {
                        replyText = handleStart(convo, true);
                    }
                    when 'AwaitingIssue' {
                        replyText = handleIssue(convo, messageBody);
                    }
                    when 'AwaitingZip' {
                        replyText = handleZip(convo, messageBody);
                    }
                    when 'AwaitingDoctorChoice' {
                        replyText = handleDoctorChoice(convo, messageBody);
                    }
                    when 'AwaitingVisitDetails' {
                        replyText = handleVisitDetails(convo, messageBody);
                    }
                    when 'AwaitingConfirmation' {
                        replyText = handleConfirmation(convo, messageBody);
                    }
                    when else {
                        // Booked, or unrecognized state — restart the flow
                        convo.Step__c = 'Started';
                        replyText = handleStart(convo, true);
                    }
                }
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'WhatsAppConversationRouter.route failed at step '
                + convo.Step__c + ': ' + e.getMessage() + ' | ' + e.getStackTraceString());
            ErrorLogger.log(
                'WhatsAppConversationRouter.route',
                'Error',
                'Booking chat failed at step ' + convo.Step__c,
                'phone ending ' + (fromNumber == null ? '' : fromNumber.right(4))
                    + '\nmessage: ' + messageBody
                    + '\n' + e.getTypeName() + ': ' + e.getMessage()
                    + '\n' + e.getStackTraceString(),
                null
            );
            replyText = GENERIC_ERROR_REPLY;
        }

        convo.Last_Message_At__c = System.now();
        System.debug('DEBUG route save: step=' + convo.Step__c + ' | issue=' + convo.Issue_Text__c
            + ' | doctorIds=' + convo.Selected_Doctor_Id__c + ' | providerIds=' + convo.Selected_Provider_Id__c
            + ' | reply=' + replyText);
        try {
            upsert convo Phone_Number__c;
        } catch (DmlException saveEx) {
            // Log the exact field/reason, then tell the patient instead of going silent.
            System.debug(LoggingLevel.ERROR, 'DEBUG route save FAILED: ' + saveEx.getDmlMessage(0)
                + ' | fields=' + saveEx.getDmlFieldNames(0));
            ErrorLogger.log(
                'WhatsAppConversationRouter.route',
                'Error',
                'Saving the conversation failed at step ' + convo.Step__c,
                'DML message: ' + saveEx.getDmlMessage(0)
                    + '\nfields: ' + saveEx.getDmlFieldNames(0)
                    + '\nstep: ' + convo.Step__c
                    + '\ndoctorIds length: ' + (convo.Selected_Doctor_Id__c == null ? 0 : convo.Selected_Doctor_Id__c.length())
                    + '\nproviderIds length: ' + (convo.Selected_Provider_Id__c == null ? 0 : convo.Selected_Provider_Id__c.length()),
                null
            );
            System.enqueueJob(new WhatsAppReplySender(convo.Phone_Number__c, GENERIC_ERROR_REPLY));
            return;
        }

        // Transcript: inbound always logged; outbound only if this step produced a reply.
        List<WhatsApp_Message__c> messageLog = new List<WhatsApp_Message__c>();
        messageLog.add(new WhatsApp_Message__c(
            Conversation__c = convo.Id,
            Direction__c = 'Inbound',
            Message_Body__c = messageBody,
            Sent_At__c = System.now()
        ));
        if (String.isNotBlank(replyText)) {
            messageLog.add(new WhatsApp_Message__c(
                Conversation__c = convo.Id,
                Direction__c = 'Outbound',
                Message_Body__c = replyText,
                Sent_At__c = System.now()
            ));
        }
        insert messageLog;

        // The callout must happen in a NEW transaction, hence enqueueing.
        if (String.isNotBlank(replyText)) {
            System.enqueueJob(new WhatsAppReplySender(convo.Phone_Number__c, replyText));
        }
    }

    // ---------------------------------------------------------------
    private static String handleCheckBill(WhatsApp_Conversation__c convo) {
        return 'Bill checking isn\'t available over WhatsApp yet — please log into the Care Compass app to check your bills for now.';
    }

    private static String handleBookADoctorButton(WhatsApp_Conversation__c convo) {
        if (convo.Step__c == 'AwaitingZip' || convo.Step__c == 'AwaitingDoctorChoice' || convo.Step__c == 'AwaitingVisitDetails'
            || convo.Step__c == 'AwaitingConfirmation') {
            return 'You\'re already partway through booking — just reply to the last question to continue.';
        }

        if (convo.Patient__c != null) {
            String existing = findUpcomingBooking(convo.Patient__c);
            if (existing != null) {
                convo.Step__c = 'Started';
                return 'You already have a callback request:\n\n' + existing
                    + '\nIf you still want to book another visit, reply NEW.';
            }
        }

        convo.Step__c = 'AwaitingIssue';
        return 'Great! Please tell me the speciality you are looking for, or describe your symptom ' +
            '(e.g. "cardiology", "knee pain" or "annual checkup").';
    }

    private static String handleStart(WhatsApp_Conversation__c convo, Boolean checkExisting) {
        Patient__c matched = findPatientByPhone(convo.Phone_Number__c);
        convo.Step__c = 'AwaitingIssue';

        // BUG-21: show an upcoming booking before starting another one.
        if (checkExisting && matched != null) {
            String existing = findUpcomingBooking(matched.Id);
            if (existing != null) {
                convo.Patient__c = matched.Id;
                convo.Step__c = 'Started';
                return 'Hi ' + matched.First_Name__c + '! You already have a callback request:\n\n' + existing
                    + '\nIf you still want to book another visit, reply NEW.';
            }
        }

        if (matched != null) {
            convo.Patient__c = matched.Id;
            return 'Welcome to Care Compass, ' + matched.First_Name__c + '! ' + WELCOME_PROMPT;
        }

        return 'Welcome to Care Compass! ' + WELCOME_PROMPT + ' ' +
            '(We don\'t see a patient record for this number yet, so please register through ' +
            'the Care Compass app if you haven\'t already, or we may not be able to finish booking.)';
    }

    /** Returns the summary of the patient's next requested visit, or null if there is none. */
    private static String findUpcomingBooking(Id patientId) {
        List<Appointment__c> upcoming = [
            SELECT Id FROM Appointment__c
            WHERE Patient__c = :patientId
              AND Status__c IN ('Call Requested', 'Confirmed')
              AND Appointment_Date__c >= :Date.today()
            ORDER BY Appointment_Date__c ASC
            LIMIT 1
        ];
        return upcoming.isEmpty() ? null : getAppointmentSummary(upcoming[0].Id);
    }

    /**
     * Matches a WhatsApp number against Patient__c.Phone__c by the last 10 digits of both
     * sides. Newest first, so if several patients share a number the most recently
     * updated one is used.
     */
    private static Patient__c findPatientByPhone(String fromNumber) {
        String targetSuffix = last10Digits(fromNumber);
        if (String.isBlank(targetSuffix)) {
            return null;
        }

        for (Patient__c p : [
            SELECT Id, First_Name__c, Phone__c
            FROM Patient__c
            WHERE Phone__c != null
            ORDER BY LastModifiedDate DESC
        ]) {
            if (last10Digits(p.Phone__c) == targetSuffix) {
                return p;
            }
        }
        return null;
    }

    private static String last10Digits(String phone) {
        if (phone == null) {
            return '';
        }
        String digitsOnly = phone.replaceAll('[^0-9]', '');
        return digitsOnly.length() > 10 ? digitsOnly.right(10) : digitsOnly;
    }

    /**
     * Parses "MM/DD/YYYY" (also "M/D/YYYY") explicitly instead of the locale-sensitive
     * Date.parse(). Returns null for anything that doesn't match.
     */
    private static Date parseAppointmentDate(String raw) {
        if (String.isBlank(raw)) {
            return null;
        }
        List<String> parts = raw.split('/');
        if (parts.size() != 3) {
            return null;
        }
        try {
            Integer month = Integer.valueOf(parts[0].trim());
            Integer day = Integer.valueOf(parts[1].trim());
            Integer year = Integer.valueOf(parts[2].trim());
            if (parts[2].trim().length() != 4 || month < 1 || month > 12 || day < 1 || day > 31) {
                return null;
            }
            Date d = Date.newInstance(year, month, day);
            // Apex rolls invalid dates over (e.g. 02/31 becomes 03/03), so reject any roll-over.
            if (d.month() != month || d.day() != day || d.year() != year) {
                return null;
            }
            return d;
        } catch (Exception e) {
            return null;
        }
    }

    private static String handleIssue(WhatsApp_Conversation__c convo, String messageBody) {
        // Same search as the portal. An empty list means the text is not a medical concern.
        List<CareFinderController.DoctorSuggestion> doctors =
            CareFinderController.getSuggestedDoctorsForPatient(messageBody, null, convo.Patient__c);

        if (doctors.isEmpty()) {
            return 'I couldn\'t match that to a medical concern. Please describe your symptoms or the type ' +
                'of doctor you need (for example "knee pain", "skin rash" or "cardiology").';
        }

        // Keep the issue and ask for a ZIP code, so the nearest doctors can be listed first.
        convo.Issue_Text__c = messageBody.left(255);
        convo.Step__c = 'AwaitingZip';
        return 'Thanks. What is your ZIP code? I\'ll show the nearest doctors first. ' +
            'Reply with 5 digits (for example 02865), or SKIP to continue without it.';
    }

    private static String handleZip(WhatsApp_Conversation__c convo, String messageBody) {
        String answer = messageBody == null ? '' : messageBody.trim();
        String zip = null;
        if (answer.equalsIgnoreCase('skip')) {
            zip = null;
        } else if (Pattern.matches('\\d{5}', answer)) {
            zip = answer;
        } else {
            return 'Please reply with a 5-digit ZIP code, for example 02865, or SKIP.';
        }

        if (String.isBlank(convo.Issue_Text__c)) {
            convo.Step__c = 'AwaitingIssue';
            return 'Please tell me the speciality you are looking for, or describe your symptom.';
        }

        // Same search as the portal: same matching, same order, nearest first when a ZIP is given.
        System.debug('DEBUG handleZip start: zip=' + zip + ' | issue=' + convo.Issue_Text__c);
        List<CareFinderController.DoctorSuggestion> doctors;
        try {
            doctors = CareFinderController.getSuggestedDoctorsForPatient(convo.Issue_Text__c, zip, convo.Patient__c);
        } catch (CareFinderController.CareFinderException e) {
            // Unknown ZIP etc. Stay on the ZIP step so the patient can retype it or reply SKIP.
            return e.getMessage() + ' Or reply SKIP.';
        } catch (Exception e) {
            ErrorLogger.logException('WhatsAppConversationRouter.handleZip', e, null);
            return 'Sorry, I couldn\'t look up that ZIP code. Please check it and try again, or reply SKIP.';
        }

        System.debug('DEBUG handleZip search done: doctors=' + doctors.size());
        if (doctors.isEmpty()) {
            convo.Step__c = 'AwaitingIssue';
            return 'I couldn\'t match that to a medical concern. Please describe your symptoms or the type ' +
                'of doctor you need (for example "knee pain", "skin rash" or "cardiology").';
        }

        List<CareFinderController.DoctorSuggestion> options = new List<CareFinderController.DoctorSuggestion>();
        for (Integer i = 0; i < Math.min(MAX_OPTIONS, doctors.size()); i++) {
            options.add(doctors[i]);
        }

        String reply = '';
        if (doctors[0].emergencyFlag == true) {
            reply += 'What you describe may be an emergency. If you have chest pain, trouble breathing, ' +
                'or severe bleeding, call 911 or go to the nearest ER instead of booking a visit.\n\n';
        }
        reply += zip != null ? 'Here are the nearest doctors that could help:\n'
                             : 'Here are some doctors that could help:\n';
        List<String> doctorIds = new List<String>();
        List<String> providerIds = new List<String>();
        for (Integer i = 0; i < options.size(); i++) {
            CareFinderController.DoctorSuggestion d = options[i];
            String cityPart = String.isNotBlank(d.city) ? ', ' + d.city : '';
            String away = d.distanceMiles != null ? ' (about ' + d.distanceMiles + ' mi)' : '';
            reply += (i + 1) + '. ' + d.doctorName + ' — ' + d.specialty + cityPart + away + '\n';
            doctorIds.add(d.doctorId);
            providerIds.add(d.providerId);
        }
        reply += '\nReply with a number to pick one.';
        if (doctors.size() > options.size()) {
            reply += '\n\nFor more options, log into the Care Compass app to see the full list.';
        }

        convo.Pending_Estimate_Id__c = null;
        convo.Selected_Doctor_Id__c = String.join(doctorIds, ',');
        convo.Selected_Provider_Id__c = String.join(providerIds, ',');
        convo.Step__c = 'AwaitingDoctorChoice';
        return reply;
    }

    private static String handleDoctorChoice(WhatsApp_Conversation__c convo, String messageBody) {
        List<String> doctorCandidateIds = convo.Selected_Doctor_Id__c.split(',');
        List<String> providerCandidateIds = convo.Selected_Provider_Id__c.split(',');
        Integer choice = null;
        try {
            choice = Integer.valueOf(messageBody.trim());
        } catch (Exception e) {
            // not a number
        }

        if (choice == null || choice < 1 || choice > doctorCandidateIds.size() || String.isBlank(doctorCandidateIds[choice - 1])) {
            return 'Please reply with just the number of the doctor you\'d like (1 to ' + doctorCandidateIds.size() + ').';
        }

        // Narrow down to the single chosen doctor/provider pair
        convo.Selected_Doctor_Id__c = doctorCandidateIds[choice - 1];
        convo.Selected_Provider_Id__c = providerCandidateIds[choice - 1];
        convo.Step__c = 'AwaitingVisitDetails';
        return 'Got it. What date would you like to come in? (e.g. "MM/DD/YYYY")';
    }

    private static String handleVisitDetails(WhatsApp_Conversation__c convo, String messageBody) {

        Date appointmentDate = parseAppointmentDate(messageBody.trim());
        System.debug('appointmentDate:::' + appointmentDate);
        System.debug(':::Date.today():::' + Date.today());
        if (appointmentDate == null) {
            return 'Sorry, I didn\'t catch that date — try a format like "10/15/2026" (MM/DD/YYYY).';
        }

        if (appointmentDate <= Date.today()) {
            return 'Please choose a date from tomorrow onward — we can\'t request a same-day visit.';
        }
        if (appointmentDate > Date.today().addDays(MAX_DAYS_AHEAD)) {
            return 'That date is too far ahead. Please choose a date within the next year (on or before '
                + Date.today().addDays(MAX_DAYS_AHEAD).format() + ').';
        }

        // An estimate needs a real patient.
        if (convo.Patient__c == null) {
            convo.Step__c = 'Started';
            ErrorLogger.log(
                'WhatsAppConversationRouter.handleVisitDetails',
                'Warning',
                'No Patient__c matched this WhatsApp number',
                'phone ending ' + (convo.Phone_Number__c == null ? '' : convo.Phone_Number__c.right(4)),
                null
            );
            return 'I couldn\'t find a patient record for this WhatsApp number, so I can\'t price this visit. ' +
                'Please make sure the phone number on your Care Compass profile matches this WhatsApp number, then reply "hi" to start again.';
        }

        // Dental plans only work with dentists (and dental visit types). Check this up front:
        // the estimate code rejects the combination with an exception that can't be caught here.
        Boolean dentalPlan = false;
        for (Patient__c p : [
            SELECT Insurance_Plan__r.Name, Insurance_Plan__r.Insurance_Carrier__c
            FROM Patient__c
            WHERE Id = :convo.Patient__c
            LIMIT 1
        ]) {
            if (p.Insurance_Plan__r != null) {
                String planText = ((p.Insurance_Plan__r.Name == null ? '' : p.Insurance_Plan__r.Name) + ' '
                    + (p.Insurance_Plan__r.Insurance_Carrier__c == null ? '' : p.Insurance_Plan__r.Insurance_Carrier__c)).toLowerCase();
                dentalPlan = planText.contains('dental');
            }
        }

        Boolean doctorIsDentist = false;
        for (Doctor__c d : [
            SELECT Specialty__c FROM Doctor__c WHERE Id = :convo.Selected_Doctor_Id__c LIMIT 1
        ]) {
            doctorIsDentist = d.Specialty__c != null && d.Specialty__c.toLowerCase().contains('dent');
        }

        if (dentalPlan && !doctorIsDentist) {
            convo.Step__c = 'AwaitingIssue';
            return 'The insurance plan on your profile is a dental plan, which only covers dentists. ' +
                'Please tell me your dental concern (e.g. "tooth pain" or "cleaning"), or update your insurance plan in the Care Compass app.';
        }

        EstimateRequestController.EstimateResult estimate;
        try {
            estimate = EstimateRequestController.requestEstimate(
                convo.Patient__c,
                convo.Selected_Provider_Id__c,
                convo.Selected_Doctor_Id__c,
                dentalPlan ? 'Dental Exam' : 'Office Visit',   // TODO: capture actual procedure type from patient
                appointmentDate
            );
        } catch (AuraHandledException e) {
            // requestEstimate throws this when no Price_Benchmark__c exists for the procedure type
            convo.Step__c = 'Started';
            return 'Sorry, we don\'t have pricing on file for that visit type yet — someone from our office will follow up directly.';
        } catch (Exception e) {
            convo.Step__c = 'Started';
            ErrorLogger.logException('WhatsAppConversationRouter.handleVisitDetails', e, null);
            return 'Sorry, I couldn\'t prepare your estimate right now. Please try again in a bit, or reply "hi" to start over.';
        }

        convo.Pending_Estimate_Id__c = estimate.appointmentId;
        convo.Step__c = 'AwaitingConfirmation';
        if (estimate.estimatedPatientCost == null) {
            // Never show "$null". The office will quote the price when they call back.
            ErrorLogger.log('WhatsAppConversationRouter.handleVisitDetails', 'Warning',
                'Estimate returned no patient cost', 'appointmentId=' + estimate.appointmentId
                + ' | patient=' + convo.Patient__c + ' | doctor=' + convo.Selected_Doctor_Id__c, null);
            return 'Dental visits aren\'t estimated by this tool, so the office will give you pricing when they call. '
                + 'Reply YES to send your callback request, or NO to cancel.';
        }
        return 'Estimated cost: $' + estimate.estimatedPatientCost + '. Reply YES to confirm this booking, or NO to cancel.';
    }

    private static String handleConfirmation(WhatsApp_Conversation__c convo, String messageBody) {
        String answer = messageBody.trim().toLowerCase();

        if (answer == 'yes' || answer == 'y') {
            CareFinderController.BookingResult result = CareFinderController.confirmBookingWithIssue(
                convo.Pending_Estimate_Id__c, convo.Issue_Text__c);

            if (!result.success) {
                // Don't mark the chat Booked on failure — restart so the patient can try again.
                convo.Step__c = 'Started';
                return 'Something went wrong confirming your booking: ' + result.message;
            }

            convo.Step__c = 'Booked';
            String details = getAppointmentSummary(convo.Pending_Estimate_Id__c);
            return 'You\'re all set — booked!\n\n' + details + '\n' + result.message;
        } else if (answer == 'no' || answer == 'n') {
            convo.Step__c = 'Started';
            return 'No problem, cancelled. Let me know if you\'d like to start over.';
        } else {
            return 'Just reply YES to confirm or NO to cancel.';
        }
    }

    /**
     * Pulls the doctor, provider, date, procedure, and cost off the just-confirmed
     * Appointment__c so the final WhatsApp message shows what was actually booked.
     */
    private static String getAppointmentSummary(Id appointmentId) {
        if (appointmentId == null) {
            return '';
        }

        List<Appointment__c> appts = [
            SELECT Doctor__r.Name, Provider__r.Provider_Name__c,
                   Procedure_Type__c, Appointment_Date__c, Estimated_Patient_Cost__c
            FROM Appointment__c
            WHERE Id = :appointmentId
            LIMIT 1
        ];
        if (appts.isEmpty()) {
            return '';
        }

        Appointment__c appt = appts[0];
        String doctorLine = appt.Doctor__r != null ? appt.Doctor__r.Name : 'No preference specified';
        String providerLine = appt.Provider__r != null ? appt.Provider__r.Provider_Name__c : '';
        String dateLine = appt.Appointment_Date__c != null ? appt.Appointment_Date__c.format() : 'Not specified';
        String costLine = appt.Estimated_Patient_Cost__c != null ? '$' + appt.Estimated_Patient_Cost__c : 'Not available';

        return 'Doctor: ' + doctorLine + '\n' +
               (String.isNotBlank(providerLine) ? 'Office: ' + providerLine + '\n' : '') +
               'Type of visit: ' + appt.Procedure_Type__c + '\n' +
               'Requested date: ' + dateLine + '\n' +
               'Estimated cost: ' + costLine + '\n';
    }

    // ---------------------------------------------------------------
    private static WhatsApp_Conversation__c getOrCreateConversation(String fromNumber) {
        List<WhatsApp_Conversation__c> existing = [
            SELECT Id, Phone_Number__c, Patient__c, Step__c, Selected_Doctor_Id__c,
                   Selected_Provider_Id__c, Pending_Estimate_Id__c, Issue_Text__c
            FROM WhatsApp_Conversation__c
            WHERE Phone_Number__c = :fromNumber
            LIMIT 1
        ];
        if (!existing.isEmpty()) {
            return existing[0];
        }

        // Not inserted here — route() does a single upsert (by Phone_Number__c, the
        // External Id/Unique field) after the dispatch.
        return new WhatsApp_Conversation__c(
            Phone_Number__c = fromNumber,
            Step__c = 'Started'
        );
    }
}
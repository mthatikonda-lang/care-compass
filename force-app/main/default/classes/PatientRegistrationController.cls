public without sharing class PatientRegistrationController {

    // Minimum rules enforced here regardless of org/profile password policy.
    // Site.validatePassword below then applies the org's own policy on top.
    private static final Integer MIN_PASSWORD_LENGTH = 8;

    @AuraEnabled
    public static String registerPatient(String firstName, String lastName, String email,
                                          String password, String dob, String gender, String phone) {
        try {
            if (String.isBlank(firstName) || String.isBlank(lastName) ||
                String.isBlank(email) || String.isBlank(password) || String.isBlank(phone)) {
                throw new AuraHandledException('Please fill in all required fields.');
            }

            String passwordProblem = checkPasswordRules(password);
            if (passwordProblem != null) {
                throw new AuraHandledException(passwordProblem);
            }

            String dobProblem = checkDateOfBirth(dob);
            if (dobProblem != null) {
                throw new AuraHandledException(dobProblem);
            }

            String emailProblem = checkEmail(email);
            if (emailProblem != null) {
                throw new AuraHandledException(emailProblem);
            }

            String phoneProblem = checkPhone(phone);
            if (phoneProblem != null) {
                throw new AuraHandledException(phoneProblem);
            }
            String cleanPhone = normalizePhone(phone);

            // Prevent duplicate registration on the same email
            List<Patient__c> existing = [SELECT Id FROM Patient__c WHERE Email__c = :email LIMIT 1];
            if (!existing.isEmpty()) {
                throw new AuraHandledException('An account with this email already exists.');
            }

            // Ids come from a Custom Metadata Type rather than being hardcoded —
            // Custom Metadata is readable by Guest User without restriction, unlike
            // Profile or Account (which either can't be queried or return zero rows
            // for guest context). This also means these values are configurable data,
            // not code, so this class deploys cleanly to any other org.
            Registration_Setting__mdt settings = Registration_Setting__mdt.getInstance('Default');
            if (settings == null) {
                ErrorLogger.log('PatientRegistrationController.registerPatient', 'Error',
                    'Registration_Setting__mdt "Default" record not found', null, null);
                throw new AuraHandledException('Registration is temporarily unavailable. Please try again later.');
            }
            Id portalAccountId = settings.Patient_Portal_Account_Id__c;
            Id patientProfileId = settings.Patient_Profile_Id__c;

            String uniqueUsername = email + '.coveragechecker';

            User newUser = new User(
                FirstName        = firstName,
                LastName         = lastName,
                Email            = email,
                Phone            = cleanPhone,
                Username         = uniqueUsername,
                Alias            = generateAlias(firstName, lastName),
                CommunityNickname = generateNickname(firstName, lastName),
                ProfileId        = patientProfileId,
                TimeZoneSidKey   = 'America/New_York',
                LocaleSidKey     = 'en_US',
                EmailEncodingKey = 'UTF-8',
                LanguageLocaleKey = 'en_US',
                Date_of_Birth__c = Date.valueOf(dob),
                Gender__c        = gender
            );

            // Apply the org / profile password policy before creating anything.
            try {
                Site.validatePassword(newUser, password, password);
            } catch (Exception pe) {
                throw new AuraHandledException(
                    'Your password does not meet the password requirements. ' + pe.getMessage());
            }

            // Site.createExternalUser handles Contact creation under the given Account,
            // links it to a new User, and runs in a guest-safe system context.
            // A trigger on User (after insert) picks up Date_of_Birth__c and Gender__c
            // from this record and provisions the matching Patient__c — creating
            // Patient__c directly here would fail with
            // INSUFFICIENT_ACCESS_ON_CROSS_REFERENCE_ENTITY, since Guest User code
            // (even without sharing, even via @future) cannot reference a User record
            // on a lookup field. Triggers run in full system context and don't have
            // this restriction.
            //
            // The user is created active and can log in immediately — there is no email
            // verification step. The site's own welcome email (Administration > Emails)
            // greets the new patient.
            String newUserId = Site.createExternalUser(newUser, portalAccountId, password, false);

            if (String.isBlank(newUserId)) {
                ErrorLogger.log('PatientRegistrationController.registerPatient', 'Error',
                    'Site.createExternalUser returned a blank user Id', 'username=' + uniqueUsername, null);
                throw new AuraHandledException('Registration failed. Please check your details and try again.');
            }

            // Give the new patient the permission set that lets Care Finder call the
            // Prompt Builder template (AI specialty matching). Runs in @future because
            // PermissionSetAssignment is a setup object and can't share a transaction
            // with the Contact that Site.createExternalUser just created.
            PatientPermissionAssigner.assign(new Set<Id>{ (Id) newUserId });

            return newUserId;

        } catch (AuraHandledException ahe) {
            // Expected, user-facing problems (validation, duplicate email, weak password)
            // are not logged here.
            throw ahe;
        } catch (Exception e) {
            ErrorLogger.logException('PatientRegistrationController.registerPatient', e, null);
            throw new AuraHandledException('Registration error: ' + e.getMessage());
        }
    }

    // Returns a user-facing message listing every unmet password rule, otherwise null.
    // Rules: at least 8 characters, one uppercase letter, one lowercase letter,
    // one number and one special character. Keep this list in step with the
    // checklist on the registration page and the site's password policy.
    @TestVisible
    private static String checkPasswordRules(String password) {
        List<String> missing = new List<String>();
        if (password == null || password.length() < MIN_PASSWORD_LENGTH) {
            missing.add('at least ' + MIN_PASSWORD_LENGTH + ' characters');
        }
        String pw = password == null ? '' : password;
        if (!Pattern.compile('.*[A-Z].*').matcher(pw).matches()) {
            missing.add('one uppercase letter');
        }
        if (!Pattern.compile('.*[a-z].*').matcher(pw).matches()) {
            missing.add('one lowercase letter');
        }
        if (!Pattern.compile('.*[0-9].*').matcher(pw).matches()) {
            missing.add('one number');
        }
        if (!Pattern.compile('.*[^A-Za-z0-9].*').matcher(pw).matches()) {
            missing.add('one special character (for example ! @ # $ %)');
        }
        if (missing.isEmpty()) {
            return null;
        }
        return 'Your password needs: ' + String.join(missing, ', ') + '.';
    }

    // Returns a user-facing message if the date of birth is missing, malformed,
    // in the future, or implausibly old; otherwise null.
    @TestVisible
    private static String checkDateOfBirth(String dob) {
        if (String.isBlank(dob)) {
            return 'Please enter your date of birth.';
        }
        Date parsed;
        try {
            parsed = Date.valueOf(dob);
        } catch (Exception e) {
            return 'Please enter a valid date of birth.';
        }
        if (parsed > Date.today()) {
            return 'Date of birth cannot be in the future.';
        }
        if (parsed < Date.today().addYears(-120)) {
            return 'Please enter a valid date of birth.';
        }
        return null;
    }

    // Returns a user-facing message if the email is not a valid address, otherwise null.
    // Length cap: the username is email + '.coveragechecker' and User.Username allows 80 chars.
    @TestVisible
    private static String checkEmail(String email) {
        if (String.isBlank(email)) {
            return 'Please enter your email address.';
        }
        if (email.length() > 64) {
            return 'Email address is too long (maximum 64 characters).';
        }
        Pattern emailPattern = Pattern.compile('^[A-Za-z0-9._%+\\-]+@[A-Za-z0-9\\-]+(\\.[A-Za-z0-9\\-]+)*\\.[A-Za-z]{2,}$');
        if (!emailPattern.matcher(email).matches()) {
            return 'Please enter a valid email address, for example name@example.com.';
        }
        return null;
    }

    // Phone is required. It must be exactly 10 digits, optionally preceded by
    // the country code +1 or +91, once spaces, dashes, dots and parentheses
    // are ignored.
    @TestVisible
    private static String checkPhone(String phone) {
        if (String.isBlank(phone)) {
            return 'Please enter your mobile number.';
        }
        String digits = normalizePhone(phone);
        if (!Pattern.compile('^(\\+1|\\+91)?[0-9]{10}$').matcher(digits).matches()) {
            return 'Mobile number must be 10 digits, optionally starting with +1 or +91.';
        }
        return null;
    }

    @TestVisible
    private static String normalizePhone(String phone) {
        return String.isBlank(phone) ? null : phone.replaceAll('[\\s().\\-]', '');
    }

    private static String generateAlias(String firstName, String lastName) {
        String alias = (firstName + lastName).replaceAll('[^a-zA-Z0-9]', '');
        return alias.length() > 8 ? alias.substring(0, 8) : alias;
    }

    private static String generateNickname(String firstName, String lastName) {
        Integer rand = Integer.valueOf(Math.round(Math.random() * 10000));
        String nickname = (firstName + lastName + String.valueOf(rand)).replaceAll('[^a-zA-Z0-9]', '');
        return nickname.length() > 40 ? nickname.substring(0, 40) : nickname;
    }
}
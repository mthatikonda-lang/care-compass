public without sharing class PatientLoginController {

    // Logs the patient in and returns the page to open next.
    // The same message is returned for every failure so the page never reveals whether a username exists.
    @AuraEnabled
    public static String login(String username, String password, String startUrl) {
        if (String.isBlank(username) || String.isBlank(password)) {
            throw new AuraHandledException('Enter your username and password.');
        }
        PageReference next;
        try {
            next = Site.login(username.trim(), password, String.isBlank(startUrl) ? '/coveragechecker/' : startUrl);
        } catch (Exception e) {
            next = null;
        }
        if (next == null) {
            AuraHandledException ex = new AuraHandledException('That username or password is not right. Please try again.');
            ex.setMessage('That username or password is not right. Please try again.');
            throw ex;
        }
        return next.getUrl();
    }

    // Sends the reset email. Always reports the same result, whether or not the username exists.
    @AuraEnabled
    public static void forgotPassword(String username) {
        if (String.isBlank(username)) {
            throw new AuraHandledException('Enter your username first.');
        }
        try {
            Site.forgotPassword(username.trim());
        } catch (Exception e) {
            // Intentionally silent.
        }
    }
}
/**
 * Publishes an Error_Log_Event__e (Publish Immediately), which ErrorLogEventTrigger turns
 * into an Error_Log__c row. Publishing immediately means the log survives even when the
 * calling transaction is rolled back by an exception. Never throws.
 */
public without sharing class ErrorLogger {

    public static void log(String source, String severity, String message, String details, String relatedId) {
        try {
            Database.SaveResult sr = EventBus.publish(new Error_Log_Event__e(
                Source__c     = clip(source, 100),
                Severity__c   = clip(severity, 20),
                Message__c    = clip(message, 32768),
                Details__c    = clip(details, 32768),
                Related_Id__c = clip(relatedId, 18),
                User_Id__c    = UserInfo.getUserId()
            ));
            if (!sr.isSuccess()) {
                System.debug(LoggingLevel.ERROR, 'ErrorLogger publish failed: ' + sr.getErrors());
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.ERROR, 'ErrorLogger failed: ' + e.getMessage());
        }
    }

    public static void logException(String source, Exception e, String relatedId) {
        log(source, 'Error', e.getTypeName() + ': ' + e.getMessage(),
            e.getStackTraceString(), relatedId);
    }

    private static String clip(String s, Integer max) {
        return (s != null && s.length() > max) ? s.substring(0, max) : s;
    }
}
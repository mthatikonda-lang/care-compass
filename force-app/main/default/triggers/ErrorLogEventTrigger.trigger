trigger ErrorLogEventTrigger on Error_Log_Event__e (after insert) {
    List<Error_Log__c> rows = new List<Error_Log__c>();
    for (Error_Log_Event__e e : Trigger.new) {
        rows.add(new Error_Log__c(
            Source__c       = e.Source__c,
            Severity__c     = e.Severity__c,
            Message__c      = e.Message__c,
            Details__c      = e.Details__c,
            Related_Id__c   = e.Related_Id__c,
            Running_User__c = e.User_Id__c
        ));
    }

    List<Database.SaveResult> results = Database.insert(rows, false);
    for (Integer i = 0; i < results.size(); i++) {
        if (results[i].isSuccess()) {
            System.debug('DEBUG ErrorLog saved: ' + results[i].getId());
        } else {
            for (Database.Error err : results[i].getErrors()) {
                System.debug(LoggingLevel.ERROR, 'DEBUG ErrorLog insert FAILED: '
                    + err.getStatusCode() + ' | ' + err.getMessage()
                    + ' | fields=' + err.getFields()
                    + ' | source=' + rows[i].Source__c
                    + ' | messageLength=' + (rows[i].Message__c == null ? 0 : rows[i].Message__c.length())
                    + ' | detailsLength=' + (rows[i].Details__c == null ? 0 : rows[i].Details__c.length()));
            }
        }
    }
}
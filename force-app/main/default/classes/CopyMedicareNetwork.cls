/**
 * One-time data load. For every doctor who is in-network ("Specific Doctor") on
 * BlueCHiP Direct 2300/4600, writes the same status for the 4 BlueCHiP for Medicare plans.
 * ASSUMPTION: the BCBSRI Medicare Advantage directory was not searched; this copies the
 * commercial BCBSRI network. insertImmediate on a Big Object replaces a row with the same key,
 * so the old default Out-of-Network rows for these plans are overwritten (no duplicates).
 *
 * Run once (Execute Anonymous):
 *   Database.executeBatch(new CopyMedicareNetwork(), 50);
 * Check Setup > Apex Jobs until Completed, then Setup > Debug Logs (search "CopyMedicareNetwork").
 */
public class CopyMedicareNetwork implements Database.Batchable<SObject>, Database.Stateful {

    static final String SOURCE_PLAN_ID = 'a01jV00000CNHinQAH'; // BlueCHiP Direct 2300/4600
    static final Map<Id, String> TARGETS = new Map<Id, String>{
        'a01jV00000CgJwzQAF' => 'BlueCHiP for Medicare Enhanced',
        'a01jV00000CgJx0QAF' => 'BlueCHiP for Medicare Extra',
        'a01jV00000CgJx1QAF' => 'BlueCHiP for Medicare Essential',
        'a01jV00000CgJx2QAF' => 'BlueCHiP for Medicare Core'
    };
    static final String SOURCE_TEXT =
        'Assumed from BCBSRI commercial network (BlueCHiP Direct); BCBSRI Medicare Advantage directory not searched.';

    // Error log, kept across batches (Database.Stateful) and printed in finish().
    Integer doctorsSeen = 0;
    Integer doctorsCopied = 0;
    Integer rowsWritten = 0;
    Integer errorCount = 0;
    List<String> errorLog = new List<String>();

    public Database.QueryLocator start(Database.BatchableContext bc) {
        return Database.getQueryLocator('SELECT Id FROM Doctor__c');
    }

    public void execute(Database.BatchableContext bc, List<Doctor__c> scope) {
        List<Doctor_Network_Status_Big__b> toWrite = new List<Doctor_Network_Status_Big__b>();
        for (Doctor__c d : scope) {
            doctorsSeen++;
            try {
                List<Doctor_Network_Status_Big__b> src = [
                    SELECT Doctor_Id__c, Doctor_Name__c, Network_Tier__c, Status__c
                    FROM Doctor_Network_Status_Big__b
                    WHERE Doctor_Id__c = :String.valueOf(d.Id) AND Plan_Id__c = :SOURCE_PLAN_ID
                    LIMIT 1
                ];
                if (src.isEmpty() || src[0].Network_Tier__c != 'Specific Doctor') {
                    continue;
                }
                for (Id planId : TARGETS.keySet()) {
                    toWrite.add(new Doctor_Network_Status_Big__b(
                        Doctor_Id__c = src[0].Doctor_Id__c,
                        Doctor_Name__c = src[0].Doctor_Name__c,
                        Plan_Id__c = String.valueOf(planId),
                        Plan_Name__c = TARGETS.get(planId),
                        Network_Tier__c = 'Specific Doctor',
                        Status__c = 'Active',
                        Source__c = SOURCE_TEXT
                    ));
                }
                doctorsCopied++;
            } catch (Exception e) {
                logError('Read failed for doctor ' + d.Id, e);
            }
        }
        if (!toWrite.isEmpty()) {
            try {
                Database.insertImmediate(toWrite);
                rowsWritten += toWrite.size();
            } catch (Exception e) {
                logError('Write failed for a batch of ' + toWrite.size() + ' rows (first doctor '
                    + toWrite[0].Doctor_Id__c + ')', e);
            }
        }
    }

    public void finish(Database.BatchableContext bc) {
        System.debug(LoggingLevel.INFO, 'CopyMedicareNetwork finished. Doctors seen=' + doctorsSeen
            + ', copied=' + doctorsCopied + ', rows written=' + rowsWritten + ', errors=' + errorCount);
        for (String line : errorLog) {
            System.debug(LoggingLevel.ERROR, 'CopyMedicareNetwork ERROR: ' + line);
        }
        if (errorCount > errorLog.size()) {
            System.debug(LoggingLevel.ERROR, 'CopyMedicareNetwork: ' + (errorCount - errorLog.size())
                + ' more errors not listed.');
        }
    }

    void logError(String context, Exception e) {
        errorCount++;
        String line = context + ' | ' + e.getTypeName() + ': ' + e.getMessage();
        System.debug(LoggingLevel.ERROR, 'CopyMedicareNetwork ERROR: ' + line);
        if (errorLog.size() < 100) { // cap so the stateful list stays small
            errorLog.add(line);
        }
    }
}
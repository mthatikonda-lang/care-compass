public without sharing class PatientPermissionAssigner {

    private static final String PERMISSION_SET_LABEL = 'Prompt Template User';

    @future
    public static void assign(Set<Id> userIds) {
        try {
            List<PermissionSet> ps = [
                SELECT Id FROM PermissionSet WHERE Label = :PERMISSION_SET_LABEL LIMIT 1
            ];
            if (ps.isEmpty()) {
                System.debug(LoggingLevel.WARN, 'Permission set not found: ' + PERMISSION_SET_LABEL);
                ErrorLogger.log('PatientPermissionAssigner.assign', 'Warning',
                    'Permission set not found: ' + PERMISSION_SET_LABEL, String.valueOf(userIds), null);
                return;
            }

            Set<Id> already = new Set<Id>();
            for (PermissionSetAssignment a : [
                SELECT AssigneeId FROM PermissionSetAssignment
                WHERE PermissionSetId = :ps[0].Id AND AssigneeId IN :userIds
            ]) {
                already.add(a.AssigneeId);
            }

            List<PermissionSetAssignment> toInsert = new List<PermissionSetAssignment>();
            for (Id uid : userIds) {
                if (!already.contains(uid)) {
                    toInsert.add(new PermissionSetAssignment(
                        AssigneeId = uid, PermissionSetId = ps[0].Id));
                }
            }
            if (!toInsert.isEmpty()) {
                insert toInsert;
            }
        } catch (Exception e) {
            System.debug(LoggingLevel.WARN, 'PatientPermissionAssigner failed: ' + e.getMessage());
            ErrorLogger.logException('PatientPermissionAssigner.assign', e, null);
        }
    }
}
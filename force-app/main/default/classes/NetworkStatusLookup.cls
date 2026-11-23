public with sharing class NetworkStatusLookup {

    public class Request {
        @InvocableVariable(label='Doctor Id' required=true)
        public String doctorId;
        @InvocableVariable(label='Insurance Plan Id' required=true)
        public String planId;
    }

    public class Result {
        @InvocableVariable(label='Record Found')
        public Boolean found;
        @InvocableVariable(label='Network Tier')
        public String networkTier;
        @InvocableVariable(label='Status')
        public String status;
    }

    @InvocableMethod(label='Get Doctor Network Status (Big Object)' description='Exact match on Doctor Id + Insurance Plan Id')
    public static List<Result> lookup(List<Request> requests) {
        List<Result> results = new List<Result>();
        for (Request req : requests) {
            Result res = new Result();
            res.found = false;
            if (String.isNotBlank(req.doctorId) && String.isNotBlank(req.planId)) {
                List<Doctor_Network_Status_Big__b> rows = [
                    SELECT Network_Tier__c, Status__c
                    FROM Doctor_Network_Status_Big__b
                    WHERE Doctor_Id__c = :req.doctorId AND Plan_Id__c = :req.planId
                    LIMIT 1
                ];
                if (!rows.isEmpty()) {
                    res.found = true;
                    res.networkTier = rows[0].Network_Tier__c;
                    res.status = rows[0].Status__c;
                }
            }
            results.add(res);
        }
        return results;
    }
}
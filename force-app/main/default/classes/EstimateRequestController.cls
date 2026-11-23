public without sharing class EstimateRequestController {

    public class ProviderOption {
        @AuraEnabled public String providerId;
        @AuraEnabled public String providerName;
    }

    public class DoctorOption {
        @AuraEnabled public String doctorId;
        @AuraEnabled public String doctorName;
        @AuraEnabled public String providerId;
    }

    public class EstimateResult {
        @AuraEnabled public Id appointmentId;
        @AuraEnabled public Decimal estimatedPatientCost;
        @AuraEnabled public Boolean inNetwork;
        @AuraEnabled public String providerName;
        @AuraEnabled public String doctorName;
        @AuraEnabled public String procedureType;
        @AuraEnabled public Decimal benchmarkCost;
        // NEW: the price actually fed to the estimate, and where it came from.
        @AuraEnabled public Decimal pricedAmount;
        @AuraEnabled public String priceSource;
        // True when the price is the doctor's fee only (billed in a hospital/facility setting).
        @AuraEnabled public Boolean feeOnly;
        // Set instead of a dollar estimate for dental plans / dentists.
        @AuraEnabled public String noEstimateMessage;
        // Extra caveat shown under the estimate (used for the rough dental estimate).
        @AuraEnabled public String extraNote;
        // True only when the cost depends on the deductible (Deductible + Coinsurance rule, in-network).
        @AuraEnabled public Boolean showDeductibleNote = false;
        // The patient's own plan name, shown on the estimate card next to the service.
        @AuraEnabled public String planName;
    }

    @AuraEnabled(cacheable=true)
    public static List<ProviderOption> getProviders() {
        List<ProviderOption> options = new List<ProviderOption>();
        for (Provider__c p : [SELECT Id, Provider_Name__c FROM Provider__c ORDER BY Provider_Name__c]) {
            ProviderOption o = new ProviderOption();
            o.providerId = p.Id;
            o.providerName = p.Provider_Name__c;
            options.add(o);
        }
        return options;
    }

    // Returns all doctors with their Provider Id so the LWC can filter
    // client-side once a provider is picked, instead of a second round trip.
    @AuraEnabled(cacheable=true)
    public static List<DoctorOption> getDoctors() {
        List<DoctorOption> options = new List<DoctorOption>();
        for (Doctor__c d : [SELECT Id, Name, Provider__c FROM Doctor__c ORDER BY Name]) {
            DoctorOption o = new DoctorOption();
            o.doctorId = d.Id;
            o.doctorName = d.Name;
            o.providerId = d.Provider__c;
            options.add(o);
        }
        return options;
    }

    // Looks up the typical/fair price for a procedure type rather than asking
    // the patient to guess a dollar amount. Tries a region-specific benchmark
    // first (matched against the provider's city), then falls back to any
    // benchmark with that name if no region match exists.
    private static Decimal getBenchmarkCost(String procedureType, String providerCity) {
        List<Price_Benchmark__c> regionMatches = [
            SELECT Average_Cost__c
            FROM Price_Benchmark__c
            WHERE Name = :procedureType AND Region__c = :providerCity
            LIMIT 1
        ];
        if (!regionMatches.isEmpty()) {
            return regionMatches[0].Average_Cost__c;
        }

        List<Price_Benchmark__c> anyMatches = [
            SELECT Average_Cost__c
            FROM Price_Benchmark__c
            WHERE Name = :procedureType
            LIMIT 1
        ];
        return anyMatches.isEmpty() ? null : anyMatches[0].Average_Cost__c;
    }

    // NEW: this doctor's own price row for the procedure type, from real CMS billing data
    // (Avg_Medicare_Allowed__c = what an in-network plan recognizes,
    //  Avg_Submitted_Charge__c = the doctor's own billed charge).
    // Returns null when the doctor has no Doctor_Price__c row for this procedure type,
    // so the caller can fall back to the generic benchmark.
    private static Doctor_Price__c getDoctorPriceRow(Id doctorId, String procedureType) {
        List<Doctor_Price__c> rows = [
            SELECT Avg_Submitted_Charge__c, Avg_Medicare_Allowed__c, Place_Of_Service__c
            FROM Doctor_Price__c
            WHERE Doctor__c = :doctorId AND Procedure_Type__c = :procedureType
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    @AuraEnabled
    public static EstimateResult requestEstimate(
        Id patientId,
        Id providerId,
        Id doctorId,
        String procedureType,
        Date appointmentDate
    ) {
        // This tool estimates medical visits only. For dental plans or dentists we skip the
        // price and the flow's cost math, but still create the appointment so the patient can
        // request the callback. The page shows the message instead of a dollar amount.
        String noEstimateMessage = null;
        String patientPlanName = null;
        Boolean dentalPlan = false;
        Id dentalPlanId = null;
        for (Patient__c pp : [SELECT Insurance_Plan__c, Insurance_Plan__r.Name, Insurance_Plan__r.Insurance_Carrier__c
                              FROM Patient__c WHERE Id = :patientId LIMIT 1]) {
            if (pp.Insurance_Plan__r != null) {
                patientPlanName = pp.Insurance_Plan__r.Name;
                String planText = ((pp.Insurance_Plan__r.Name == null ? '' : pp.Insurance_Plan__r.Name) + ' '
                    + (pp.Insurance_Plan__r.Insurance_Carrier__c == null ? '' : pp.Insurance_Plan__r.Insurance_Carrier__c)).toLowerCase();
                if (planText.contains('dental')) {
                    dentalPlan = true;
                    dentalPlanId = pp.Insurance_Plan__c;
                }
            }
        }

        // Dental plan: typical price for the dental procedure type, then the plan's own Coverage Rule
        // for that type (Covered in Full, plan pays X %, or not covered). Annual maximums,
        // deductibles and waiting periods are not modeled, so the page labels this a rough estimate.
        if (dentalPlan) {
            if (procedureType == null || !procedureType.startsWith('Dental')) {
                throw new AuraHandledException('Please choose a dental procedure type for your dental plan.');
            }
            Decimal dPrice = getBenchmarkCost(procedureType, null);
            if (dPrice == null) {
                throw new AuraHandledException('We don\'t have typical pricing on file for "' + procedureType + '" yet. Please choose a different procedure type or contact support.');
            }
            List<Coverage_Rule__c> dRules = [
                SELECT Cost_Sharing_Method__c, Coverage_Percentage__c, Excluded__c
                FROM Coverage_Rule__c
                WHERE Insurance_Plan__c = :dentalPlanId AND Coverage_Rule__c = :procedureType
                LIMIT 1
            ];
            // Network status from the same Big Object lookup the medical estimate uses.
            NetworkStatusLookup.Request dnreq = new NetworkStatusLookup.Request();
            dnreq.doctorId = String.valueOf(doctorId);
            dnreq.planId = String.valueOf(dentalPlanId);
            NetworkStatusLookup.Result dnres =
                NetworkStatusLookup.lookup(new List<NetworkStatusLookup.Request>{ dnreq })[0];
            Boolean dOutOfNetwork = dnres.found && dnres.networkTier == 'Out-of-Network';

            Decimal dCost = dPrice;
            if (dOutOfNetwork) {
                // Out-of-network: no plan benefit applied, the patient pays the full price.
                dCost = dPrice;
            } else if (!dRules.isEmpty()) {
                Coverage_Rule__c r = dRules[0];
                if (r.Excluded__c == true) {
                    dCost = dPrice;
                } else if (r.Cost_Sharing_Method__c == 'Covered in Full') {
                    dCost = 0;
                } else if (r.Coverage_Percentage__c != null) {
                    dCost = dPrice * (100 - r.Coverage_Percentage__c) / 100;
                }
            }

            Appointment__c da = new Appointment__c();
            da.Patient__c = patientId;
            da.Provider__c = providerId;
            da.Doctor__c = doctorId;
            da.Procedure_Type__c = procedureType;
            da.Appointment_Date__c = appointmentDate;
            da.Network_Found__c = dnres.found;
            da.Network_Tier_Result__c = dnres.networkTier;
            da.Estimated_Patient_Cost__c = dCost.setScale(2);
            insert da;

            Appointment__c ds = [
                SELECT Id, Estimated_Patient_Cost__c, Provider__r.Provider_Name__c, Doctor__r.Name, Procedure_Type__c
                FROM Appointment__c WHERE Id = :da.Id
            ];
            EstimateResult dr = new EstimateResult();
            dr.appointmentId = ds.Id;
            dr.estimatedPatientCost = ds.Estimated_Patient_Cost__c;
            dr.providerName = ds.Provider__r != null ? ds.Provider__r.Provider_Name__c : '';
            dr.doctorName = ds.Doctor__r != null ? ds.Doctor__r.Name : '';
            dr.procedureType = ds.Procedure_Type__c;
            if (dnres.found) {
                dr.inNetwork = !dOutOfNetwork;
            }
            dr.planName = patientPlanName;
            dr.pricedAmount = dPrice;
            dr.priceSource = 'Typical price for this procedure';
            dr.feeOnly = false;
            dr.extraNote = 'Rough dental estimate: your plan\'s share is applied to the price. Real dental coverage can vary by service type, annual maximum and waiting periods, so confirm with the office.';
            return dr;
        }

        if (noEstimateMessage == null) {
            for (Doctor__c dd : [SELECT Specialty__c FROM Doctor__c WHERE Id = :doctorId LIMIT 1]) {
                if (dd.Specialty__c != null && dd.Specialty__c.toLowerCase().contains('dent')) {
                    noEstimateMessage = 'Dental visits aren\'t estimated by this tool. Contact the office for pricing.';
                }
            }
        }
        if (noEstimateMessage != null) {
            Appointment__c dentalAppt = new Appointment__c();
            dentalAppt.Patient__c = patientId;
            dentalAppt.Provider__c = providerId;
            dentalAppt.Doctor__c = doctorId;
            dentalAppt.Procedure_Type__c = procedureType;
            dentalAppt.Appointment_Date__c = appointmentDate;
            insert dentalAppt;

            Appointment__c savedDental = [
                SELECT Id, Provider__r.Provider_Name__c, Doctor__r.Name, Procedure_Type__c
                FROM Appointment__c WHERE Id = :dentalAppt.Id
            ];
            EstimateResult dentalResult = new EstimateResult();
            dentalResult.appointmentId = savedDental.Id;
            dentalResult.providerName = savedDental.Provider__r != null ? savedDental.Provider__r.Provider_Name__c : '';
            dentalResult.doctorName = savedDental.Doctor__r != null ? savedDental.Doctor__r.Name : '';
            dentalResult.procedureType = savedDental.Procedure_Type__c;
            dentalResult.planName = patientPlanName;
            dentalResult.noEstimateMessage = noEstimateMessage;
            return dentalResult;
        }

        Provider__c provider = [SELECT Id, City__c FROM Provider__c WHERE Id = :providerId LIMIT 1];
        Decimal benchmarkCost = getBenchmarkCost(procedureType, provider.City__c);

        // Look up network status BEFORE the insert. Big Object queries can't
        // run while a save is pending, and the flow fires during the insert.
        Patient__c patient = [SELECT Id, Insurance_Plan__c FROM Patient__c WHERE Id = :patientId LIMIT 1];
        Boolean networkFound = false;
        String networkTier = null;
        if (patient.Insurance_Plan__c != null) {
            NetworkStatusLookup.Request nreq = new NetworkStatusLookup.Request();
            nreq.doctorId = String.valueOf(doctorId);
            nreq.planId = String.valueOf(patient.Insurance_Plan__c);
            NetworkStatusLookup.Result nres =
                NetworkStatusLookup.lookup(new List<NetworkStatusLookup.Request>{ nreq })[0];
            networkFound = nres.found;
            networkTier = nres.networkTier;
        }

        // NEW: choose the price. Out-of-network or unknown -> the doctor's billed charge;
        // in-network -> the Medicare-based allowed amount. No doctor row -> typical price.
        Boolean outOfNetwork = (networkTier == 'Out-of-Network');
        Doctor_Price__c priceRow = getDoctorPriceRow(doctorId, procedureType);
        Decimal pricedAmount = null;
        Boolean feeOnly = false;
        String priceSource;
        if (priceRow != null) {
            pricedAmount = outOfNetwork ? priceRow.Avg_Submitted_Charge__c : priceRow.Avg_Medicare_Allowed__c;
            feeOnly = (priceRow.Place_Of_Service__c == 'F');
        }
        if (pricedAmount != null) {
            priceSource = outOfNetwork
                ? 'This doctor\'s billed charge'
                : 'This doctor\'s allowed amount (Medicare-based)';
        } else {
            pricedAmount = benchmarkCost;
            priceSource = 'Typical price for this procedure';
            feeOnly = false;
        }

        if (pricedAmount == null) {
            throw new AuraHandledException('We don\'t have typical pricing on file for "' + procedureType + '" yet. Please choose a different procedure type or contact support.');
        }

        Appointment__c appt = new Appointment__c();
        appt.Patient__c = patientId;
        appt.Provider__c = providerId;
        appt.Doctor__c = doctorId;
        appt.Procedure_Type__c = procedureType;
        appt.Estimated_Billed_Amount__c = pricedAmount;
        appt.Appointment_Date__c = appointmentDate;
        appt.Network_Found__c = networkFound;
        appt.Network_Tier_Result__c = networkTier;
        insert appt;

        Appointment__c saved = [
            SELECT Id, Estimated_Patient_Cost__c, In_Network__c,
                   Provider__r.Provider_Name__c, Doctor__r.Name, Procedure_Type__c
            FROM Appointment__c
            WHERE Id = :appt.Id
        ];

        EstimateResult result = new EstimateResult();
        result.appointmentId = saved.Id;
        result.estimatedPatientCost = saved.Estimated_Patient_Cost__c;
        result.inNetwork = saved.In_Network__c;
        result.providerName = saved.Provider__r != null ? saved.Provider__r.Provider_Name__c : '';
        result.doctorName = saved.Doctor__r != null ? saved.Doctor__r.Name : '';
        result.procedureType = saved.Procedure_Type__c;
        result.planName = patientPlanName;
        result.benchmarkCost = benchmarkCost;
        result.pricedAmount = pricedAmount;
        result.priceSource = priceSource;
        result.feeOnly = feeOnly;

        // Show the "assumes deductible not met" note only when the plan rule for this
        // procedure is Deductible + Coinsurance and the visit is not out-of-network.
        if (!outOfNetwork && patient.Insurance_Plan__c != null) {
            List<Coverage_Rule__c> medRules = [
                SELECT Cost_Sharing_Method__c, Excluded__c
                FROM Coverage_Rule__c
                WHERE Insurance_Plan__c = :patient.Insurance_Plan__c AND Coverage_Rule__c = :procedureType
                LIMIT 1
            ];
            if (!medRules.isEmpty() && medRules[0].Excluded__c != true
                && medRules[0].Cost_Sharing_Method__c == 'Deductible + Coinsurance') {
                result.showDeductibleNote = true;
            }
        }
        return result;
    }
}
public without sharing class CareFinderController {

    public class DoctorSuggestion {
        @AuraEnabled public String doctorId;
        @AuraEnabled public String doctorName;
        @AuraEnabled public String providerId;
        @AuraEnabled public String providerName;
        @AuraEnabled public String specialty;
        @AuraEnabled public String city;
        @AuraEnabled public Boolean isSuggested;
        @AuraEnabled public Boolean matchesLocation;
        // Miles from the patient's ZIP code to this doctor's city (null when no ZIP was given).
        @AuraEnabled public Decimal distanceMiles;
        // Position of this doctor's specialty in the AI's answer (0 = most appropriate). Not sent to the page.
        public Integer aiRank = 99;
        @AuraEnabled public Decimal estimatedCost;
        @AuraEnabled public String networkStatus; // 'In-Network', 'Out-of-Network', or 'Unknown'
        // NEW: what the estimated cost is based on.
        @AuraEnabled public String procedureType;
        @AuraEnabled public String priceSource; // 'Doctor allowed amount', 'Doctor billed charge', 'Typical price'
        // True when the doctor's price covers the doctor's fee only (billed in a hospital/facility
        // setting), so facility charges are separate and not included.
        @AuraEnabled public Boolean feeOnly;
        // Typical total price for this procedure type, shown next to a fee-only price.
        @AuraEnabled public Decimal typicalCost;
        // True when the AI thinks the description may be an emergency; the UI shows a warning.
        @AuraEnabled public Boolean emergencyFlag;
        // True when the patient's plan is a dental plan (the page then offers dental procedure types).
        @AuraEnabled public Boolean dentalPlan;
        // Visit types this doctor has their own price for, and the one to preselect.
        @AuraEnabled public List<String> pricedTypes;
        @AuraEnabled public String defaultProcedureType;
    }

    public class BookingResult {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String message;
    }

    private static final Map<String, List<String>> SPECIALTY_KEYWORDS = new Map<String, List<String>>{
        'Family Medicine' => new List<String>{
            'cold', 'flu', 'fever', 'cough', 'checkup', 'check up', 'annual exam',
            'sore throat', 'general', 'tired', 'fatigue', 'headache', 'migraine',
            'stomach ache', 'stomachache', 'nausea', 'vomiting', 'diarrhea',
            'allergies', 'rash', 'sinus', 'congestion', 'ear ache', 'earache',
            'physical', 'wellness', 'vaccine', 'vaccination', 'shot'
        },
        'Orthopedics' => new List<String>{
            'knee', 'joint', 'bone', 'fracture', 'broken bone', 'sprain', 'strain',
            'shoulder', 'back pain', 'lower back', 'neck pain', 'hip', 'ankle',
            'hand', 'wrist', 'elbow', 'arm', 'leg pain', 'muscle pain', 'ligament',
            'tendon', 'swelling', 'stiffness', 'arthritis'
        },
        'Urgent Care' => new List<String>{
            'injury', 'cut', 'laceration', 'emergency', 'burn', 'accident',
            'sudden pain', 'bleeding', 'fell', 'fall', 'twisted', 'bite',
            'sting', 'choking', 'severe pain', 'cannot walk', 'can\'t walk'
        },
        'Radiology' => new List<String>{
            'scan', 'imaging', 'x-ray', 'xray', 'mri', 'ct scan', 'ultrasound',
            'need a scan', 'follow up scan', 'follow-up imaging'
        },
        'Laboratory Medicine' => new List<String>{
            'blood test', 'lab work', 'labwork', 'cholesterol', 'bloodwork',
            'blood draw', 'urine test', 'panel', 'screening test', 'a1c'
        }
    };

    // Concern rules: if the patient's text contains any trigger word, doctors whose specialty
    // contains any stem match. Stems are partial on purpose ('orthop' fits Orthopedics and
    // Orthopedic Surgery), so this works without knowing the exact Specialty__c spellings.
    private class ConcernRule {
        List<String> triggers;
        List<String> stems;
        ConcernRule(List<String> triggers, List<String> stems) {
            this.triggers = triggers;
            this.stems = stems;
        }
    }

    private static final List<ConcernRule> CONCERN_RULES = new List<ConcernRule>{
        new ConcernRule(
            new List<String>{ 'knee', 'meniscus', 'acl', 'joint', 'bone', 'fracture', 'sprain', 'strain',
                'shoulder', 'back', 'neck', 'spine', 'sciatica', 'hip', 'ankle', 'wrist', 'elbow',
                'leg', 'muscle', 'ligament', 'tendon', 'stairs', 'limp', 'walking', 'sports' },
            new List<String>{ 'orthop', 'sports', 'physical', 'physiatr', 'rehab', 'chiropract', 'spine' }),
        new ConcernRule(
            new List<String>{ 'arthritis', 'gout', 'lupus', 'joint swelling', 'stiff', 'autoimmune' },
            new List<String>{ 'rheumat' }),
        new ConcernRule(
            new List<String>{ 'foot', 'feet', 'heel', 'toe', 'toenail', 'bunion', 'plantar' },
            new List<String>{ 'podiat', 'orthop' }),
        new ConcernRule(
            new List<String>{ 'skin', 'rash', 'acne', 'eczema', 'mole', 'itch', 'psoriasis', 'hives', 'wart', 'hair loss' },
            new List<String>{ 'dermat' }),
        new ConcernRule(
            new List<String>{ 'chest', 'heart', 'palpitation', 'blood pressure', 'hypertension', 'cholesterol', 'dizzy' },
            new List<String>{ 'cardio' }),
        new ConcernRule(
            new List<String>{ 'stomach', 'belly', 'abdomen', 'abdominal', 'acid reflux', 'heartburn', 'constipation',
                'diarrhea', 'colon', 'bowel', 'liver', 'gallbladder', 'nausea', 'vomit',
                'gut', 'digest', 'indigestion', 'bloat', 'gas', 'ibs', 'gerd', 'reflux', 'ulcer',
                'stool', 'intestin', 'crohn', 'colitis', 'motion', 'loose' },
            new List<String>{ 'gastro', 'internal' }),
        new ConcernRule(
            new List<String>{ 'eye', 'vision', 'blurry', 'glasses', 'cataract', 'glaucoma' },
            new List<String>{ 'ophthal', 'optom' }),
        new ConcernRule(
            new List<String>{ 'ear', 'hearing', 'nose', 'throat', 'sinus', 'tonsil', 'snoring', 'voice' },
            new List<String>{ 'otolaryng', 'ear nose', 'ent', 'audiolog' }),
        new ConcernRule(
            new List<String>{ 'headache', 'migraine', 'seizure', 'numb', 'tingling', 'memory', 'tremor', 'stroke', 'nerve' },
            new List<String>{ 'neuro' }),
        new ConcernRule(
            new List<String>{ 'anxiety', 'depress', 'stress', 'panic', 'sleep', 'mood', 'mental', 'therapy', 'adhd' },
            new List<String>{ 'psych', 'mental', 'behavior', 'counsel' }),
        new ConcernRule(
            new List<String>{ 'pregnan', 'period', 'menstrual', 'pelvic', 'menopause', 'pap', 'gynec', 'birth control' },
            new List<String>{ 'obstet', 'gynec', 'ob/gyn', 'ob-gyn', 'women' }),
        new ConcernRule(
            new List<String>{ 'urine', 'urinary', 'bladder', 'kidney stone', 'prostate' },
            new List<String>{ 'urolog', 'nephro' }),
        new ConcernRule(
            new List<String>{ 'breath', 'asthma', 'lung', 'cough', 'wheez' },
            new List<String>{ 'pulmon', 'respir' }),
        new ConcernRule(
            new List<String>{ 'diabetes', 'thyroid', 'hormone', 'weight', 'sugar' },
            new List<String>{ 'endocrin', 'diabet' }),
        new ConcernRule(
            new List<String>{ 'child', 'kid', 'baby', 'infant', 'toddler', 'son', 'daughter' },
            new List<String>{ 'pediatr' }),
        new ConcernRule(
            new List<String>{ 'cancer', 'tumor', 'lump', 'chemo' },
            new List<String>{ 'oncolog', 'hematolog' }),
        new ConcernRule(
            new List<String>{ 'tooth', 'teeth', 'gum', 'dental', 'cavity', 'jaw' },
            new List<String>{ 'dentist', 'dental', 'oral surg' })
    };

    // Lower-case, punctuation -> spaces, padded with spaces, so words can be matched whole.
    private static String normalize(String text) {
        return ' ' + (text == null ? '' : text.toLowerCase().replaceAll('[^a-z0-9]+', ' ')).trim() + ' ';
    }

    // Short triggers (<= 4 letters) must match a whole word ("ear" must not match "clearly");
    // longer ones match at the start of a word ("pregnan" matches "pregnancy").
    private static Boolean textHasTrigger(String normIssue, String triggerWord) {
        String t = normalize(triggerWord).trim();
        if (t.length() <= 4) {
            return normIssue.contains(' ' + t + ' ') || normIssue.contains(' ' + t + 's ');
        }
        return normIssue.contains(' ' + t);
    }

    // Work out once per search which concern rules the patient's text triggers.
    private static List<ConcernRule> activeRulesFor(String lowerIssue) {
        List<ConcernRule> active = new List<ConcernRule>();
        if (String.isBlank(lowerIssue)) return active;
        String normIssue = normalize(lowerIssue);
        for (ConcernRule r : CONCERN_RULES) {
            for (String t : r.triggers) {
                if (textHasTrigger(normIssue, t)) {
                    active.add(r);
                    break;
                }
            }
        }
        return active;
    }

    // A stem must match the START of a word in the specialty name, so "ent" can't match
    // "Dentistry" or "Urgent" and "urolog" can't match "Neurology".
    private static Boolean matchesConcern(List<ConcernRule> activeRules, String specialty) {
        if (activeRules.isEmpty() || String.isBlank(specialty)) return false;
        String normSpec = normalize(specialty);
        for (ConcernRule r : activeRules) {
            for (String stem : r.stems) {
                if (normSpec.contains(' ' + normalize(stem).trim())) return true;
            }
        }
        return false;
    }

    private static Boolean looksLikeEmergency(String lowerIssue) {
        for (String w : new List<String>{ 'chest pain', 'trouble breathing', 'cannot breathe', 'can\'t breathe',
                'shortness of breath', 'stroke', 'severe bleeding', 'unconscious', 'overdose', 'suicid',
                'heart attack', 'seizure', 'drooping', 'slurred', 'can\'t speak', 'cannot speak',
                'trouble speaking', 'face is numb', 'arm is numb', 'left arm', 'passed out', 'fainted',
                'coughing blood', 'vomiting blood', 'want to die', 'kill myself', 'end my life' }) {
            if (lowerIssue.contains(w)) return true;
        }
        return false;
    }

    // NEW: which Doctor_Price__c procedure type represents a typical visit to this kind of doctor.
    private static String procedureTypeFor(String specialty) {
        if (specialty == 'Family Medicine' || specialty == 'Urgent Care') {
            return 'Office Visit';
        }
        if (specialty == 'Radiology') {
            return 'Imaging';
        }
        if (specialty == 'Laboratory Medicine') {
            return 'Lab Test';
        }
        return 'Specialist Visit';
    }

    // True when the emergency check, a concern rule or an old keyword understands the text.
    private static Boolean localRecognized(String lowerIssue) {
        if (looksLikeEmergency(lowerIssue) || !activeRulesFor(lowerIssue).isEmpty()) return true;
        String normIssue = normalize(lowerIssue);
        for (List<String> words : SPECIALTY_KEYWORDS.values()) {
            for (String kw : words) {
                if (textHasTrigger(normIssue, kw)) return true;
            }
        }
        return false;
    }

    // Not cacheable: it calls the Prompt Builder (Einstein) template, which can't run from a cacheable method.
    // Used by the WhatsApp router (city text, no distance).
    @AuraEnabled
    public static List<DoctorSuggestion> getSuggestedDoctors(String issueText, String preferredCity) {
        try {
            return findDoctors(issueText, preferredCity, null, null);
        } catch (CareFinderException e) {
            throw toAura(e);
        }
    }

    // BUG-11: used by the web page. Optional city (preferredCity: matching doctors are listed first)
    // and optional ZIP code plus a distance range in miles (null or 0 = any distance), which
    // decides who is shown. Either or both can be given.
    @AuraEnabled
    public static List<DoctorSuggestion> getSuggestedDoctorsNear(String issueText, String preferredCity, String zipCode, Decimal miles) {
        try {
            return findDoctors(issueText, preferredCity, zipCode, miles);
        } catch (CareFinderException e) {
            throw toAura(e);
        }
    }

    // Cities that have at least one doctor, for the "Preferred area" drop-down on the page.
    @AuraEnabled(cacheable=true)
    public static List<String> getDoctorCities() {
        Set<String> cities = new Set<String>();
        for (Doctor__c d : [
            SELECT Provider__r.City__c FROM Doctor__c WHERE Provider__r.City__c != null LIMIT 50000
        ]) {
            String c = d.Provider__r.City__c.trim();
            if (c != '') {
                cities.add(c);
            }
        }
        List<String> sorted = new List<String>(cities);
        sorted.sort();
        return sorted;
    }

    // Set only while getSuggestedDoctorsForPatient runs, so WhatsApp (which runs as the
    // Automated Process user, not the patient) gets the same plan-based results as the portal.
    private static Id patientOverride;

    public static List<DoctorSuggestion> getSuggestedDoctorsForPatient(String issueText, String zipCode, Id patientId) {
        patientOverride = patientId;
        try {
            return findDoctors(issueText, null, zipCode, null);
        } finally {
            patientOverride = null;
        }
    }

    // Thrown by fail(). A normal exception, so WhatsApp (not an Aura context) can catch it.
    // AuraHandledException can only be thrown from Aura/Visualforce; elsewhere it becomes an
    // uncatchable LimitException.
    public class CareFinderException extends Exception {}

    private static void fail(String message) {
        throw new CareFinderException(message);
    }

    // For the web page only: turn our exception into the Aura one the page understands.
    private static AuraHandledException toAura(CareFinderException e) {
        AuraHandledException ex = new AuraHandledException(e.getMessage());
        ex.setMessage(e.getMessage());
        return ex;
    }

    // Straight-line distance in miles between two latitude/longitude points.
    @TestVisible
    private static Decimal milesBetween(Decimal lat1, Decimal lon1, Decimal lat2, Decimal lon2) {
        Double r = 3958.8;
        Double dLat = (lat2 - lat1).doubleValue() * Math.PI / 180;
        Double dLon = (lon2 - lon1).doubleValue() * Math.PI / 180;
        Double a = Math.sin(dLat / 2) * Math.sin(dLat / 2)
            + Math.cos(lat1.doubleValue() * Math.PI / 180) * Math.cos(lat2.doubleValue() * Math.PI / 180)
            * Math.sin(dLon / 2) * Math.sin(dLon / 2);
        Double d = 2 * r * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
        return Decimal.valueOf(d).setScale(1);
    }

    private static List<DoctorSuggestion> findDoctors(String issueText, String preferredCity, String zipCode, Decimal miles) {
        String lowerIssue = issueText == null ? '' : issueText.toLowerCase();
        // Keep only the city part ("Lincoln, RI" -> "lincoln") and match it as a whole name.
        String lowerCity = preferredCity == null ? '' : preferredCity.split(',')[0].trim().toLowerCase();

        // BUG-11: ZIP code -> coordinates, and each Rhode Island city's coordinates (the average
        // of its ZIP codes), so a doctor's distance can be worked out from the doctor's city.
        Boolean zipMode = String.isNotBlank(zipCode);
        Boolean rangeOn = zipMode && miles != null && miles > 0;
        Decimal zipLat = null;
        Decimal zipLon = null;
        Map<String, List<Decimal>> cityCoords = new Map<String, List<Decimal>>();
        if (zipMode) {
            String z = zipCode.trim();
            if (!Pattern.matches('\\d{5}', z)) {
                fail('Please enter a 5-digit ZIP code.');
            }
            // Zip_Location__b is a Big Object: filter only on its index field (Zip_Code__c).
            for (Zip_Location__b zl : [
                SELECT Latitude__c, Longitude__c FROM Zip_Location__b WHERE Zip_Code__c = :z
            ]) {
                zipLat = zl.Latitude__c;
                zipLon = zl.Longitude__c;
            }
            if (zipLat == null) {
                fail('We couldn\'t find that ZIP code. Please check it and try again (Rhode Island, Massachusetts and Connecticut ZIP codes are supported).');
            }
            // Big Objects have no AVG or GROUP BY, so average each Rhode Island city's ZIP
            // coordinates here. Rhode Island ZIP codes run 02800 to 02999.
            Map<String, List<Decimal>> sums = new Map<String, List<Decimal>>();
            for (Zip_Location__b zl : [
                SELECT City__c, State__c, Latitude__c, Longitude__c FROM Zip_Location__b
                WHERE Zip_Code__c >= '02800' AND Zip_Code__c <= '02999'
                LIMIT 2000
            ]) {
                if (zl.State__c != 'RI' || zl.City__c == null) continue;
                String key = zl.City__c.toLowerCase();
                if (!sums.containsKey(key)) {
                    sums.put(key, new List<Decimal>{ 0, 0, 0 });
                }
                List<Decimal> s = sums.get(key);
                s[0] += zl.Latitude__c;
                s[1] += zl.Longitude__c;
                s[2] += 1;
            }
            for (String key : sums.keySet()) {
                List<Decimal> s = sums.get(key);
                cityCoords.put(key, new List<Decimal>{ s[0] / s[2], s[1] / s[2] });
            }
        }
        Boolean emergency = looksLikeEmergency(lowerIssue);
        List<ConcernRule> activeRules = activeRulesFor(lowerIssue);
        String normIssue = normalize(lowerIssue);

        // Ask the Prompt Builder template which of our real specialties fit. If it is
        // unavailable or fails, the concern rules and keywords below still work.
        List<String> allSpecialties = new List<String>();
        for (AggregateResult ar : [
            SELECT Specialty__c s FROM Doctor__c WHERE Specialty__c != null GROUP BY Specialty__c
        ]) {
            allSpecialties.add((String) ar.get('s'));
        }
        SpecialtyAiMatcher.Result ai = SpecialtyAiMatcher.match(issueText, allSpecialties);
        Set<String> aiSpecialties = new Set<String>(ai.specialties);
        if (ai.emergency) {
            emergency = true;
        }

        // BUG-09: if the text is not a medical concern at all, return nothing so the page can
        // ask the patient to re-enter it. "Recognized" means the AI, a concern rule, an old
        // keyword, or the emergency check understood something in the text.
        Boolean recognized = emergency || !aiSpecialties.isEmpty() || localRecognized(lowerIssue);
        if (!recognized) {
            return new List<DoctorSuggestion>();
        }

        String currentUserId = UserInfo.getUserId();
        Id patientPlanId = null;
        List<Patient__c> planPatients = patientOverride != null
            ? [SELECT Insurance_Plan__c FROM Patient__c WHERE Id = :patientOverride LIMIT 1]
            : [SELECT Insurance_Plan__c FROM Patient__c WHERE Related_User__c = :currentUserId LIMIT 1];
        for (Patient__c p : planPatients) {
            patientPlanId = p.Insurance_Plan__c;
        }

        // A dental plan only works with dental doctors, so those patients see only dentists.
        Boolean dentalPlan = false;
        if (patientPlanId != null) {
            for (Insurance_Plan__c ip : [
                SELECT Name, Insurance_Carrier__c FROM Insurance_Plan__c WHERE Id = :patientPlanId LIMIT 1
            ]) {
                String planText = ((ip.Name == null ? '' : ip.Name) + ' '
                    + (ip.Insurance_Carrier__c == null ? '' : ip.Insurance_Carrier__c)).toLowerCase();
                dentalPlan = planText.contains('dental');
            }
        }

        // Doctor -> network tier for THIS patient's plan, read from the Big Object.
        // Big Objects can only be filtered on their index fields in order (Doctor_Id__c first),
        // so pull rows with a range filter on Doctor_Id__c and match the plan in Apex.
        Map<Id, String> doctorNetworkTier = new Map<Id, String>();
        if (patientPlanId != null) {
            String planIdStr = String.valueOf(patientPlanId);
            for (Doctor_Network_Status_Big__b b : [
                SELECT Doctor_Id__c, Plan_Id__c, Network_Tier__c, Status__c
                FROM Doctor_Network_Status_Big__b
                WHERE Doctor_Id__c >= 'a06'
                LIMIT 50000
            ]) {
                if (b.Plan_Id__c == planIdStr && b.Status__c == 'Active') {
                    doctorNetworkTier.put((Id) b.Doctor_Id__c, b.Network_Tier__c);
                }
            }
        }

        // NEW: every doctor's own prices, keyed doctor -> procedure type.
        Map<Id, Map<String, Doctor_Price__c>> pricesByDoctor = new Map<Id, Map<String, Doctor_Price__c>>();
        for (Doctor_Price__c dp : [
            SELECT Doctor__c, Procedure_Type__c, Avg_Submitted_Charge__c, Avg_Medicare_Allowed__c,
                   Place_Of_Service__c
            FROM Doctor_Price__c
        ]) {
            if (!pricesByDoctor.containsKey(dp.Doctor__c)) {
                pricesByDoctor.put(dp.Doctor__c, new Map<String, Doctor_Price__c>());
            }
            pricesByDoctor.get(dp.Doctor__c).put(dp.Procedure_Type__c, dp);
        }

        // NEW: typical price per procedure type, used when a doctor has no price of their own.
        Map<String, Decimal> benchmarkByType = new Map<String, Decimal>();
        for (Price_Benchmark__c pb : [
            SELECT Name, Average_Cost__c FROM Price_Benchmark__c
        ]) {
            if (!benchmarkByType.containsKey(pb.Name)) {
                benchmarkByType.put(pb.Name, pb.Average_Cost__c);
            }
        }

        Map<String, Decimal> cityBenchmarkCost = new Map<String, Decimal>();
        for (Price_Benchmark__c pb : [
            SELECT Region__c, Average_Cost__c
            FROM Price_Benchmark__c
            WHERE Name = 'Office Visit'
        ]) {
            if (pb.Region__c != null) {
                cityBenchmarkCost.put(pb.Region__c, pb.Average_Cost__c);
            }
        }
        Decimal fallbackCost = null;
        for (Decimal cost : cityBenchmarkCost.values()) {
            if (fallbackCost == null || cost < fallbackCost) {
                fallbackCost = cost;
            }
        }

        // Doctors whose specialty is named by a concern rule (e.g. "cancer" -> Oncology) are
        // listed before doctors the AI or an old keyword added (e.g. Radiology).
        List<DoctorSuggestion> primaryAndLocation = new List<DoctorSuggestion>();
        List<DoctorSuggestion> primaryOnly = new List<DoctorSuggestion>();
        List<DoctorSuggestion> specialtyAndLocation = new List<DoctorSuggestion>();
        List<DoctorSuggestion> specialtyOnly = new List<DoctorSuggestion>();
        List<DoctorSuggestion> others = new List<DoctorSuggestion>();

        Boolean cityKnown = false;
        for (Doctor__c d : [
            SELECT Id, Name, Specialty__c, Provider__c,
                   Provider__r.Provider_Name__c, Provider__r.City__c
            FROM Doctor__c
            ORDER BY Name
        ]) {
            // BUG-24: remember whether any doctor is in the city the patient typed.
            if (String.isNotBlank(lowerCity) && d.Provider__r != null && d.Provider__r.City__c != null
                && d.Provider__r.City__c.trim().toLowerCase() == lowerCity) {
                cityKnown = true;
            }
            Boolean isDentistDoc = d.Specialty__c != null && d.Specialty__c.toLowerCase().contains('dent');
            // Dental plans see only dentists; everyone else never sees dentists.
            if (dentalPlan != isDentistDoc) {
                continue;
            }
            DoctorSuggestion ds = new DoctorSuggestion();
            ds.doctorId = d.Id;
            ds.doctorName = d.Name;
            ds.providerId = d.Provider__c;
            ds.providerName = d.Provider__r != null ? d.Provider__r.Provider_Name__c : '';
            ds.specialty = d.Specialty__c;
            ds.city = d.Provider__r != null ? d.Provider__r.City__c : '';

            if (patientPlanId == null) {
                ds.networkStatus = 'Unknown';
            } else if (doctorNetworkTier.containsKey(d.Id)) {
                ds.networkStatus = (doctorNetworkTier.get(d.Id) == 'Out-of-Network')
                    ? 'Out-of-Network' : 'In-Network';
            } else {
                ds.networkStatus = 'Out-of-Network';
            }

            // NEW: price from this doctor's own CMS-based row when there is one.
            //   In-network or unknown -> Medicare-based allowed amount
            //   Out-of-network        -> the doctor's billed charge
            // Otherwise the typical price for the procedure type, then the old city fallback.
            // Use the visit type this doctor actually has a price for. Primary-care doctors have an
            // Office Visit row, specialists a Specialist Visit row, so this doesn't depend on the exact
            // specialty wording. Falls back to the specialty-based guess when they have neither.
            // Dental prices and procedure types apply only to patients on a dental plan.
            Boolean isDentist = dentalPlan;
            ds.dentalPlan = dentalPlan;
            String procType = isDentist ? 'Dental Exam' : procedureTypeFor(d.Specialty__c);
            // Dentists have no CMS price rows (Medicare doesn't cover dental), so they use typical dental prices.
            Map<String, Doctor_Price__c> ownPrices = isDentist ? null : pricesByDoctor.get(d.Id);
            if (ownPrices != null) {
                for (String candidate : new List<String>{ 'Office Visit', 'Specialist Visit', 'Imaging', 'Lab Test' }) {
                    if (ownPrices.containsKey(candidate)) {
                        procType = candidate;
                        break;
                    }
                }
            }
            ds.pricedTypes = ownPrices != null ? new List<String>(ownPrices.keySet()) : new List<String>();
            ds.defaultProcedureType = procType;
            Boolean outOfNetwork = (ds.networkStatus == 'Out-of-Network');
            Decimal price = null;
            Map<String, Doctor_Price__c> byType = isDentist ? null : pricesByDoctor.get(d.Id);
            if (byType != null && byType.containsKey(procType)) {
                Doctor_Price__c dp = byType.get(procType);
                price = outOfNetwork ? dp.Avg_Submitted_Charge__c : dp.Avg_Medicare_Allowed__c;
                ds.priceSource = outOfNetwork ? 'Doctor billed charge' : 'Doctor allowed amount';
                ds.feeOnly = (dp.Place_Of_Service__c == 'F');
            }
            ds.typicalCost = benchmarkByType.get(procType);
            if (price == null) {
                price = benchmarkByType.get(procType);
                ds.priceSource = 'Typical price';
                ds.feeOnly = false;
            }
            if (price == null) {
                price = (ds.city != null && cityBenchmarkCost.containsKey(ds.city))
                    ? cityBenchmarkCost.get(ds.city)
                    : fallbackCost;
            }
            ds.estimatedCost = price;
            ds.procedureType = procType;

            ds.emergencyFlag = emergency;
            // A doctor matches if a concern rule fits their specialty OR an old keyword hits.
            Boolean specialtyMatch = aiSpecialties.contains(d.Specialty__c)
                || matchesConcern(activeRules, d.Specialty__c);
            if (!specialtyMatch && SPECIALTY_KEYWORDS.containsKey(d.Specialty__c)) {
                for (String keyword : SPECIALTY_KEYWORDS.get(d.Specialty__c)) {
                    if (textHasTrigger(normIssue, keyword)) {
                        specialtyMatch = true;
                        break;
                    }
                }
            }
            Boolean locationMatch = String.isNotBlank(lowerCity) && ds.city != null
                && ds.city.trim().toLowerCase() == lowerCity;
            if (zipMode) {
                ds.distanceMiles = null;
                if (ds.city != null && cityCoords.containsKey(ds.city.trim().toLowerCase())) {
                    List<Decimal> cc = cityCoords.get(ds.city.trim().toLowerCase());
                    ds.distanceMiles = milesBetween(zipLat, zipLon, cc[0], cc[1]);
                }
                if (rangeOn && (ds.distanceMiles == null || ds.distanceMiles > miles)) {
                    continue; // outside the chosen distance range
                }
                // If a city was also given, doctors in that city go first. Otherwise, with a range
                // chosen everyone left is in range; with "any distance", "near" means 10 miles.
                if (String.isBlank(lowerCity)) {
                    locationMatch = rangeOn || (ds.distanceMiles != null && ds.distanceMiles <= 10);
                }
            }

            Integer rankIdx = ai.specialties.indexOf(d.Specialty__c);
            ds.aiRank = rankIdx >= 0 ? rankIdx : 99;
            ds.isSuggested = specialtyMatch;
            ds.matchesLocation = locationMatch;

            Boolean primaryMatch = matchesConcern(activeRules, d.Specialty__c);
            if (specialtyMatch && primaryMatch && locationMatch) {
                primaryAndLocation.add(ds);
            } else if (specialtyMatch && primaryMatch) {
                primaryOnly.add(ds);
            } else if (specialtyMatch && locationMatch) {
                specialtyAndLocation.add(ds);
            } else if (specialtyMatch) {
                specialtyOnly.add(ds);
            } else {
                others.add(ds);
            }
        }

        if (String.isNotBlank(lowerCity) && !cityKnown) {
            fail('We don\'t have doctors in "' + preferredCity.split(',')[0].trim()
                + '". Please check the spelling, or clear the city to see all matches.');
        }

        sortSuggestions(primaryAndLocation, zipMode);
        sortSuggestions(primaryOnly, zipMode);
        sortSuggestions(specialtyAndLocation, zipMode);
        sortSuggestions(specialtyOnly, zipMode);
        sortSuggestions(others, zipMode);

        primaryAndLocation.addAll(primaryOnly);
        primaryAndLocation.addAll(specialtyAndLocation);
        primaryAndLocation.addAll(specialtyOnly);
        specialtyAndLocation = primaryAndLocation;
        // Only show doctors whose specialty fits the issue. If the text was understood but no
        // doctor has that specialty, return nothing instead of listing unrelated specialties
        // (BUG-24). Text that was not understood at all returns an empty list above (BUG-09).
        if (!specialtyAndLocation.isEmpty()) {
            return specialtyAndLocation;
        }
        if (rangeOn) {
            fail('No matching doctors within ' + miles.intValue() + ' miles of ' + zipCode.trim()
                + '. Try a larger distance.');
        }
        return new List<DoctorSuggestion>();
    }

    // With a ZIP code the nearest doctor goes first (price breaks ties); otherwise cheapest first.
    // The AI's own order comes first (most appropriate specialty first); distance or price only
    // orders doctors within the same rank.
    private static void sortSuggestions(List<DoctorSuggestion> suggestions, Boolean byDistance) {
        for (Integer i = 1; i < suggestions.size(); i++) {
            DoctorSuggestion current = suggestions[i];
            Integer j = i - 1;
            while (j >= 0 && ranksBefore(current, suggestions[j], byDistance)) {
                suggestions[j + 1] = suggestions[j];
                j--;
            }
            suggestions[j + 1] = current;
        }
    }

    private static Boolean ranksBefore(DoctorSuggestion a, DoctorSuggestion b, Boolean byDistance) {
        if (a.aiRank != b.aiRank) return a.aiRank < b.aiRank;
        return byDistance ? isNearer(a, b) : isCheaper(a, b);
    }

    private static Boolean isNearer(DoctorSuggestion a, DoctorSuggestion b) {
        if (a.distanceMiles == null && b.distanceMiles == null) return isCheaper(a, b);
        if (a.distanceMiles == null) return false;
        if (b.distanceMiles == null) return true;
        if (a.distanceMiles == b.distanceMiles) return isCheaper(a, b);
        return a.distanceMiles < b.distanceMiles;
    }

    private static void sortByEstimatedCost(List<DoctorSuggestion> suggestions) {
        for (Integer i = 1; i < suggestions.size(); i++) {
            DoctorSuggestion current = suggestions[i];
            Integer j = i - 1;
            while (j >= 0 && isCheaper(current, suggestions[j])) {
                suggestions[j + 1] = suggestions[j];
                j--;
            }
            suggestions[j + 1] = current;
        }
    }

    private static Boolean isCheaper(DoctorSuggestion a, DoctorSuggestion b) {
        if (a.estimatedCost == null) return false;
        if (b.estimatedCost == null) return true;
        return a.estimatedCost < b.estimatedCost;
    }

    // Used by the web page (passes what the patient typed).
    @AuraEnabled
    public static BookingResult confirmBookingWithIssue(Id appointmentId, String issueText) {
        return doConfirm(appointmentId, issueText);
    }

    // Used by the WhatsApp router (unchanged signature).
    @AuraEnabled
    public static BookingResult confirmBooking(Id appointmentId) {
        return doConfirm(appointmentId, null);
    }

    // Email the patient that their callback request was sent to the provider.
    // Contains no health details: only the office, doctor, visit type and requested date.
    private static void sendPatientConfirmation(Appointment__c appt, String patientName) {
        try {
            String patientEmail = (appt.Patient__r != null) ? appt.Patient__r.Email__c : null;
            System.debug(LoggingLevel.ERROR, 'PATIENT_EMAIL start: appt=' + appt.Id + ' to=' + patientEmail);
            if (String.isBlank(patientEmail)) {
                System.debug(LoggingLevel.ERROR, 'PATIENT_EMAIL skipped: patient has no email on file');
                ErrorLogger.log('CareFinderController.sendPatientConfirmation', 'Warning',
                    'PATIENT_EMAIL skipped: patient has no email on file',
                    'appt=' + appt.Id, String.valueOf(appt.Id));
                return;
            }
            String firstName = (appt.Patient__r != null && String.isNotBlank(appt.Patient__r.First_Name__c))
                ? appt.Patient__r.First_Name__c : 'there';
            String office = (appt.Provider__r != null && String.isNotBlank(appt.Provider__r.Provider_Name__c))
                ? appt.Provider__r.Provider_Name__c : 'the office';
            Messaging.SingleEmailMessage mail = new Messaging.SingleEmailMessage();
            mail.setToAddresses(new String[]{ patientEmail });
            mail.setSubject('Your callback request was sent to ' + office);
            mail.setPlainTextBody(
                'Hi ' + firstName + ',\n\n' +
                'Thank you for submitting your request. We have sent your callback request to ' + office + '.\n\n' +
                'Doctor: ' + (appt.Doctor__c != null ? appt.Doctor__r.Name : 'No preference specified') + '\n' +
                'Visit type: ' + appt.Procedure_Type__c + '\n' +
                'Requested date: ' + (appt.Appointment_Date__c != null ? appt.Appointment_Date__c.format() : 'Not specified') + '\n\n' +
                'This is a request, not a confirmed appointment. No time slot has been booked. ' +
                'The office will call you to confirm a time, so please also confirm your appointment with the doctor\'s office.\n\n' +
                'Care Compass'
            );
            mail.setSaveAsActivity(false);
            List<OrgWideEmailAddress> owa = [
                SELECT Id FROM OrgWideEmailAddress WHERE Address = 'thatmanu602@gmail.com' LIMIT 1
            ];
            if (!owa.isEmpty()) {
                mail.setOrgWideEmailAddressId(owa[0].Id);
            }
            System.debug(LoggingLevel.ERROR, 'PATIENT_EMAIL orgWide=' + (owa.isEmpty() ? 'NOT FOUND (sending as ' + UserInfo.getUserEmail() + ')' : 'found'));
            Messaging.SendEmailResult[] res = Messaging.sendEmail(new Messaging.SingleEmailMessage[]{ mail }, false);
            for (Messaging.SendEmailResult sr : res) {
                System.debug(LoggingLevel.ERROR, 'PATIENT_EMAIL success=' + sr.isSuccess());
                ErrorLogger.log('CareFinderController.sendPatientConfirmation', 'Warning',
                    'PATIENT_EMAIL result: success=' + sr.isSuccess() + ' to=' + patientEmail
                        + ' orgWide=' + (owa.isEmpty() ? 'NOT FOUND' : 'found'),
                    'appt=' + appt.Id, String.valueOf(appt.Id));
                if (!sr.isSuccess()) {
                    for (Messaging.SendEmailError err : sr.getErrors()) {
                        System.debug(LoggingLevel.ERROR, 'PATIENT_EMAIL error=' + err.getStatusCode() + ' ' + err.getMessage());
                        ErrorLogger.log('CareFinderController.sendPatientConfirmation', 'Warning',
                            'Patient confirmation email failed: ' + err.getStatusCode() + ' ' + err.getMessage(),
                            'appt=' + appt.Id, String.valueOf(appt.Id));
                    }
                }
            }
        } catch (Exception e) {
            ErrorLogger.logException('CareFinderController.sendPatientConfirmation', e, null);
        }
    }

    private static BookingResult doConfirm(Id appointmentId, String issueText) {
        BookingResult result = new BookingResult();
        try {
            List<Appointment__c> found = [
                SELECT Id, Provider__r.Provider_Name__c, Provider__r.Office_Email__c,
                       Doctor__c, Doctor__r.Name,
                       Patient__r.First_Name__c, Patient__r.Last_Name__c, Patient__r.Phone__c, Patient__r.Email__c,
                       Procedure_Type__c, Appointment_Date__c, Issue_Description__c
                FROM Appointment__c
                WHERE Id = :appointmentId
                LIMIT 1
            ];
            if (found.isEmpty()) {
                result.success = false;
                result.message = 'I couldn\'t find your pending estimate. Please reply "hi" to start again.';
                return result;
            }
            Appointment__c appt = found[0];

            if (String.isNotBlank(issueText)) {
                appt.Issue_Description__c = issueText.left(1000);
            }
            appt.Status__c = 'Call Requested';
            update appt;

            String patientName = (appt.Patient__r != null)
                ? ((appt.Patient__r.First_Name__c == null ? '' : appt.Patient__r.First_Name__c) + ' '
                    + (appt.Patient__r.Last_Name__c == null ? '' : appt.Patient__r.Last_Name__c)).trim()
                : 'Unknown patient';
            String patientPhone = (appt.Patient__r != null && String.isNotBlank(appt.Patient__r.Phone__c))
                ? appt.Patient__r.Phone__c : 'Not on file';
            String issue = String.isNotBlank(appt.Issue_Description__c)
                ? appt.Issue_Description__c : 'Not provided';
            String officeEmail = (appt.Provider__r != null) ? appt.Provider__r.Office_Email__c : null;

            if (String.isNotBlank(officeEmail)) {
                Messaging.SingleEmailMessage email = new Messaging.SingleEmailMessage();
                email.setToAddresses(new String[]{ officeEmail });
                email.setSubject('Appointment request — ' + patientName);
                email.setPlainTextBody(
                    'A patient has requested an appointment.\n\n' +
                    'Patient: ' + patientName + '\n' +
                    'Phone: ' + patientPhone + '\n' +
                    'Reason for visit: ' + issue + '\n' +
                    'Doctor: ' + (appt.Doctor__c != null ? appt.Doctor__r.Name : 'No preference specified') + '\n' +
                    'Procedure type: ' + appt.Procedure_Type__c + '\n' +
                    'Requested date: ' + (appt.Appointment_Date__c != null ? appt.Appointment_Date__c.format() : 'Not specified') + '\n\n' +
                    'Please call the patient to confirm an actual appointment time.'
                );
                                email.setSaveAsActivity(false);

                // Send from a fixed verified address instead of the portal user's address.
                List<OrgWideEmailAddress> owa = [
                    SELECT Id, Address FROM OrgWideEmailAddress
                    WHERE Address = 'thatmanu602@gmail.com' LIMIT 1
                ];
                if (!owa.isEmpty()) {
                    email.setOrgWideEmailAddressId(owa[0].Id);
                }
                System.debug(LoggingLevel.ERROR, 'CALLBACK_EMAIL orgWide=' + (owa.isEmpty() ? 'NOT FOUND (sending as ' + UserInfo.getUserEmail() + ')' : owa[0].Address)
                    + ' to=' + officeEmail + ' appt=' + appointmentId);

                Messaging.SendEmailResult[] sendResults =
                    Messaging.sendEmail(new Messaging.SingleEmailMessage[]{ email }, false);
                for (Messaging.SendEmailResult sr : sendResults) {
                    System.debug(LoggingLevel.ERROR, 'CALLBACK_EMAIL success=' + sr.isSuccess());
                    if (!sr.isSuccess()) {
                        for (Messaging.SendEmailError err : sr.getErrors()) {
                            System.debug(LoggingLevel.ERROR, 'CALLBACK_EMAIL error=' + err.getStatusCode() + ' ' + err.getMessage());
                            ErrorLogger.log('CareFinderController.doConfirm', 'Warning',
                                'Callback email failed: ' + err.getStatusCode() + ' ' + err.getMessage(),
                                'to=' + officeEmail, String.valueOf(appointmentId));
                        }
                    }
                }
                result.message = 'Callback request sent to the office.';
            } else {
                result.message = 'Request saved, but this provider has no office email on file to notify.';
            }
            // Tell the patient their request was sent. A failure here never fails the request.
            sendPatientConfirmation(appt, patientName);
            result.success = true;
        } catch (Exception e) {
            result.success = false;
            result.message = 'Could not send the callback request: ' + e.getMessage();
            ErrorLogger.logException('CareFinderController.confirmBooking', e, null);
        }
        return result;
    }
}
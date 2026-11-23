/**
 * Bill checker. Same cost-sharing logic as the estimate screen, applied to each pasted charge:
 *   doctor + patient plan -> network status (Big Object, queried BEFORE any save)
 *   charge -> procedure type (CPT code, description words, the doctor's specialty)
 *   plan rule for that type -> flat copay / covered in full / deductible + coinsurance / excluded
 * Deductible is assumed unmet at the start of the bill and is used up across the lines in order.
 * Errors are written to the debug log with the tag CoverageChecker and a short reference code.
 */
public without sharing class CoverageCheckerController {

    public class DoctorOption {
        @AuraEnabled public String value;      // Doctor__c Id
        @AuraEnabled public String label;      // "Name - Specialty"
    }

    public class ChargeResult {
        @AuraEnabled public String description;
        @AuraEnabled public Decimal billedAmount;
        @AuraEnabled public Decimal patientResponsibility;
        @AuraEnabled public Boolean flaggedAsUnreasonable;
        @AuraEnabled public String serviceType;   // procedure type used
        @AuraEnabled public String howCalculated; // plain-language reason
        @AuraEnabled public String category;      // heading on the bill, if it had one
    }

    public class BillAnalysisResult {
        @AuraEnabled public String billId;
        @AuraEnabled public Decimal totalBilled;
        @AuraEnabled public Decimal totalPatientResponsibility;
        @AuraEnabled public String doctorName;
        @AuraEnabled public String planName;
        @AuraEnabled public String networkLabel;  // In-network / Out-of-network / Network unknown
        @AuraEnabled public Boolean networkAssumed; // true when no doctor was found, so in-network rules were assumed
        @AuraEnabled public Decimal insurancePays;  // total billed minus what the patient owes
        @AuraEnabled public Decimal deductibleApplied; // part of what the patient owes that goes toward the deductible
        @AuraEnabled public List<ChargeResult> charges;
    }

    // ---------- doctor picker ----------
    @AuraEnabled
    public static List<DoctorOption> searchDoctors(String term) {
        List<DoctorOption> out = new List<DoctorOption>();
        try {
            if (String.isBlank(term) || term.trim().length() < 2) {
                return out;
            }
            // Match on every word of the name, in any order, so "Jeffrey M. Wilson, MD" finds the
            // doctor however the list spells the name (middle initial, credentials, "Wilson, Jeffrey").
            List<String> words = new List<String>();
            for (String w : term.trim().split('[\\s,]+')) {
                String clean = w.replaceAll('[^A-Za-z\\-\']', '');
                String low = clean.toLowerCase();
                if (clean.length() < 2) { continue; }
                // Drop credentials only when a full name was typed, so a single "Pa" still finds Patel.
                if (term.trim().contains(' ') && new Set<String>{ 'md', 'do', 'dmd', 'dds', 'dpm', 'np', 'pa', 'dr', 'phd', 'od' }.contains(low)) { continue; }
                words.add(clean);
            }
            if (words.isEmpty()) { return out; }
            String t1 = '%' + words[0] + '%';
            String t2 = words.size() > 1 ? '%' + words[1] + '%' : '%';
            String t3 = words.size() > 2 ? '%' + words[2] + '%' : '%';
            List<Doctor__c> found = [
                SELECT Id, Name, Specialty__c FROM Doctor__c
                WHERE Name LIKE :t1 AND Name LIKE :t2 AND Name LIKE :t3 ORDER BY Name LIMIT 15
            ];
            if (found.isEmpty() && words.size() > 1) {
                // Fall back to the longest word (usually the surname).
                String longest = words[0];
                for (String w : words) { if (w.length() > longest.length()) { longest = w; } }
                String tl = '%' + longest + '%';
                found = [SELECT Id, Name, Specialty__c FROM Doctor__c WHERE Name LIKE :tl ORDER BY Name LIMIT 15];
            }
            for (Doctor__c d : found) {
                DoctorOption o = new DoctorOption();
                o.value = d.Id;
                o.label = d.Name + (String.isBlank(d.Specialty__c) ? '' : ' - ' + d.Specialty__c);
                out.add(o);
            }
        } catch (Exception e) {
            throw fail('searchDoctors', e, 'We could not search doctors right now. Please try again.');
        }
        return out;
    }

    // ---------- main ----------
    @AuraEnabled
    public static BillAnalysisResult analyzeBill(String providerName, String billDate, String billText, String doctorId, String billNumber) {
        try {
            // Reject a future or unusable bill date before anything is queried or saved.
            String billDateProblem = checkBillDate(billDate);
            if (billDateProblem != null) {
                throw new AuraHandledException(billDateProblem);
            }

            List<Patient__c> patients = [
                SELECT Id, Insurance_Plan__c FROM Patient__c
                WHERE Related_User__c = :UserInfo.getUserId() LIMIT 1
            ];
            if (patients.isEmpty()) {
                throw new AuraHandledException('We could not find your patient profile.');
            }
            Patient__c patient = patients[0];

            // The doctor is optional. Without one: network unknown, no specialty-based matching.
            Doctor__c doctor = null;
            if (!String.isBlank(doctorId)) {
                List<Doctor__c> docs = [SELECT Id, Name, Specialty__c FROM Doctor__c WHERE Id = :doctorId LIMIT 1];
                if (docs.isEmpty()) {
                    throw new AuraHandledException('We could not find that doctor. Please choose again or leave it blank.');
                }
                doctor = docs[0];
            }
            String doctorName = doctor == null ? null : doctor.Name;
            String doctorSpecialty = doctor == null ? null : doctor.Specialty__c;

            List<BillTextParser.ParsedCharge> parsed = BillTextParser.parse(billText);
            if (parsed.isEmpty()) {
                throw new AuraHandledException('We could not find any charges in the text you pasted. Please check the format and try again.');
            }

            // 1. Network status first. Big Object queries can't run once a save is pending.
            Id planId = patient.Insurance_Plan__c;
            Boolean networkFound = false;
            String networkTier = null;
            if (planId != null && doctor != null) {
                NetworkStatusLookup.Request nreq = new NetworkStatusLookup.Request();
                nreq.doctorId = String.valueOf(doctor.Id);
                nreq.planId = String.valueOf(planId);
                NetworkStatusLookup.Result nres =
                    NetworkStatusLookup.lookup(new List<NetworkStatusLookup.Request>{ nreq })[0];
                networkFound = nres.found;
                networkTier = nres.networkTier;
            }
            Boolean outOfNetwork = (networkTier == 'Out-of-Network');
            String networkLabel = planId == null ? 'No plan on file'
                : doctor == null ? 'Doctor not found, in-network assumed'
                : outOfNetwork ? 'Out-of-network'
                : networkFound ? 'In-network' : 'Network unknown';

            Boolean networkAssumed = (planId != null && doctor == null);

            // 2. Plan, rules, doctor prices, benchmarks.
            PlanInfo plan = loadPlan(planId);
            Map<String, RuleInfo> rules = loadRules(planId);
            Map<String, Doctor_Price__c> docPrices = new Map<String, Doctor_Price__c>();
            Id docRecordId = doctor == null ? null : doctor.Id;
            // Doctor prices only sharpen the price flag. If this user can't read the object,
            // log it and fall back to the typical price instead of failing the whole bill.
            try {
                if (docRecordId != null) {
                    List<Doctor_Price__c> docPriceRows = [
                        SELECT Procedure_Type__c, Avg_Submitted_Charge__c, HCPCS_Code__c FROM Doctor_Price__c WHERE Doctor__c = :docRecordId
                    ];
                    for (Doctor_Price__c dp : docPriceRows) {
                        docPrices.put(dp.Procedure_Type__c, dp);
                    }
                }
            } catch (Exception e) {
                System.debug(LoggingLevel.WARN, 'CoverageChecker WARN doctor prices not readable by this user, '
                    + 'using typical prices | ' + e.getTypeName() + ': ' + e.getMessage());
            }
            Map<String, Decimal> benchByCpt = new Map<String, Decimal>();
            for (Price_Benchmark__c pb : [SELECT CPT_Code__c, Average_Cost__c FROM Price_Benchmark__c WHERE CPT_Code__c != null]) {
                benchByCpt.put(pb.CPT_Code__c, pb.Average_Cost__c);
            }
            List<String> typeValues = picklistValues('Coverage_Rule__c', 'Coverage_Rule__c');
            Boolean dentalPlan = isDentalPlan(typeValues, rules);

            // 3. Per-charge math.
            Decimal deductibleLeft = plan.deductible == null ? 0 : plan.deductible;
            // The yearly out-of-pocket maximum is shared by the patient's bills, so what is owed on their
            // earlier bills comes off it first. A bill already saved (same charges) keeps the result it
            // had when it was first checked: only bills saved before it count, so checking it again gives
            // the same amounts. A new bill counts every bill saved so far.
            // A bill number typed (or read) from the bill identifies the bill: the same number from the same
            // provider is the same bill, even if the pasted text changes a little.
            String billNo = String.isBlank(billNumber) ? null : billNumber.trim();
            String provForMatch = String.isBlank(providerName) ? doctorName : providerName;
            Id numberBillId = null;
            Datetime numberBillCreated = null;
            if (billNo != null) {
                Id meNo = UserInfo.getUserId();
                List<Bill__c> byNumber = [
                    SELECT Id, CreatedDate FROM Bill__c
                    WHERE CreatedById = :meNo AND Bill_Number__c = :billNo
                      AND (Provider_Name__c = :provForMatch OR Provider_Name__c = null)
                    ORDER BY CreatedDate ASC LIMIT 1
                ];
                if (!byNumber.isEmpty()) {
                    numberBillId = byNumber[0].Id;
                    numberBillCreated = byNumber[0].CreatedDate;
                }
            }
            Decimal priorOwed = 0;
            if (plan.oopMax != null && planId != null && !outOfNetwork) {
                List<String> thisSig = new List<String>();
                for (BillTextParser.ParsedCharge pc0 : parsed) {
                    thisSig.add(chargeKey(new Charge__c(
                        Charge_Description__c = pc0.description, CPT_Code__c = pc0.cptCode, Billed_Amount__c = pc0.amount)));
                }
                thisSig.sort();
                Id meId = UserInfo.getUserId();
                Map<Id, List<String>> sigByBill = new Map<Id, List<String>>();
                Map<Id, Decimal> owedByBill = new Map<Id, Decimal>();
                Map<Id, Datetime> createdByBill = new Map<Id, Datetime>();
                for (Charge__c ex : [
                    SELECT Bill__c, Bill__r.CreatedDate, Charge_Description__c, CPT_Code__c, Billed_Amount__c, Patient_Responsibility__c
                    FROM Charge__c WHERE Bill__r.CreatedById = :meId LIMIT 5000
                ]) {
                    if (!sigByBill.containsKey(ex.Bill__c)) {
                        sigByBill.put(ex.Bill__c, new List<String>());
                        owedByBill.put(ex.Bill__c, 0);
                        createdByBill.put(ex.Bill__c, ex.Bill__r.CreatedDate);
                    }
                    sigByBill.get(ex.Bill__c).add(chargeKey(ex));
                    owedByBill.put(ex.Bill__c, owedByBill.get(ex.Bill__c)
                        + (ex.Patient_Responsibility__c == null ? 0 : ex.Patient_Responsibility__c));
                }
                // The earliest saved copy of this same bill sets the cut-off.
                Datetime cutoff = numberBillCreated;
                for (Id bid : sigByBill.keySet()) {
                    if (numberBillId != null) { break; }
                    List<String> sg = sigByBill.get(bid);
                    sg.sort();
                    if (sg == thisSig && (cutoff == null || createdByBill.get(bid) < cutoff)) {
                        cutoff = createdByBill.get(bid);
                    }
                }
                for (Id bid : sigByBill.keySet()) {
                    List<String> sg = sigByBill.get(bid);
                    if (bid == numberBillId) { continue; }
                    if (numberBillId == null && sg == thisSig) { continue; }
                    if (cutoff != null && createdByBill.get(bid) >= cutoff) { continue; }
                    priorOwed += owedByBill.get(bid);
                }
            }
            Decimal oopLeft = plan.oopMax; // null = no cap
            if (oopLeft != null) {
                oopLeft = oopLeft - priorOwed;
                if (oopLeft < 0) { oopLeft = 0; }
            }
            Map<String, Decimal> copayLeft = new Map<String, Decimal>();
            List<Charge__c> toInsert = new List<Charge__c>();
            List<ChargeResult> results = new List<ChargeResult>();
            Decimal totalBilled = 0;
            Decimal totalOwed = 0;
            Decimal deductibleApplied = 0;
            List<String> chargeTypes = new List<String>();

            for (BillTextParser.ParsedCharge pc : parsed) {
                String procType = classify(pc.description, pc.cptCode, pc.category, doctorSpecialty, typeValues, dentalPlan);
                RuleInfo rule = procType == null ? null : rules.get(procType);
                Decimal amount = pc.amount;
                Decimal owed;
                String how;

                if (planId == null) {
                    owed = amount; how = 'No insurance plan on file, so the full charge is yours.';
                } else if (outOfNetwork) {
                    owed = amount; how = 'This doctor is out-of-network for your plan, so no plan benefit is applied.';
                } else if (procType == null) {
                    owed = amount;
                    how = dentalPlan
                        ? 'This looks like a medical charge, and your plan is a dental plan, so it is not covered here. The full charge is shown. Ask the provider\'s billing office if it can go to a medical plan.'
                        : 'We could not match this charge to a type of service, so the full amount is shown and no plan discount is applied. '
                            + 'This is common for drugs, supplies and unusual codes. Check the code on your bill, or call the provider\'s billing office and ask what the charge is for and whether it was sent to your insurance.';
                } else if (rule == null) {
                    owed = amount; how = 'Your plan has no coverage rule for ' + procType + ', so the full charge is shown. Call your insurer to ask whether this service is covered.';
                } else if (rule.excluded) {
                    owed = amount; how = 'Your plan excludes this service.';
                } else if (rule.method == 'Covered in Full') {
                    owed = 0; how = 'Covered in full by your plan.';
                } else if (rule.method == 'Flat Copay') {
                    if (rule.copay == null) {
                        throw fail('flatCopay', new CheckerException('Flat Copay rule has no copay value for ' + procType
                            + ' (resolved copay field: ' + rule.copayField + ')'),
                            'We could not read your plan copay for this service.');
                    }
                    // A flat copay is charged once per service type on a bill, not once per line.
                    Decimal remaining = copayLeft.containsKey(procType) ? copayLeft.get(procType) : rule.copay;
                    owed = remaining < amount ? remaining : amount;
                    copayLeft.put(procType, remaining - owed);
                    if (remaining == 0) {
                        how = 'Your $' + rule.copay.setScale(2) + ' flat copay for ' + procType + ' was already counted earlier on this bill.';
                    } else if (remaining < rule.copay) {
                        how = 'Rest of your $' + rule.copay.setScale(2) + ' flat copay for ' + procType + '.';
                    } else if (rule.copay < amount) {
                        how = 'Flat copay of $' + rule.copay.setScale(2) + ' for this service.';
                    } else {
                        how = 'Your flat copay is $' + rule.copay.setScale(2) + ', which is more than this charge, so you owe the full $'
                            + amount.setScale(2) + '.';
                    }
                } else if (rule.method == 'Deductible + Coinsurance') {
                    Decimal rate = rule.coinsurance != null ? rule.coinsurance : plan.coinsurance;
                    if (rate == null) { rate = 0; }
                    Decimal fromDeductible = amount < deductibleLeft ? amount : deductibleLeft;
                    deductibleLeft -= fromDeductible;
                    deductibleApplied += fromDeductible;
                    owed = fromDeductible + (amount - fromDeductible) * rate;
                    Decimal afterDeductible = amount - fromDeductible;
                    if (fromDeductible > 0 && afterDeductible == 0) {
                        how = 'Applied to your deductible ($' + fromDeductible.setScale(2) + ').';
                    } else if (fromDeductible > 0) {
                        how = 'Deductible first ($' + fromDeductible.setScale(2) + ' applied), then ' + pct(rate) + ' coinsurance.';
                    } else if (plan.deductible == null || plan.deductible == 0) {
                        how = pct(rate) + ' coinsurance. This plan has no deductible.';
                    } else {
                        how = 'Deductible already used up on earlier lines; ' + pct(rate) + ' coinsurance.';
                    }
                } else if (rule.coveragePct != null) {
                    owed = amount * (1 - rule.coveragePct / 100);
                    how = 'Your plan pays ' + rule.coveragePct.setScale(0) + '%.';
                } else {
                    owed = amount; how = 'Cost-sharing method not recognised (' + rule.method + '), full charge shown.';
                }
                if (oopLeft != null && planId != null && !outOfNetwork) {
                    if (owed > oopLeft) {
                        owed = oopLeft;
                        how += priorOwed > 0
                            ? ' Capped at your out-of-pocket maximum, counting $' + priorOwed.setScale(2) + ' you already owe on your other bills.'
                            : ' Capped at your out-of-pocket maximum.';
                    }
                    oopLeft -= owed;
                }
                owed = owed.setScale(2, System.RoundingMode.HALF_UP);

                // Reasonableness flag. Only compared when the bill's CPT code is the same code the
                // reference price is for, so a lab bill isn't judged against a different lab test.
                Boolean flagged = false;
                if (pc.cptCode != null) {
                    Decimal ref = null;
                    Doctor_Price__c dpr = procType == null ? null : docPrices.get(procType);
                    if (dpr != null && dpr.HCPCS_Code__c == pc.cptCode && dpr.Avg_Submitted_Charge__c != null) {
                        ref = dpr.Avg_Submitted_Charge__c;
                    } else if (benchByCpt.containsKey(pc.cptCode)) {
                        ref = benchByCpt.get(pc.cptCode);
                    }
                    if (ref != null && ref > 0 && amount > ref * 1.5) { flagged = true; }
                }

                toInsert.add(new Charge__c(
                    Charge_Description__c = pc.description, CPT_Code__c = pc.cptCode,
                    Billed_Amount__c = amount, Patient_Responsibility__c = owed,
                    Flagged_As_Unreasonable__c = flagged));
                chargeTypes.add(procType);

                ChargeResult cr = new ChargeResult();
                cr.description = pc.description; cr.billedAmount = amount; cr.patientResponsibility = owed;
                cr.flaggedAsUnreasonable = flagged;
                cr.serviceType = procType == null ? 'Not matched' : procType;
                cr.howCalculated = how;
                cr.category = pc.category;
                results.add(cr);
                totalBilled += amount; totalOwed += owed;
                System.debug(LoggingLevel.INFO, 'CoverageChecker line: ' + pc.description + ' | type=' + procType
                    + ' | method=' + (rule == null ? 'none' : rule.method) + ' | billed=' + amount + ' | owed=' + owed);
            }

            // 4. Save (after every query above). Checking the same bill again must not create a second
            // bill: a bill from the same user with the same provider, date and charges is reused, and only
            // its calculated amounts are refreshed.
            Id savedBillId = null;
            {
                Id me = UserInfo.getUserId();
                String provName = String.isBlank(providerName) ? doctorName : providerName;
                Date bDate = String.isBlank(billDate) ? null : Date.valueOf(billDate);

                List<String> newSig = new List<String>();
                for (Charge__c c : toInsert) { newSig.add(chargeKey(c)); }
                newSig.sort();

                List<Bill__c> candidates = [
                    SELECT Id FROM Bill__c
                    WHERE CreatedById = :me AND Bill_Date__c = :bDate AND Provider_Name__c = :provName
                    ORDER BY CreatedDate DESC LIMIT 20
                ];
                Map<Id, List<Charge__c>> chargesByBill = new Map<Id, List<Charge__c>>();
                if (!candidates.isEmpty()) {
                    for (Charge__c ex : [
                        SELECT Id, Bill__c, Charge_Description__c, CPT_Code__c, Billed_Amount__c
                        FROM Charge__c WHERE Bill__c IN :candidates
                    ]) {
                        if (!chargesByBill.containsKey(ex.Bill__c)) { chargesByBill.put(ex.Bill__c, new List<Charge__c>()); }
                        chargesByBill.get(ex.Bill__c).add(ex);
                    }
                }
                Id existingBillId = numberBillId;
                for (Bill__c cand : candidates) {
                    if (existingBillId != null) { break; }
                    List<Charge__c> exList = chargesByBill.get(cand.Id);
                    if (exList == null) { continue; }
                    List<String> sig = new List<String>();
                    for (Charge__c ex : exList) { sig.add(chargeKey(ex)); }
                    sig.sort();
                    if (sig == newSig) { existingBillId = cand.Id; break; }
                }

                if (existingBillId != null) {
                    // Same bill checked again: refresh the amounts on the saved charges, add nothing new.
                    Map<String, List<Charge__c>> pool = new Map<String, List<Charge__c>>();
                    List<Charge__c> savedCharges = chargesByBill.get(existingBillId);
                    if (savedCharges == null) {
                        savedCharges = [
                            SELECT Id, Bill__c, Charge_Description__c, CPT_Code__c, Billed_Amount__c
                            FROM Charge__c WHERE Bill__c = :existingBillId
                        ];
                    }
                    List<Charge__c> notSaved = new List<Charge__c>();
                    for (Charge__c ex : savedCharges) {
                        String k = chargeKey(ex);
                        if (!pool.containsKey(k)) { pool.put(k, new List<Charge__c>()); }
                        pool.get(k).add(ex);
                    }
                    List<Charge__c> toUpdate = new List<Charge__c>();
                    for (Charge__c c : toInsert) {
                        List<Charge__c> matches = pool.get(chargeKey(c));
                        if (matches != null && !matches.isEmpty()) {
                            Charge__c ex = matches.remove(0);
                            // Update a bare record (Id + the two amounts only). Sending the existing record back would
                            // include the Bill lookup, which cannot be changed on a charge.
                            toUpdate.add(new Charge__c(
                                Id = ex.Id,
                                Patient_Responsibility__c = c.Patient_Responsibility__c,
                                Flagged_As_Unreasonable__c = c.Flagged_As_Unreasonable__c));
                        } else {
                            notSaved.add(c);
                        }
                    }
                    if (!toUpdate.isEmpty()) { update toUpdate; }
                    // Same bill number but the text now has a charge that was not saved before: add it.
                    if (!notSaved.isEmpty()) {
                        for (Charge__c c : notSaved) { c.Bill__c = existingBillId; }
                        insert notSaved;
                    }
                    if (billNo != null && numberBillId == null) {
                        update new Bill__c(Id = existingBillId, Bill_Number__c = billNo);
                    }
                    savedBillId = existingBillId;
                } else {
                    Bill__c bill = new Bill__c(
                        Bill_Date__c = bDate, Provider_Name__c = provName,
                        Bill_Number__c = billNo,
                        Status__c = 'Under Review');
                    insert bill;
                    for (Charge__c c : toInsert) { c.Bill__c = bill.Id; }
                    insert toInsert;
                    savedBillId = bill.Id;
                }
            }

            BillAnalysisResult res = new BillAnalysisResult();
            res.billId = savedBillId;
            res.totalBilled = totalBilled.setScale(2, System.RoundingMode.HALF_UP);
            res.totalPatientResponsibility = totalOwed.setScale(2, System.RoundingMode.HALF_UP);
            res.doctorName = doctorName;
            res.planName = plan.name;
            res.networkLabel = networkLabel;
            res.networkAssumed = networkAssumed;
            res.insurancePays = (totalBilled - totalOwed).setScale(2, System.RoundingMode.HALF_UP);
            res.deductibleApplied = (deductibleApplied > totalOwed ? totalOwed : deductibleApplied).setScale(2, System.RoundingMode.HALF_UP);
            res.charges = results;
            return res;

        } catch (AuraHandledException ahe) {
            throw ahe;
        } catch (Exception e) {
            String detail = (e instanceof DmlException) ? ' ' + ((DmlException) e).getDmlMessage(0) : '';
            throw fail('analyzeBill', e, 'Error analyzing bill.' + detail + ' Please try again.');
        }
    }

    // Identifies a charge for duplicate detection: description, CPT code and billed amount.
    static String chargeKey(Charge__c c) {
        String d = (c.Charge_Description__c == null ? '' : c.Charge_Description__c.toLowerCase().replaceAll('\\s+', ' ').trim());
        String cpt = c.CPT_Code__c == null ? '' : c.CPT_Code__c;
        Decimal amt = c.Billed_Amount__c == null ? 0 : c.Billed_Amount__c.setScale(2);
        return d + '|' + cpt + '|' + amt;
    }

    // Returns a user-facing message if the bill date cannot be used, otherwise null.
    // The date is optional. One day of slack is allowed on "today" because the patient's
    // browser date can be a day ahead of the Salesforce user's time zone (the page itself
    // already blocks any date after the patient's own today).
    @TestVisible
    static String checkBillDate(String billDate) {
        if (String.isBlank(billDate)) {
            return null;
        }
        Date parsed;
        try {
            parsed = Date.valueOf(billDate);
        } catch (Exception e) {
            return 'Please enter a valid bill date.';
        }
        if (parsed > Date.today().addDays(1)) {
            return 'Bill date cannot be in the future.';
        }
        if (parsed < Date.today().addYears(-10)) {
            return 'Please enter a valid bill date. Bills older than 10 years cannot be checked.';
        }
        return null;
    }

    // ---------- classification ----------
    static String classify(String description, String cpt, String category, String specialty, List<String> typeValues, Boolean dentalPlan) {
        String d = (description == null ? '' : description).toLowerCase();
        String cat = (category == null ? '' : category).toLowerCase();
        // Hospital bills: the bill's own heading decides the type.
        if (!dentalPlan && cat.length() > 0) {
            if (cat.contains('laborator')) { return pick(typeValues, 'lab'); }
            if (cat.contains('radiolog') || cat.contains('imaging')) { return pick(typeValues, 'imaging'); }
            if (cat.contains('room') || cat.contains('operating') || cat.contains('anesthes') || cat.contains('recovery')
                || cat.contains('labor') || cat.contains('supplies') || cat.contains('pharmacy') || cat.contains('surgical')) {
                return pick(typeValues, 'surgery');
            }
        }
        String sp = (specialty == null ? '' : specialty).toLowerCase();
        Integer code = (cpt != null && cpt.isNumeric()) ? Integer.valueOf(cpt) : null;

        if (dentalPlan) {
            if (d.contains('crown')) { return pick(typeValues, 'crown'); }
            if (d.contains('fill') || d.contains('composite') || d.contains('amalgam')) { return pick(typeValues, 'fill'); }
            if (d.contains('clean') || d.contains('prophy') || d.contains('exam') || d.contains('evaluation')) { return pick(typeValues, 'clean'); }
            return null;
        }
        // Hospital charges that arrive without a heading (printed statements).
        if (!dentalPlan) {
            if (d.contains('room daily') || d.contains('anesthesia') || d.contains('pacu') || d.contains('labor care')
                || d.contains('fetal') || d.contains('c section') || d.contains('deliv') || d.contains('cesarean')
                || d.contains('postpartum') || d.contains('prenatal') || d.contains('obste') || d.contains('antepartum')
                || (code != null && code >= 59000 && code <= 59899) || d.contains('pack custom')
                || d.contains('retr srg') || d.contains('operating room')) {
                return pick(typeValues, 'surgery');
            }
            // HCPCS drug and supply codes (J3010, A4216...) are hospital charges.
            if (cpt != null && cpt.length() == 5 && !cpt.isNumeric()) {
                return pick(typeValues, 'surgery');
            }
            if (d.contains('sodium chloride') || d.contains('ringer') || d.contains('saline') || d.contains('dextrose')
                || d.contains(' mg') || d.contains(' ml') || d.contains('solution') || d.contains('tablet') || d.contains('patch')
                || d.contains('cream') || d.contains('syringe') || d.contains('vial') || d.contains('ampule') || d.contains(' pack')) {
                return pick(typeValues, 'surgery');
            }
            if (d.contains('crossmatch') || d.contains('antibody') || d.contains('blood typing') || d.contains('syphilis')
                || d.contains('venipuncture')) {
                return pick(typeValues, 'lab');
            }
        }
        if (d.contains('emergency') || d.contains(' er ') || d.startsWith('er ') || (code != null && code >= 99281 && code <= 99285)) {
            return pick(typeValues, 'emergency');
        }
        if (d.contains('mri') || d.contains('ct scan') || d.contains('pet scan') || (code != null && code >= 70450 && code <= 78999 && d.contains('ct'))) {
            return pick(typeValues, 'advanced');
        }
        if (d.contains('x-ray') || d.contains('xray') || d.contains('imaging') || d.contains('ultrasound') || d.contains('radiolog')
            || (code != null && code >= 70000 && code <= 79999)) {
            return pick(typeValues, 'imaging');
        }
        if (d.contains('vaccin') || d.contains('immuniz') || d.contains('preventive') || d.contains('annual physical') || d.contains('wellness')) {
            return pick(typeValues, 'prevent');
        }
        if (d.contains('physical therapy') || d.contains('therapy session')) { return pick(typeValues, 'physical'); }
        if (d.contains('counsel') || d.contains('psychother') || d.contains('mental')) { return pick(typeValues, 'mental'); }
        if (d.contains('surgery') || d.contains('operation') || d.contains('hospital stay')) { return pick(typeValues, 'surgery'); }
        if (d.contains('lab') || d.contains('blood') || d.contains('panel') || d.contains('culture') || d.contains('strep')
            || d.contains('urinalysis') || d.contains('cbc') || (code != null && code >= 80000 && code <= 89999)) {
            return pick(typeValues, 'lab');
        }
        if (d.contains('hydration') || d.contains('infusion') || d.contains(' iv ') || d.startsWith('iv ') || d.contains('intravenous')
            || (code != null && code >= 96360 && code <= 96549)) {
            return pick(typeValues, 'outpatient');
        }
        if (d.contains('injection') || d.contains('procedure') || d.contains('splint') || d.contains('cast') || d.contains('removal')
            || d.contains('hearing') || d.contains('audiolog') || d.contains('biopsy')
            || (code != null && code >= 10000 && code <= 69999) || (code != null && code >= 92000 && code <= 92999)) {
            return pick(typeValues, 'outpatient');
        }
        if (d.contains('office visit') || d.contains('visit') || d.contains('consult') || (code != null && code >= 99202 && code <= 99215)) {
            Boolean primary = sp.length() == 0 || sp.contains('family') || sp.contains('internal') || sp.contains('pediatric')
                || sp.contains('general practice') || sp.contains('primary');
            return pick(typeValues, primary ? 'office' : 'specialist');
        }
        return null; // not recognised: shown as "Not matched" at full charge
    }

    static String pick(List<String> typeValues, String word) {
        for (String v : typeValues) {
            if (v.toLowerCase().startsWith(word)) { return v; }
        }
        for (String v : typeValues) {
            if (v.toLowerCase().contains(word)) { return v; }
        }
        return null;
    }

    static Boolean isDentalPlan(List<String> typeValues, Map<String, RuleInfo> rules) {
        for (String k : rules.keySet()) {
            if (k.toLowerCase().contains('dental')) { return true; }
        }
        return false;
    }

    static List<String> picklistValues(String objName, String fieldName) {
        List<String> vals = new List<String>();
        for (Schema.PicklistEntry pe : Schema.getGlobalDescribe().get(objName).getDescribe()
                .fields.getMap().get(fieldName).getDescribe().getPicklistValues()) {
            vals.add(pe.getValue());
        }
        return vals;
    }

    // ---------- plan and rule loading (field names resolved at run time, then logged) ----------
    class PlanInfo {
        String name; Decimal deductible; Decimal coinsurance; Decimal oopMax;
    }
    class RuleInfo {
        String method; Boolean excluded; Decimal coveragePct; Decimal copay; Decimal coinsurance; String copayField;
    }

    static final List<String> COPAY_FIELDS = new List<String>{ 'Copay_Amount__c', 'Flat_Copay__c', 'Copay__c', 'Flat_Copay_Amount__c' };
    static final List<String> COINS_FIELDS = new List<String>{ 'Coinsurance_Rate__c' };
    static final List<String> DEDUCT_FIELDS = new List<String>{ 'Deductible__c' };
    static final List<String> OOP_FIELDS = new List<String>{ 'Out_of_Pocket_Max__c' };

    static String resolve(String objName, List<String> candidates) {
        Map<String, Schema.SObjectField> m = Schema.getGlobalDescribe().get(objName).getDescribe().fields.getMap();
        for (String c : candidates) {
            if (m.containsKey(c.toLowerCase())) { return c; }
        }
        return null;
    }

    static Decimal num(SObject s, String field) {
        if (field == null) { return null; }
        Object v = s.get(field);
        return v == null ? null : (Decimal) v;
    }

    // Rates stored as 20 mean 20 percent; rates stored as 0.2 also mean 20 percent.
    static Decimal asFraction(Decimal r) {
        if (r == null) { return null; }
        return r > 1 ? r / 100 : r;
    }

    static String pct(Decimal fraction) {
        return (fraction * 100).setScale(0) + '%';
    }

    static PlanInfo loadPlan(Id planId) {
        PlanInfo p = new PlanInfo();
        p.name = null;
        if (planId == null) { return p; }
        String fDed = resolve('Insurance_Plan__c', DEDUCT_FIELDS);
        String fCoin = resolve('Insurance_Plan__c', COINS_FIELDS);
        String fOop = resolve('Insurance_Plan__c', OOP_FIELDS);
        List<String> sel = new List<String>{ 'Id', 'Name' };
        for (String f : new List<String>{ fDed, fCoin, fOop }) { if (f != null) { sel.add(f); } }
        List<SObject> rows = Database.query('SELECT ' + String.join(sel, ',') + ' FROM Insurance_Plan__c WHERE Id = :planId LIMIT 1');
        if (!rows.isEmpty()) {
            p.name = (String) rows[0].get('Name');
            p.deductible = num(rows[0], fDed);
            p.coinsurance = asFraction(num(rows[0], fCoin));
            p.oopMax = num(rows[0], fOop);
            if (p.oopMax != null && p.oopMax >= 999999999) { p.oopMax = null; }
        }
        return p;
    }

    static Map<String, RuleInfo> loadRules(Id planId) {
        Map<String, RuleInfo> out = new Map<String, RuleInfo>();
        if (planId == null) { return out; }
        String fCopay = resolve('Coverage_Rule__c', COPAY_FIELDS);
        String fCoin = resolve('Coverage_Rule__c', COINS_FIELDS);
        List<String> sel = new List<String>{ 'Id', 'Coverage_Rule__c', 'Cost_Sharing_Method__c', 'Coverage_Percentage__c', 'Excluded__c' };
        for (String f : new List<String>{ fCopay, fCoin }) { if (f != null) { sel.add(f); } }
        for (SObject r : Database.query('SELECT ' + String.join(sel, ',') + ' FROM Coverage_Rule__c WHERE Insurance_Plan__c = :planId')) {
            RuleInfo ri = new RuleInfo();
            ri.method = (String) r.get('Cost_Sharing_Method__c');
            ri.excluded = (Boolean) r.get('Excluded__c') == true;
            ri.coveragePct = num(r, 'Coverage_Percentage__c');
            ri.copayField = fCopay;
            ri.copay = num(r, fCopay);
            ri.coinsurance = asFraction(num(r, fCoin));
            out.put((String) r.get('Coverage_Rule__c'), ri);
        }
        System.debug(LoggingLevel.INFO, 'CoverageChecker fields: copay=' + fCopay + ' coinsurance=' + fCoin + ' rules=' + out.size());
        return out;
    }

    // ---------- error log ----------
    public class CheckerException extends Exception {}

    static AuraHandledException fail(String context, Exception e, String userMessage) {
        String ref = String.valueOf(Math.abs(Crypto.getRandomInteger())).left(6);
        System.debug(LoggingLevel.ERROR, 'CoverageChecker ERROR [' + ref + '] in ' + context + ' | '
            + e.getTypeName() + ': ' + e.getMessage() + ' | line ' + e.getLineNumber() + ' | ' + e.getStackTraceString());
        try {
            ErrorLogger.log('CoverageCheckerController.' + context, 'Error', userMessage + ' (ref ' + ref + ')',
                e.getTypeName() + ': ' + e.getMessage() + ' | line ' + e.getLineNumber(), String.valueOf(UserInfo.getUserId()));
        } catch (Exception logEx) {
            System.debug(LoggingLevel.WARN, 'CoverageChecker could not write the error log: ' + logEx.getMessage());
        }
        AuraHandledException a = new AuraHandledException(userMessage + ' (ref ' + ref + ')');
        a.setMessage(userMessage + ' (ref ' + ref + ')');
        return a;
    }
}
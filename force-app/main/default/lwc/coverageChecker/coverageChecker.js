import { LightningElement } from 'lwc';
import analyzeBill from '@salesforce/apex/CoverageCheckerController.analyzeBill';
import searchDoctors from '@salesforce/apex/CoverageCheckerController.searchDoctors';
import getSavedBill from '@salesforce/apex/SavedBillController.getSavedBill';
import readBill from '@salesforce/apex/BillFileReader.readBill';

// BUG-32: plain-language meanings behind the small "i" icons.
const TIP_DEFS = [
    { test: /out-of-network/i, text: 'Out-of-network: no agreement with your insurance, so you may pay more, up to the full price.' },
    { test: /in-network/i, text: 'In-network: this doctor has an agreement with your insurance, so you usually pay less.' },
    { test: /deductible/i, text: 'Deductible: what you pay yourself each year before your insurance starts paying its share.' },
    { test: /copay/i, text: 'Copay: a fixed amount you pay for a visit or service.' },
    { test: /coinsurance/i, text: 'Coinsurance: your share, as a percentage, of costs after the deductible.' },
    { test: /excludes/i, text: 'Excluded: your plan does not cover this service, so you pay the full price.' },
    { test: /covered in full/i, text: 'Covered in full: your plan pays the whole cost, so you pay $0.' }
];

// Joins the meaning of every term that appears in a line of text.
function tipFor(text) {
    return TIP_DEFS.filter((d) => d.test.test(text || '')).map((d) => d.text).join(' ');
}

const PROGRESS_STEPS = [
    'Reading your bill…',
    'Matching each charge to your plan…',
    'Working out what insurance pays and what you owe…'
];

// The sentence added to a charge when the out-of-pocket maximum limits what the patient owes.
const CAP_SENTENCE = /\s*Capped at your out-of-pocket maximum.*$/i;

const MAX_UPLOAD_BYTES = 10 * 1024 * 1024; // biggest file we will open
const MAX_SEND_BYTES = 1000000;             // biggest file the text-reading service accepts (about 1 MB)

// Lines from a bill that are not charges (totals, balances, payments) and the provider /
// date header lines. Dropped so the totals are not counted as a charge.
// "Payments and Adjustments" headings are kept on purpose: BillTextParser uses them to skip the payment block.
const SKIP_LINE = /^(sub\s*)?total\b|\bamount\s+due\b|\bbalance\b|\bpayments?\b(?!\s+and\s+adjustments)|\b(insurance|patient)\s+adjustments?\b|\binsurance\s+(paid|payments?)\b|(?:^|[\s$])0\.00$|\bpatient\s+(balance|responsibility)\b|^page\s+\d+/i;
const HEADER_LINE = /^(rendering\s+)?(provider|physician|doctor)\s*:|(date\s+of\s+service|service\s+date|\bdos)\s*:/i;

// Wording on a bill that means the insurance has not finished paying its share yet.
const PENDING_CLAIM = /\bpending\b|awaiting\s+(insurance|payer|claim)|not\s+yet\s+(processed|adjudicated|paid)|claim\s+(is\s+)?(in\s+process|processing|submitted)/i;

// "Account number: QVM-2026-0052874", "Invoice #12345", "Bill no. 998877"
const BILL_NUMBER = /\b(?:account|acct|invoice|bill|statement)\s*(?:number|no\.?|#)\s*[:#]?\s*([A-Z0-9][A-Z0-9\-]{3,})/i;

// A saved bill keeps only amounts, so its lines have no service type. To still group a reopened
// bill, the group is worked out from the words in each line. A line that fits nothing goes to
// "Other charges". Fresh checks use the service type from the plan match instead.
const GROUP_RULES = [
    { name: 'Emergency care', test: /emergency|\ber\b|\bed\s+visit|trauma|urgent/i },
    { name: 'Advanced imaging', test: /\bmri\b|\bct\b|\bcat\s+scan|computed|\bpet\b|\bmra\b|nuclear/i },
    { name: 'Imaging', test: /ultrasound|sonogra|x-?ray|radiograph|mammo|\becho|imaging|fluoro|doppler/i },
    { name: 'Lab tests', test: /blood|panel|urinalysis|urine|culture|assay|glucose|\bcbc\b|metabolic|lipid|\blab\b|laborator|pathology|biopsy\s+exam|\btest\b/i },
    { name: 'Medication & infusions', test: /\biv\b|infusion|hydration|injection|medication|\bdrug|pharmacy|tablet|saline|antibiotic/i },
    { name: 'Surgery & procedures', test: /surg|procedure|repair|excision|biopsy|endoscop|colonoscop|suture|laceration|anesthesia/i },
    { name: 'Therapy', test: /therapy|rehab|counsel|psychotherapy/i },
    { name: 'Visits', test: /office\s+visit|consult|visit|evaluation|exam\b|check-?up|preventive|wellness|vaccine|immuniz/i }
];
function inferGroup(description) {
    const text = description || '';
    const hit = GROUP_RULES.find((r) => r.test.test(text));
    return hit ? hit.name : 'Other charges';
}

const money = (n) =>
    Number(n || 0).toLocaleString('en-US', { style: 'currency', currency: 'USD' });

export default class CoverageChecker extends LightningElement {
    providerName = '';
    billDate = '';
    billText = '';

    doctorSearch = '';
    doctorOptions = [];
    doctorId = '';
    doctorLabel = '';
    searchTimer;
    noDoctorMatch = false;
    billNumber = ''; // account / invoice number printed on the bill (shown on the result, not saved)
    pendingClaim = false; // the bill itself says the insurance claim is still pending

    result;
    errorMessage = '';
    openedFromDashboard = false;
    isSubmitting = false;

    // Bill upload (PDF, PNG or JPG)
    isReading = false;
    readingStatus = '';
    uploadNote = '';
    showManualEntry = false; // the line items box stays hidden until a bill is read or the patient asks for it

    // The result screen uses a wider column than the upload form.
    get contentClass() {
        return this.result ? 'checker-content checker-content-wide' : 'checker-content checker-content-card';
    }

    // The banner is tall on the upload form and slim on the result screen.
    get brandClass() {
        return this.result ? 'checker-brand checker-brand-compact' : 'checker-brand';
    }

    // Progress text while the bill is being read, so the wait does not look frozen.
    progressStep = 0;
    _progressTimer;
    get progressText() {
        return PROGRESS_STEPS[Math.min(this.progressStep, PROGRESS_STEPS.length - 1)];
    }

    startProgress() {
        this.progressStep = 0;
        window.clearInterval(this._progressTimer);
        this._progressTimer = window.setInterval(() => {
            this.progressStep += 1;
        }, 2500);
    }

    stopProgress() {
        window.clearInterval(this._progressTimer);
        this.progressStep = 0;
    }

    connectedCallback() {
        let billId = null;
        try { billId = new URLSearchParams(window.location.search).get('bill'); } catch (e) { billId = null; }
        if (!billId) return;
        this.openedFromDashboard = true;
        this.isSubmitting = true;
        getSavedBill({ billId })
            .then((b) => {
                this.isSubmitting = false;
                const data = {
                    billId: b.billId,
                    totalBilled: b.totalBilled,
                    totalPatientResponsibility: b.totalPatientResponsibility,
                    insurancePays: b.insurancePays,
                    deductibleApplied: 0,
                    planName: b.planName,
                    networkLabel: null,
                    networkAssumed: false,
                    saved: true,
                    charges: (b.charges || []).map((c) => ({ ...c, serviceType: '', howCalculated: '' }))
                };
                this.buildResult(data, {
                    providerName: b.providerName || '',
                    billNumber: b.billNumber || '',
                    billDate: b.billDate || '',
                    billText: '',
                    pendingClaim: false
                });
            })
            .catch((error) => {
                this.isSubmitting = false;
                console.log(error);
                this.errorMessage = 'We could not open that bill. Please go back to your dashboard and try again. You can also check a bill below.';
            });
    }

    disconnectedCallback() {
        window.clearInterval(this._progressTimer);
    }

    get submitLabel() {
        return this.isSubmitting ? 'Analyzing…' : 'Analyze Bill';
    }
    get hasDoctorOptions() {
        return this.doctorOptions.length > 0 && !this.doctorId;
    }
    get hasDoctor() {
        return !!this.doctorId;
    }
    // Upload / Type line items tabs
    tab = 'upload';
    get isUploadTab() { return this.tab === 'upload'; }
    get isManualTab() { return this.tab === 'manual'; }
    get uploadTabClass() { return this.tab === 'upload' ? 'seg-btn seg-btn-active' : 'seg-btn'; }
    get manualTabClass() { return this.tab === 'manual' ? 'seg-btn seg-btn-active' : 'seg-btn'; }
    handleTabUpload() { this.tab = 'upload'; }
    handleTabManual() { this.tab = 'manual'; }

    // The line items box belongs to the "Type line items" tab only. A file that was read keeps its text
    // here, so the patient can open that tab to check or fix a line.
    get showBillBox() {
        return this.tab === 'manual';
    }

    handleShowManualEntry() {
        this.showManualEntry = true;
    }

    handleProviderName(event) { this.providerName = event.target.value; }
    handleBillNumber(event) { this.billNumber = event.target.value; }
    handleBillDate(event) {
        this.billDate = event.target.value;
        const problem = this.billDateProblem(this.billDate);
        event.target.setCustomValidity(problem || '');
        event.target.reportValidity();
    }

    // Latest selectable bill date: today (local time), as YYYY-MM-DD.
    get maxBillDate() {
        return this.dateString(new Date());
    }

    dateString(d) {
        const mm = String(d.getMonth() + 1).padStart(2, '0');
        const dd = String(d.getDate()).padStart(2, '0');
        return `${d.getFullYear()}-${mm}-${dd}`;
    }

    // Mirrors CoverageCheckerController.checkBillDate. The date is optional.
    billDateProblem(value) {
        if (!value) {
            return null;
        }
        if (value > this.maxBillDate) {
            return 'Bill date cannot be in the future.';
        }
        const oldest = new Date();
        oldest.setFullYear(oldest.getFullYear() - 10);
        if (value < this.dateString(oldest)) {
            return 'Please enter a valid bill date. Bills older than 10 years cannot be checked.';
        }
        return null;
    }
    handleBillText(event)     { this.billText = event.target.value; }

    handleDoctorSearch(event) {
        const term = event.target.value;
        // keyup also fires for Tab/arrow keys; ignore if nothing changed
        if (term === this.doctorSearch && (this.doctorId || this.doctorOptions.length > 0)) {
            return;
        }
        this.doctorSearch = term;
        this.doctorId = '';
        this.doctorLabel = '';
        this.noDoctorMatch = false;
        window.clearTimeout(this.searchTimer);
        if (!term || term.trim().length < 2) {
            this.doctorOptions = [];
            return;
        }
        this.searchTimer = window.setTimeout(() => {
            searchDoctors({ term })
                .then((rows) => {
                    this.doctorOptions = rows;
                    this.noDoctorMatch = rows.length === 0;
                })
                .catch((error) => {
                    this.doctorOptions = [];
                    this.errorMessage = (error && error.body && error.body.message)
                        ? error.body.message
                        : 'We could not search doctors right now. Please try again.';
                });
        }, 300);
    }

    handleDoctorPick(event) {
        this.doctorId = event.detail.value;
        const match = this.doctorOptions.find((o) => o.value === this.doctorId);
        this.doctorLabel = match ? match.label : '';
        this.doctorSearch = this.doctorLabel;
        this.doctorOptions = [];
    }

    // Turns the data from Apex into what the result screen shows. ctx holds what the patient typed
    // (or, for a saved bill, what was saved): providerName, billNumber, billDate, billText, pendingClaim.
    buildResult(data, ctx) {
        const lines = data.charges.map((c, i) => ({
            ...c,
            key: `${i}-${c.description}`,
            billedText: money(c.billedAmount),
            owedText: money(c.patientResponsibility),
            // The PDF shows the out-of-pocket cap sentence once under the totals, not on every line.
            printNote: (c.howCalculated || '').replace(CAP_SENTENCE, '').trim(),
            rowClass: c.flaggedAsUnreasonable ? 'ledger-row flagged' : 'ledger-row',
            howTip: tipFor(c.howCalculated),
            hasHowTip: !!tipFor(c.howCalculated)
        }));

        // Bills pasted from a hospital portal come under headings (Pharmacy, Laboratory...).
        // Group those so a long bill is readable; a plain bill stays one flat list.
        // A bill with no headings at all is grouped by the service type each line matched to.
        const hasHeadings = lines.some((l) => l.category);
        const byName = new Map();
        lines.forEach((l) => {
            const name = hasHeadings ? (l.category || '') : (data.saved ? inferGroup(l.description) : (l.serviceType || 'Not matched'));
            if (!byName.has(name)) {
                byName.set(name, { key: name || 'all', name, billed: 0, owed: 0, lines: [] });
            }
            const g = byName.get(name);
            g.billed += l.billedAmount;
            g.owed += l.patientResponsibility;
            g.lines.push(l);
        });
        const named = byName.size > 1;
        const groups = Array.from(byName.values()).map((g) => ({
            ...g,
            name: g.name || (named ? 'Hospital charges' : ''),
            billedText: money(g.billed),
            owedText: money(g.owed),
            countLabel: `${g.lines.length} charge${g.lines.length === 1 ? '' : 's'}`
        }));
        const hasGroups = groups.length > 1 || (groups.length === 1 && groups[0].name !== '');

        const pending = ctx.pendingClaim || PENDING_CLAIM.test(ctx.billText || '');
        this.result = {
            ...data,
            insurancePaysText: money(data.insurancePays),
            deductibleAppliedText: money(data.deductibleApplied),
            hasDeductibleApplied: Number(data.deductibleApplied) > 0,
            networkAssumed: data.networkAssumed === true,
            pendingClaim: pending,
            hasUnmatched: lines.some((l) => l.serviceType === 'Not matched'),
            totalTip: 'Total billed: the full price the provider charged, before your insurance is applied.',
            insTip: 'Insurance pays: the part of the bill your plan is expected to cover. This is an estimate, and your insurer makes the final decision.',
            oweTip: 'You owe: what you are expected to pay yourself. It can include your deductible, a flat copay, and your share of costs after the deductible (coinsurance).',
            dedTip: 'Deductible: what you pay yourself each year before your insurance starts paying its share.',
            providerInitials: this.initialsOf(ctx.providerName),
            insPct: this.pctOf(data.insurancePays, data.totalBilled),
            owePct: 100 - this.pctOf(data.insurancePays, data.totalBilled),
            ringStyle: `stroke-dasharray:${100 - this.pctOf(data.insurancePays, data.totalBilled)} ${this.pctOf(data.insurancePays, data.totalBilled)};`,
            barInsStyle: `width:${this.pctOf(data.insurancePays, data.totalBilled)}%;background:#5CC28A;`,
            barOweStyle: `width:${100 - this.pctOf(data.insurancePays, data.totalBilled)}%;background:#E8A33D;`,
            providerNameText: (ctx.providerName || '').trim(),
            billNumberText: (ctx.billNumber || '').trim(),
            billDateText: this.prettyDate(ctx.billDate),
            hasProviderInfo: !!((ctx.providerName || '').trim() || (ctx.billNumber || '').trim() || ctx.billDate),
            hasNotices: pending || data.networkAssumed === true || lines.some((l) => l.serviceType === 'Not matched'),
            totalBilledText: money(data.totalBilled),
            totalOwedText: money(data.totalPatientResponsibility),
            charges: lines,
            hasFlagged: lines.some((l) => l.flaggedAsUnreasonable),
            capNote: (() => {
                const hit = lines.map((l) => (l.howCalculated || '').match(CAP_SENTENCE)).find((m) => m);
                return hit ? hit[0].trim() : '';
            })(),
            flaggedSummary: (() => {
                const n = lines.filter((l) => l.flaggedAsUnreasonable).length;
                return n === 1 ? '1 charge is priced above the typical rate.' : `${n} charges are priced above the typical rate.`;
            })(),
            groups,
            hasGroups,
            networkTip: /^(in|out-of)-network$/i.test(data.networkLabel || '') ? tipFor(data.networkLabel) : '',
            hasNetworkTip: /^(in|out-of)-network$/i.test(data.networkLabel || '')
        };

    }

    handleAnalyze() {
        this.errorMessage = '';

        if (!this.billText || !this.billText.trim()) {
            this.errorMessage = 'Please upload your bill, or enter at least one line item.';
            return;
        }

        if (!(this.billNumber || '').trim()) {
            this.errorMessage = 'Please enter the bill or account number printed on your bill.';
            return;
        }

        const dateProblem = this.billDateProblem(this.billDate);
        if (dateProblem) {
            this.errorMessage = dateProblem;
            return;
        }

        this.isSubmitting = true;
        this.startProgress();

        analyzeBill({
            providerName: this.providerName,
            billDate: this.billDate,
            billText: this.billText,
            doctorId: this.doctorId,
            billNumber: this.billNumber
        })
            .then((data) => {
                this.isSubmitting = false;
                this.stopProgress();
                this.buildResult(data, {
                    providerName: this.providerName,
                    billNumber: this.billNumber,
                    billDate: this.billDate,
                    billText: this.billText,
                    pendingClaim: this.pendingClaim
                });
            })
            .catch((error) => {
                this.isSubmitting = false;
                this.stopProgress();
                this.errorMessage = (error && error.body && error.body.message)
                    ? error.body.message
                    : 'Something went wrong analyzing your bill. Please try again.';
            });
    }

    // ---------- bill upload ----------
    // The file is turned into text by BillFileReader (Apex), which sends it to an OCR service.
    // Nothing is saved in Salesforce. The text then fills the line items box.
    async handleFileChange(event) {
        const input = event.target;
        const file = input.files && input.files[0];
        if (!file) {
            return;
        }
        this.errorMessage = '';
        this.uploadNote = '';

        const name = (file.name || '').toLowerCase();
        let mime = file.type;
        if (!mime) {
            mime = name.endsWith('.pdf') ? 'application/pdf'
                : name.endsWith('.png') ? 'image/png'
                : /\.jpe?g$/.test(name) ? 'image/jpeg' : '';
        }
        if (!['application/pdf', 'image/png', 'image/jpeg'].includes(mime)) {
            this.errorMessage = 'Please upload a PDF, PNG or JPG file.';
            input.value = null;
            return;
        }
        if (file.size > MAX_UPLOAD_BYTES) {
            this.errorMessage = 'That file is larger than 10 MB. Please upload a smaller one, or paste the line items instead.';
            input.value = null;
            return;
        }

        this.isReading = true;
        this.readingStatus = 'Reading your bill…';
        try {
            const prepared = await this.prepareFile(file, mime);
            const text = await readBill({ base64Data: prepared.base64, mimeType: prepared.mime });
            this.applyExtractedText(text);
        } catch (error) {
            console.error('CoverageChecker.handleFileChange - could not read file:', error);
            this.errorMessage = (error && error.body && error.body.message)
                ? error.body.message
                : (error && error.message)
                    ? error.message
                    : 'We could not read that file. You can paste the line items from your bill instead.';
        } finally {
            this.isReading = false;
            this.readingStatus = '';
            input.value = null;
        }
    }

    // Returns the file as base64. A big photo is scaled down first so it fits the size limit;
    // a PDF cannot be shrunk, so a PDF over the limit is turned away with a clear message.
    async prepareFile(file, mime) {
        if (file.size <= MAX_SEND_BYTES) {
            return { base64: await this.toBase64(file), mime };
        }
        if (mime === 'application/pdf') {
            throw new Error('That PDF is larger than 1 MB. Please upload a screenshot of the bill, or paste the line items instead.');
        }
        const small = await this.shrinkImage(file);
        return { base64: await this.toBase64(small), mime: 'image/jpeg' };
    }

    async shrinkImage(file) {
        const bitmap = await createImageBitmap(file);
        let side = 2000;
        let quality = 0.85;
        for (let attempt = 0; attempt < 5; attempt++) {
            const scale = Math.min(1, side / Math.max(bitmap.width, bitmap.height));
            const canvas = document.createElement('canvas');
            canvas.width = Math.round(bitmap.width * scale);
            canvas.height = Math.round(bitmap.height * scale);
            canvas.getContext('2d').drawImage(bitmap, 0, 0, canvas.width, canvas.height);
            // eslint-disable-next-line no-await-in-loop
            const blob = await new Promise((resolve) => canvas.toBlob(resolve, 'image/jpeg', quality));
            if (blob && blob.size <= MAX_SEND_BYTES) {
                return blob;
            }
            side = Math.round(side * 0.75);
            quality = Math.max(0.5, quality - 0.1);
        }
        throw new Error('That image is too large to read. Please upload a smaller screenshot, or paste the line items instead.');
    }

    toBase64(blob) {
        return new Promise((resolve, reject) => {
            const reader = new FileReader();
            reader.onload = () => resolve(String(reader.result).split(',')[1] || '');
            reader.onerror = () => reject(new Error('We could not open that file.'));
            reader.readAsDataURL(blob);
        });
    }

    // Turns the text read from the file into the line items box, a suggested doctor and a
    // bill date. The patient can still edit everything before analysing.
    applyExtractedText(raw) {
        // OCR often reads the $ sign as S, so put it back in front of amounts like S130.00
        const lines = (raw || '').split(/\r?\n/).map((l) => l.replace(/\s+/g, ' ').replace(/[S§](?=\d[\d,]*\.\d{2}\b)/g, '$').trim()).filter((l) => l.length > 0);
        if (lines.length === 0) {
            this.errorMessage = 'We could not find any text in that file. You can paste the line items from your bill instead.';
            return;
        }

        this.pendingClaim = lines.some((l) => PENDING_CLAIM.test(l));
        if (!this.billNumber) {
            for (const l of lines) {
                const m = l.match(BILL_NUMBER);
                if (m) { this.billNumber = m[1]; break; }
            }
        }
        const providerName = this.findProviderName(lines);
        const facilityName = this.findFacilityName(lines);
        const foundDate = this.findBillDate(lines);
        const kept = lines
            .filter((l) => !SKIP_LINE.test(l) && !HEADER_LINE.test(l))
            .map((l) => this.tidyChargeLine(l));
        if (kept.length === 0) {
            this.errorMessage = 'We could not find any charges in that file. You can paste the line items from your bill instead.';
            return;
        }
        this.billText = kept.join('\n');
        this.showManualEntry = true; // show the text we read so the patient can check it

        let note = (this.uploadNote || '') + 'We read your bill. To check or fix any line, open the "Type line items" tab.';
        if (foundDate && !this.billDate) {
            this.billDate = foundDate;
            note += ' We filled in the bill date from the file.';
        }
        if (facilityName && !this.providerName) {
            this.providerName = facilityName;
            note += ' We filled in the provider / practice name from the file.';
        }
        this.uploadNote = note;

        if ((providerName || facilityName) && !this.doctorId) {
            this.matchProvider(providerName, facilityName);
        }
    }

    // Printed statement rows read "10/04/2026 99283 Emergency Department Visit $780.00" (a date, a
    // CPT code, the description and the amount). Put the code next to the amount the way the
    // bill parser expects, so the code is used to find the service type. Single stray capital
    // letters before the amount (a watermark read as text) are removed.
    tidyChargeLine(line) {
        // A stray symbol the reader picked up (for example "Urinalysis <") is not part of the name.
        line = line.replace(/\s+[<>|~_]+(?=\s+(?:\d{5}\s+)?\$?[\d,]+\.\d{2}$)/, '');
        const row = line.match(/^\d{1,2}\/\d{1,2}\/\d{2,4}\s+(\d{5})\s+(.+?)(?:\s+\d{1,3})?\s+\$?([\d,]+\.\d{2})$/);
        if (!row) {
            return line;
        }
        const description = row[2].replace(/\s+[A-Z]$/, '').replace(/\s*[<>|~_]+$/, '').trim();
        return `${description}   ${row[1]}   $${row[3]}`;
    }

    // Looks for "Provider: Jeffrey M. Wilson, MD" style lines, then "Dr. Name".
    findProviderName(lines) {
        const labelled = /(?:rendering\s+)?(?:provider|physician|doctor)\s*:\s*(.+?)(?=\s{2,}|\s+(?:date|dos|npi|acct|account|patient)\b|$)/i;
        for (const l of lines) {
            const m = l.match(labelled);
            if (m) {
                const cleaned = this.cleanDoctorName(m[1]);
                if (cleaned) {
                    return cleaned;
                }
            }
        }
        for (const l of lines) {
            const m = l.match(/\bDr\.?\s+([A-Z][A-Za-z'-]+(?:\s+[A-Z]\.)?(?:\s+[A-Z][A-Za-z'-]+)?)/);
            if (m) {
                const cleaned = this.cleanDoctorName(m[1]);
                if (cleaned) {
                    return cleaned;
                }
            }
        }
        return null;
    }

    cleanDoctorName(value) {
        const name = (value || '')
            .replace(/,?\s*\b(MD|DO|DPM|DDS|DMD|DC|PhD|NP|PA-C|PA|FACS|FACOG|MPH|MBA)\b\.?/gi, '')
            .replace(/[^A-Za-z.'\- ]/g, ' ')
            .replace(/\s+/g, ' ')
            .trim();
        // A specialty, department or facility is not a doctor ("Attending: Emergency Medicine").
        if (/\b(medicine|department|services|hospital|center|clinic|surgery|radiology|laboratory|emergency|unit|billing)\b/i.test(name)) {
            return null;
        }
        return name.length >= 3 ? name : null;
    }

    // Finds the hospital or practice name, usually the first line of the bill, e.g.
    // "Quidnick Valley Medical Center PATIENT STATEMENT" gives "Quidnick Valley Medical Center".
    findFacilityName(lines) {
        const facility = /^(.*?\b(?:Hospital|Medical Center|Medical Group|Medical Associates|Health System|Healthcare|Health Center|Clinic|Urgent Care|Family Medicine|Physicians|Associates|Center))\b/i;
        for (const l of lines.slice(0, 8)) {
            const m = l.match(facility);
            if (m) {
                const name = m[1].replace(/[^A-Za-z0-9&.,'\- ]/g, ' ').replace(/\s+/g, ' ').trim();
                if (name.length >= 5 && name.length <= 80 && !/\d{3}[-) ]/.test(name) && !/\b(patient|statement|account)\b/i.test(name)) {
                    return name;
                }
            }
        }
        return null;
    }

    // Finds the date of the visit as YYYY-MM-DD. Tries, in order: a "Date of service" label,
    // the date at the start of the charge rows, then a statement or bill date. Only a usable
    // date (not in the future, not too old) is returned.
    findBillDate(lines) {
        const datePart = '(\\d{1,2}\\/\\d{1,2}\\/\\d{2,4}|\\d{4}-\\d{2}-\\d{2})';
        const service = new RegExp('(?:date\\s+of\\s+service|service\\s+date|\\bdos)\\s*[:\\-]?\\s*' + datePart, 'i');
        const row = new RegExp('^' + datePart + '\\s+(?:[A-Z]?\\d{4,5}[A-Z]?\\s+)?[A-Za-z]');
        const other = new RegExp('(?:statement\\s+date|bill\\s+date)\\s*[:\\-]?\\s*' + datePart, 'i');
        for (const pattern of [service, row, other]) {
            for (const l of lines) {
                const m = l.match(pattern);
                const iso = m ? this.toIsoDate(m[1]) : null;
                if (iso && !this.billDateProblem(iso)) {
                    return iso;
                }
            }
        }
        return null;
    }

    toIsoDate(text) {
        let iso = null;
        if (text.includes('-')) {
            iso = text;
        } else {
            const [mm, dd, yy] = text.split('/');
            const year = yy.length === 2 ? `20${yy}` : yy;
            iso = `${year}-${mm.padStart(2, '0')}-${dd.padStart(2, '0')}`;
        }
        return Number.isNaN(Date.parse(iso)) ? null : iso;
    }

    // Looks up the provider on the bill in the doctor list, so the result can show whether
    // they are in or out of your network. Tries the doctor's name first, then the hospital or
    // practice name. A single match is selected for the patient; several are offered to pick from.
    async matchProvider(doctorName, facilityName) {
        try {
            if (doctorName) {
                const rows = await this.searchForDoctor(doctorName);
                if (rows.length > 0) {
                    this.applyDoctorMatches(rows, doctorName);
                    return;
                }
            }
            if (facilityName) {
                const rows = await this.searchForFacility(facilityName);
                this.applyDoctorMatches(rows, facilityName, true);
                return;
            }
            this.applyDoctorMatches([], doctorName);
        } catch (error) {
            console.error('CoverageChecker.matchProvider - could not look up the provider:', error);
            this.doctorOptions = [];
        }
    }

    // Searches the doctor list with each term in turn and returns the first non-empty result.
    async searchFirst(terms) {
        for (const term of terms) {
            if (term && term.trim().length >= 2) {
                // eslint-disable-next-line no-await-in-loop
                const rows = await searchDoctors({ term: term.trim() });
                if (rows.length > 0) {
                    return rows;
                }
            }
        }
        return [];
    }

    // Searches by last name (names in the list may include a middle name), then narrows by first name.
    async searchForDoctor(name) {
        const words = name.split(' ').filter((w) => w.replace(/[.]/g, '').length > 1);
        const lastName = words.length ? words[words.length - 1] : name;
        let rows = await this.searchFirst([lastName]);
        if (rows.length > 1 && words.length > 1) {
            const first = words[0].toLowerCase();
            const narrowed = rows.filter((r) => r.label.toLowerCase().includes(first));
            if (narrowed.length > 0) {
                rows = narrowed;
            }
        }
        return rows;
    }

    // Searches the full facility name, then the name without words like "Hospital", then its first word.
    async searchForFacility(name) {
        const generic = /\b(hospital|medical center|medical group|medical associates|health system|healthcare|health center|clinic|urgent care|family medicine|physicians|associates|center|inc|llc)\b/gi;
        const core = name.replace(generic, ' ').replace(/\s+/g, ' ').trim();
        const firstWord = core.split(' ')[0];
        return this.searchFirst([name, core, firstWord && firstWord.length >= 5 ? firstWord : '']);
    }

    applyDoctorMatches(rows, foundName, isFacility = false) {
        this.doctorOptions = [];
        this.noDoctorMatch = false;
        // A hospital name is not a doctor: when it matches nothing, leave the doctor box empty.
        this.doctorSearch = isFacility && rows.length === 0 ? '' : foundName;
        if (rows.length === 1) {
            this.doctorId = rows[0].value;
            this.doctorLabel = rows[0].label;
            this.doctorSearch = rows[0].label;
            this.uploadNote += ` We matched "${foundName}" on the bill to ${rows[0].label}. The result will show whether they are in your network. Change the doctor below if this is not right.`;
        } else if (rows.length > 1) {
            this.doctorOptions = rows;
            this.uploadNote += ` We found "${foundName}" on the bill. Pick the matching provider below so we can check whether they are in your network.`;
        } else if (isFacility) {
            this.uploadNote += ' This bill does not name a doctor, so we cannot check your network. In-network is assumed. You can choose a doctor below if you know who treated you.';
        } else {
            this.uploadNote += ` We found "${foundName}" on the bill but it is not in our provider list, so we cannot check whether it is in your network. In-network is assumed.`;
        }
    }

    // ---- BUG-32: "i" icons. One floating tooltip (position:fixed) so nothing can clip it.
    tipBoxText = '';
    tipBoxStyle = '';

    get tipVisible() {
        return !!this.tipBoxText;
    }

    showTip(el) {
        const text = el.dataset.text;
        if (!text) return;
        const r = el.getBoundingClientRect();
        const width = 250;
        const left = Math.max(12, Math.min(r.left + r.width / 2 - width / 2, window.innerWidth - width - 12));
        const below = r.bottom + 8;
        const flip = below + 140 > window.innerHeight;
        const top = flip ? r.top - 8 : below;
        this.tipBoxText = text;
        this.tipBoxStyle = `position:fixed;z-index:9999;top:${top}px;left:${left}px;width:${width}px;box-sizing:border-box;`
            + 'background:#16213E;color:#FBF8F3;font-size:13px;line-height:1.45;font-weight:400;font-family:"Segoe UI",Arial,sans-serif;overflow-wrap:break-word;'
            + 'padding:10px 12px;border-radius:10px;box-shadow:0 6px 18px rgba(22,33,62,.3);text-align:left;white-space:normal;'
            + 'pointer-events:none;' + (flip ? 'transform:translateY(-100%);' : '');
    }
    handleTipOn(event) {
        this.showTip(event.currentTarget);
    }
    handleTipOff() {
        this.tipBoxText = '';
    }
    handleTipToggle(event) {
        event.stopPropagation();
        if (this.tipBoxText && this.tipBoxText === event.currentTarget.dataset.text) {
            this.tipBoxText = '';
        } else {
            this.showTip(event.currentTarget);
        }
    }
    handleTipKey(event) {
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            this.handleTipToggle(event);
        }
    }

    // Back from the result to the upload form. What the patient entered is kept, so they can fix it and run again.
    // ---- Dispute help: a letter and phone script for charges flagged as above the typical rate ----
    showDispute = false;
    copyMessage = '';

    get disputeButtonLabel() {
        return this.showDispute ? 'Hide letter' : 'Get dispute letter';
    }

    // A native textarea does not take its text from a template binding, so the letter is set on it directly.
    renderedCallback() {
        if (!this.showDispute) return;
        const area = this.template.querySelector('.dispute-letter');
        const text = this.disputeLetter;
        if (area && area.value !== text) {
            area.value = text;
        }
    }

    toggleDispute() {
        this.showDispute = !this.showDispute;
        this.copyMessage = '';
    }

    get disputeLetter() {
        const r = this.result;
        if (!r) return '';
        const today = new Date().toLocaleDateString('en-US', { year: 'numeric', month: 'long', day: 'numeric' });
        const provider = r.providerNameText || 'the provider';
        const refs = [];
        if (r.billNumberText) refs.push(`bill number ${r.billNumberText}`);
        if (r.billDateText) refs.push(`dated ${r.billDateText}`);
        const ref = refs.length ? ` (${refs.join(', ')})` : '';
        const items = (r.charges || [])
            .filter((c) => c.flaggedAsUnreasonable)
            .map((c) => `  - ${c.description}: ${c.billedText}`)
            .join('\n');
        return [
            today,
            '',
            `To: Billing Department, ${provider}`,
            `Re: Request to review charges on my bill${ref}`,
            '',
            'Hello,',
            '',
            'I am writing about the bill above. When I compared it with typical prices, these charges looked higher than expected:',
            '',
            items,
            '',
            'Please:',
            '  1. Review these charges and tell me whether the prices and billing codes are correct, and whether anything was billed twice.',
            '  2. Confirm that the claim was sent to my insurance and whether any adjustments apply.',
            '  3. Tell me whether a prompt-pay discount or financial assistance is available.',
            '',
            'Please hold the disputed amount from collections while this is reviewed.',
            '',
            'Thank you,',
            '[Your name]',
            '[Your phone or email]',
            '[Your member ID]'
        ].join('\n');
    }

    copyLetter() {
        const text = this.disputeLetter;
        const done = () => {
            this.copyMessage = 'Copied. Paste it into an email or print it.';
        };
        const fallback = () => {
            const area = this.template.querySelector('.dispute-letter');
            if (area) {
                area.focus();
                area.select();
                try {
                    document.execCommand('copy');
                    done();
                    return;
                } catch (e) {
                    // fall through
                }
            }
            this.copyMessage = 'Select the text above and copy it.';
        };
        if (navigator.clipboard && navigator.clipboard.writeText) {
            navigator.clipboard.writeText(text).then(done, fallback);
        } else {
            fallback();
        }
    }

    get printDate() {
        return new Date().toLocaleDateString('en-US', { year: 'numeric', month: 'long', day: 'numeric' });
    }

    // Opens the browser's print dialog; the user picks "Save as PDF". Collapsed groups are opened first so they print.
    handlePrint() {
        const closed = Array.from(this.template.querySelectorAll('details:not([open])'));
        closed.forEach((d) => { d.open = true; });
        const restore = () => { closed.forEach((d) => { d.open = false; }); };
        try {
            window.addEventListener('afterprint', restore, { once: true });
            window.print();
        } catch (e) {
            restore();
        }
    }

    handleBack() {
        if (this.openedFromDashboard) {
            window.location.href = '/coveragechecker/';
            return;
        }
        this.result = undefined;
        this.showDispute = false;
        this.copyMessage = '';
        this.tipBoxText = '';
        this.errorMessage = '';
    }

    handleGoHome() {
        window.location.href = '/coveragechecker/';
    }

    initialsOf(name) {
        const words = (name || '').replace(/[^A-Za-z\s]/g, ' ').split(/\s+/).filter((w) => w.length > 0);
        return words.slice(0, 2).map((w) => w[0].toUpperCase()).join('') || '+';
    }

    pctOf(part, whole) {
        const w = Number(whole);
        if (!w) { return 0; }
        return Math.max(0, Math.min(100, Math.round((Number(part) / w) * 100)));
    }

    // "2026-10-04" -> "Oct 4, 2026" (no time-zone shift).
    prettyDate(value) {
        const m = /^(\d{4})-(\d{2})-(\d{2})$/.exec(value || '');
        if (!m) { return ''; }
        const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
        return `${months[Number(m[2]) - 1]} ${Number(m[3])}, ${m[1]}`;
    }

    handleReset() {
        this.result = undefined;
        this.tipBoxText = '';
        this.providerName = '';
        this.billDate = '';
        this.billText = '';
        this.doctorSearch = '';
        this.doctorOptions = [];
        this.doctorId = '';
        this.doctorLabel = '';
        this.errorMessage = '';
        this.uploadNote = '';
        this.readingStatus = '';
        this.showManualEntry = false;
        this.tab = 'upload';
        this.pendingClaim = false;
        this.billNumber = '';
    }
}
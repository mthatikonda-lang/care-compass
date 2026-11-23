import { LightningElement, wire } from 'lwc';
import getCurrentPatient from '@salesforce/apex/PatientHomeController.getCurrentPatient';
import getDoctorCities from '@salesforce/apex/CareFinderController.getDoctorCities';
import getSuggestedDoctors from '@salesforce/apex/CareFinderController.getSuggestedDoctorsNear';
import confirmBookingWithIssue from '@salesforce/apex/CareFinderController.confirmBookingWithIssue';
import checkOpenRequest from '@salesforce/apex/BookingCheckController.checkOpenRequest';
import requestEstimate from '@salesforce/apex/EstimateRequestController.requestEstimate';

const PROCEDURE_TYPES = [
    'Office Visit',
    'Specialist Visit',
    'Preventive / Immunization',
    'Lab Test',
    'Imaging',
    'Advanced Imaging',
    'Emergency Room',
    'Outpatient Procedure',
    'Surgery / Hospital Stay',
    'Physical Therapy',
    'Mental Health Visit',
    'DME / Other',
    'Prescription / Drug'
];

const DENTAL_TYPES = [
    'Dental Exam',
    'Dental X-rays',
    'Dental Cleaning',
    'Dental Filling',
    'Dental Extraction',
    'Dental Root Canal',
    'Dental Crown'
];

const DISTANCE_OPTIONS = [
    { label: 'Within 5 miles', value: '5' },
    { label: 'Within 10 miles', value: '10' },
    { label: 'Within 25 miles', value: '25' },
    { label: 'Within 50 miles', value: '50' },
    { label: 'Any distance', value: '0' }
];

const PAGE_SIZE = 10;

// BUG-32: plain-language meanings shown by the small "i" icons.
const TIP_TEXT = {
    in: 'In-network: this doctor has an agreement with your insurance, so you usually pay less.',
    out: 'Out-of-network: no agreement with your insurance, so you may pay more, up to the full price.',
    deductible: 'Deductible: what you pay yourself each year before your insurance starts paying its share.',
    copay: 'Copay: a fixed amount you pay for a visit.',
    coinsurance: 'Coinsurance: your share, as a percentage, of costs after the deductible.'
};

// True when the practice name is really just the doctor's own name
// (for example "Christina Dicomes DMD" and "Christina D. Dicomes, DMD"),
// so the screen doesn't show the same name twice.
function isSamePerson(providerName, doctorName) {
    const words = (s) =>
        (s || '')
            .toLowerCase()
            .replace(/[^a-z\s]/g, ' ')
            .split(/\s+/)
            .filter((w) => w.length > 1);
    const p = words(providerName);
    const d = words(doctorName);
    return p.length > 0 && d.length > 0 && p.every((w) => d.includes(w));
}

export default class BookAppointment extends LightningElement {
    patientId;
    step = 'issue';
    procedureTypes = PROCEDURE_TYPES;

    issueText;
    preferredCity = '';
    zipCode = '';
    distance = '25';
    distanceOptions = DISTANCE_OPTIONS;
    allDoctors = [];
    visibleCount = PAGE_SIZE;
    selectedDoctor;
    selectedProcedureType = 'Office Visit';
    appointmentDate;

    estimateResult;
    isSubmitting = false;
    errorMessage;
    duplicateWarning = '';

    @wire(getCurrentPatient)
    wiredPatient({ data, error }) {
        if (data) {
            this.patientId = data.Id;
        } else if (error) {
            this.errorMessage = 'Could not load your patient profile.';
        }
    }

    // ---- BUG-32: "i" icons. One floating tooltip (position:fixed) so no card or badge can clip it.
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
        const flip = below + 120 > window.innerHeight;
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
        // The icon can sit inside a card button, so a tap must not pick the doctor.
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

    get tipEstNetworkText() {
        return this.estimateResult && this.estimateResult.inNetwork ? TIP_TEXT.in : TIP_TEXT.out;
    }
    get tipDeductibleText() { return TIP_TEXT.deductible; }
    get tipCopayText() { return TIP_TEXT.copay; }
    get tipCoinsText() { return TIP_TEXT.coinsurance; }

    // BUG-28: filter the matched doctors by name and by network status (done in the browser).
    nameFilter = '';
    networkFilter = 'all';

    networkFilterOptions = [
        { value: 'all', label: 'All' },
        { value: 'In-Network', label: 'In-Network' },
        { value: 'Out-of-Network', label: 'Out-of-Network' }
    ];

    // Pill buttons: the chosen one is filled navy, the others are outlined.
    get networkPills() {
        const base = 'padding:8px 16px;font-size:14px;font-weight:600;border-radius:999px;cursor:pointer;';
        return this.networkFilterOptions.map((o) => ({
            value: o.value,
            label: o.label,
            style: o.value === this.networkFilter
                ? base + 'background:#16213E;color:#FBF8F3;border:1px solid #16213E;'
                : base + 'background:#fff;color:#2B3340;border:1px solid #E4DED2;'
        }));
    }

    // Sort the matched doctors. "Best match" keeps the order the search returned them in.
    sortMode = 'match';

    sortOptions = [
        { value: 'match', label: 'Best match' },
        { value: 'price', label: 'Lowest price' },
        { value: 'distance', label: 'Nearest' }
    ];

    get sortPills() {
        const base = 'padding:6px 14px;font-size:13px;font-weight:600;border-radius:999px;cursor:pointer;';
        return this.sortOptions.map((o) => ({
            value: o.value,
            label: o.label,
            style: o.value === this.sortMode
                ? base + 'background:#E8A33D;color:#16213E;border:1px solid #E8A33D;'
                : base + 'background:#fff;color:#2B3340;border:1px solid #E4DED2;'
        }));
    }

    handleSortPill(event) {
        this.sortMode = event.currentTarget.dataset.value;
        this.visibleCount = PAGE_SIZE;
    }

    handleNetworkPill(event) {
        this.networkFilter = event.currentTarget.dataset.value;
        this.visibleCount = PAGE_SIZE;
    }

    // One or two letters match the START of any word in the name ("m" finds Marcaccio and
    // Mark, not every name with an m inside). Three or more letters match anywhere in the name.
    nameMatches(name, term) {
        const lower = (name || '').toLowerCase();
        if (term.length >= 3) {
            return lower.includes(term);
        }
        return lower.split(/[\s,.\-]+/).some((word) => word.startsWith(term));
    }

    get filteredDoctors() {
        const term = (this.nameFilter || '').trim().toLowerCase();
        const list = this.allDoctors.filter((d) => {
            if (term && !this.nameMatches(d.doctorName, term)) return false;
            if (this.networkFilter !== 'all' && d.networkStatus !== this.networkFilter) return false;
            return true;
        });
        if (this.sortMode === 'price') {
            // Doctors without a price go last.
            return [...list].sort((a, b) => {
                const pa = a.estimatedCost == null ? Infinity : a.estimatedCost;
                const pb = b.estimatedCost == null ? Infinity : b.estimatedCost;
                return pa - pb;
            });
        }
        if (this.sortMode === 'distance') {
            // Doctors without a distance (no ZIP given) go last.
            return [...list].sort((a, b) => {
                const da = a.distanceMiles == null ? Infinity : a.distanceMiles;
                const db = b.distanceMiles == null ? Infinity : b.distanceMiles;
                return da - db;
            });
        }
        return list;
    }
    get visibleDoctors() {
        return this.filteredDoctors.slice(0, this.visibleCount).map((d) => {
            return {
                ...d,
                tipText: d.networkStatus === 'In-Network' ? TIP_TEXT.in : TIP_TEXT.out
            };
        });
    }
    get hasMoreDoctors() {
        return this.filteredDoctors.length > this.visibleCount;
    }
    get noFilteredDoctors() {
        return this.allDoctors.length > 0 && this.filteredDoctors.length === 0;
    }
    get doctorCountLabel() {
        const total = this.filteredDoctors.length;
        const shown = Math.min(this.visibleCount, total);
        return `Showing ${shown} of ${total} doctors`;
    }
    get showMoreLabel() {
        const remaining = this.filteredDoctors.length - this.visibleCount;
        return `Show ${Math.min(PAGE_SIZE, remaining)} more`;
    }

    handleNameFilter(event) {
        this.nameFilter = event.target.value || '';
        this.visibleCount = PAGE_SIZE;
    }

    handleNetworkFilter(event) {
        this.networkFilter = event.target.value;
        this.visibleCount = PAGE_SIZE;
    }

    get showEmergencyNotice() {
        return this.allDoctors.length > 0 && this.allDoctors[0].emergencyFlag === true;
    }

    // Dental procedure types are offered only to patients on a dental plan.
    get isDentist() {
        return !!(this.selectedDoctor && this.selectedDoctor.dentalPlan);
    }

    // The visit type is set automatically from the doctor and is not chosen by the patient.
    get procedureLabel() {
        return this.selectedProcedureType;
    }

    handleShowMore() {
        this.visibleCount += PAGE_SIZE;
    }

    get isIssueStep() { return this.step === 'issue'; }
    get isDoctorStep() { return this.step === 'doctor'; }
    get isDetailsStep() { return this.step === 'details'; }
    get isConfirmStep() { return this.step === 'confirm'; }
    get isRequestedStep() { return this.step === 'requested'; }

    handleIssueChange(event) {
        this.issueText = event.target.value;
    }

    // Cities that have doctors, for the "Preferred area" drop-down.
    cityList = [];

    @wire(getDoctorCities)
    wiredCities({ data }) {
        if (data) {
            this.cityList = data;
        }
    }

    get cityOptions() {
        return [{ value: '', label: 'Any area', selected: !this.preferredCity }].concat(
            this.cityList.map((c) => ({ value: c, label: c, selected: c === this.preferredCity }))
        );
    }

    handleCityChange(event) {
        this.preferredCity = (event.target.value || '').trim();
    }

    handleZipChange(event) {
        this.zipCode = (event.target.value || '').trim();
    }

    handleDistanceChange(event) {
        this.distance = event.target.value;
    }

    // The distance choice shows only once there is a ZIP code.
    get showDistance() {
        return !!this.zipCode;
    }

    get distanceSelectOptions() {
        return this.distanceOptions.map((o) => ({ ...o, selected: o.value === this.distance }));
    }

    async handleFindDoctors() {
        this.errorMessage = null;
        const typed = (this.issueText || '').trim();
        if (!typed) {
            this.errorMessage = 'Please tell us what the issue is. This is required, for example "knee pain" or "skin rash".';
            return;
        }
        if (!/[a-z]{3,}/i.test(typed)) {
            this.errorMessage = 'That doesn\u2019t look like a medical concern. Please re-enter what\u2019s going on, for example "knee pain" or "skin rash".';
            return;
        }
        if (this.zipCode && !/^\d{5}$/.test(this.zipCode)) {
            this.errorMessage = 'Please enter a 5-digit ZIP code, for example 02865.';
            return;
        }
        this.isSubmitting = true;
        try {
            const results = await getSuggestedDoctors({
                issueText: typed,
                preferredCity: this.preferredCity || null,
                zipCode: this.zipCode || null,
                miles: this.zipCode ? Number(this.distance) : null
            });
            if (!results || results.length === 0) {
                this.errorMessage = 'We couldn’t match that to a medical concern. Please re-enter what’s going on, for example "knee pain", "skin rash" or "headache".';
                return;
            }
            this.visibleCount = PAGE_SIZE;
            this.nameFilter = '';
            this.networkFilter = 'all';
            this.sortMode = 'match';
            this.allDoctors = results.map((d) => ({
                ...d,
                cardClass: d.isSuggested ? 'doctor-card doctor-card-suggested' : 'doctor-card',
                badgeLabel: d.isSuggested ? 'Suggested for you' : null,
                locationLabel: d.matchesLocation ? 'Near you' : null,
                metaLine: [
                    isSamePerson(d.providerName, d.doctorName) ? null : d.providerName,
                    d.specialty,
                    d.city,
                    d.distanceMiles != null ? `about ${d.distanceMiles} mi away` : null
                ]
                    .filter(Boolean)
                    .join(' \u00B7 '),
                // One price per card. The detail is in the "i": where the number comes from.
                priceLabel: d.estimatedCost != null ? `Est. $${d.estimatedCost.toFixed(2)}` : null,
                priceTip: d.estimatedCost == null ? '' : (
                    d.priceSource === 'Typical price'
                        ? 'No price on file for this doctor, so this is the typical price for this kind of visit.'
                        : (d.feeOnly
                            ? `This is the doctor's fee only.${d.typicalCost != null ? ` The typical price for this kind of visit is $${d.typicalCost.toFixed(2)}.` : ''} Facility charges are billed separately.`
                            : (d.networkStatus === 'Out-of-Network'
                                ? 'Based on the average this doctor bills for this kind of visit. Out of network, you may owe more.'
                                : "Based on this doctor's average allowed amount for this kind of visit. Your plan and deductible decide what you pay."))),
                networkLabel: d.networkStatus === 'Unknown' ? null : d.networkStatus,
                networkBadgeClass: d.networkStatus === 'In-Network' ? 'badge badge-network-in' : 'badge badge-network-out'
            }));
            this.step = 'doctor';
        } catch (e) {
            console.log(e);
            this.errorMessage = (e && e.body && e.body.message) || 'Could not load doctors.';
        } finally {
            this.isSubmitting = false;
        }
    }

    handleSelectDoctor(event) {
        const doctorId = event.currentTarget.dataset.id;
        this.selectedDoctor = this.allDoctors.find((d) => d.doctorId === doctorId);
        this.selectedProcedureType = this.isDentist
            ? 'Dental Exam'
            : (this.selectedDoctor && this.selectedDoctor.defaultProcedureType) || 'Office Visit';
        this.step = 'details';
    }

    // The Back pill in the banner: one step back inside the flow.
    get showStepBack() {
        return this.step === 'doctor' || this.step === 'details' || this.step === 'confirm';
    }

    handleStepBack() {
        if (this.step === 'doctor') {
            this.handleBackToIssue();
        } else if (this.step === 'details') {
            this.handleBackToDoctors();
        } else if (this.step === 'confirm') {
            this.handleBackToDetails();
        }
    }

    handleBackToIssue() {
        this.step = 'issue';
        this.errorMessage = null;
    }

    handleProcedureChange(event) {
        this.selectedProcedureType = event.target.value;
    }

    handleDateChange(event) {
        this.appointmentDate = event.target.value;
    }

    // Today's date in the patient's own time zone, as yyyy-mm-dd. Earlier dates are not allowed.
    get minDate() {
        const t = new Date();
        const pad = (n) => String(n).padStart(2, '0');
        return `${t.getFullYear()}-${pad(t.getMonth() + 1)}-${pad(t.getDate())}`;
    }

    get detailsSubmitDisabled() {
        return !this.appointmentDate || this.isSubmitting;
    }

    async handleGetEstimate() {
        this.errorMessage = null;
        if (this.appointmentDate && this.appointmentDate < this.minDate) {
            this.errorMessage = 'Preferred date can\u2019t be in the past. Please choose today or a later date.';
            return;
        }
        this.isSubmitting = true;
        try {
            const res = await requestEstimate({
                patientId: this.patientId,
                providerId: this.selectedDoctor.providerId,
                doctorId: this.selectedDoctor.doctorId,
                procedureType: this.selectedProcedureType,
                appointmentDate: this.appointmentDate
            });
            this.estimateResult = {
                ...res,
                costDisplay: res.estimatedPatientCost != null ? res.estimatedPatientCost.toFixed(2) : '0.00',
                benchmarkDisplay: res.benchmarkCost != null ? res.benchmarkCost.toFixed(2) : '0.00',
                hasEstimate: !res.noEstimateMessage,
                headerLine: isSamePerson(res.providerName, res.doctorName)
                    ? res.doctorName
                    : `${res.providerName} \u00B7 ${res.doctorName}`,
                serviceLine: res.planName
                    ? `${res.procedureType} \u00B7 ${res.planName}`
                    : res.procedureType,
                showNetwork: res.inNetwork === true || res.inNetwork === false,
                // BUG-32: one line saying how the cost was worked out (only when we are sure).
                calcKind: this.calcKindFor(res),
                notDental: !res.extraNote,
                isTypicalPrice: !!res.priceSource && res.priceSource.startsWith('Typical'),
                networkLabel: res.inNetwork ? 'In-network' : 'Out-of-network',
                networkClass: res.inNetwork ? 'badge badge-network-in' : 'badge badge-network-out'
            };
            this.duplicateWarning = '';
            try {
                const dup = await checkOpenRequest({ doctorId: this.selectedDoctor.doctorId });
                if (dup && dup.hasOpenRequest) {
                    const when = dup.dateText ? ` for ${dup.dateText}` : '';
                    this.duplicateWarning = dup.status === 'Confirmed'
                        ? `You already have a confirmed appointment with this doctor${when}. You can still send another request if you need one.`
                        : `You already have an open callback request with this doctor${when}. You can still send another request if you need one.`;
                }
            } catch (dupErr) {
                console.log(dupErr);
            }
            this.step = 'confirm';
        } catch (e) {
            console.log(e);
            this.errorMessage = (e && e.body && e.body.message) || 'Something went wrong getting your estimate.';
        } finally {
            this.isSubmitting = false;
        }
    }

    // Which "how this was calculated" line applies. Empty string = show nothing.
    //   outofnetwork, covered, deductible, copay
    calcKindFor(res) {
        if (res.noEstimateMessage || res.extraNote) return '';
        if (res.inNetwork === false) return 'outofnetwork';
        if (res.inNetwork === true && Number(res.estimatedPatientCost) === 0) return 'covered';
        if (res.showDeductibleNote) return 'deductible';
        // costSharingMethod is sent by EstimateRequestController when it is available.
        if (res.costSharingMethod === 'Flat Copay') return 'copay';
        return '';
    }

    get calcOutOfNetwork() { return this.estimateResult && this.estimateResult.calcKind === 'outofnetwork'; }
    get calcCovered() { return this.estimateResult && this.estimateResult.calcKind === 'covered'; }
    get calcDeductible() { return this.estimateResult && this.estimateResult.calcKind === 'deductible'; }
    get calcCopay() { return this.estimateResult && this.estimateResult.calcKind === 'copay'; }

    handleBackToDetails() {
        this.duplicateWarning = '';
        this.step = 'details';
        this.errorMessage = null;
    }

    async handleConfirmBooking() {
        this.errorMessage = null;
        this.isSubmitting = true;
        try {
            const result = await confirmBookingWithIssue({
                appointmentId: this.estimateResult.appointmentId,
                issueText: (this.issueText || '').trim() || null
            });
            if (!result.success) {
                this.errorMessage = result.message;
                return;
            }
            this.step = 'requested';
        } catch (e) {
            console.log(e);
            this.errorMessage = (e && e.body && e.body.message) || 'Could not send the callback request.';
        } finally {
            this.isSubmitting = false;
        }
    }

    handleBackToDoctors() {
        this.step = 'doctor';
        this.errorMessage = null;
    }

    handleStartOver() {
        this.step = 'issue';
        this.issueText = undefined;
        this.preferredCity = '';
        this.zipCode = '';
        this.distance = '25';
        this.allDoctors = [];
        this.nameFilter = '';
        this.networkFilter = 'all';
        this.visibleCount = PAGE_SIZE;
        this.selectedDoctor = undefined;
        this.selectedProcedureType = 'Office Visit';
        this.appointmentDate = undefined;
        this.estimateResult = undefined;
        this.tipBoxText = '';
        this.errorMessage = null;
    }

    handleGoHome() {
        window.location.href = '/coveragechecker/';
    }
}
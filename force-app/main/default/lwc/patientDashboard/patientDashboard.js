import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getDashboard from '@salesforce/apex/PatientDashboardController.getDashboard';
import confirmAppointment from '@salesforce/apex/PatientDashboardController.confirmAppointment';

const LIST_LIMIT = 3;
const MONTHS = ['JAN', 'FEB', 'MAR', 'APR', 'MAY', 'JUN', 'JUL', 'AUG', 'SEP', 'OCT', 'NOV', 'DEC'];
const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

function money(value) {
    const n = Number(value || 0);
    const whole = Math.abs(n % 1) < 0.005;
    return new Intl.NumberFormat('en-US', {
        style: 'currency',
        currency: 'USD',
        minimumFractionDigits: whole ? 0 : 2,
        maximumFractionDigits: whole ? 0 : 2
    }).format(n);
}

function clampPct(value) {
    return Math.max(0, Math.min(100, Math.round(value)));
}

// Apex Date arrives as "YYYY-MM-DD"; parse it locally so the day never shifts
function parseDate(value) {
    if (!value) return null;
    const [y, m, d] = value.split('-').map(Number);
    return new Date(y, m - 1, d);
}

export default class PatientDashboard extends LightningElement {
    // Old properties kept so the component can be deployed while it's on a published page. Not used.
    @api findCarePage;
    @api checkBillPage;
    @api profilePage;

    @api findCareUrl = '/coveragechecker/book-appointment';
    @api checkBillUrl = '/coveragechecker/coverage-checker';
    @api profileUrl = '/coveragechecker/profile-setup';
    @api homeUrl = '/coveragechecker/';

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

    get tipOopText() {
        return 'Out-of-pocket maximum: the most you pay in a year. After that, your plan pays 100% of covered care. Your deductible, copays and coinsurance all count toward it.';
    }
    get tipPaidText() {
        return 'What your insurance has paid toward your bills after your deductible, copays and coinsurance.';
    }
    get tipOweText() {
        return 'Your share of the bills: your deductible, copays and coinsurance.';
    }

    data;
    error;
    loaded = false;

    wiredResult;

    @wire(getDashboard)
    wiredDashboard(result) {
        this.wiredResult = result;
        const { data, error } = result;
        if (data) {
            this.data = data;
            this.error = undefined;
        } else if (error) {
            this.error = error?.body?.message || 'Something went wrong loading your dashboard.';
            this.data = undefined;
        }
        if (data || error) {
            this.loaded = true;
        }
        if (data) {
            this.sendToSetupIfNeeded(data);
        }
    }

    // First-time order: profile setup, then insurance setup, then the dashboard.
    // Each redirect happens at most once per browser session so a failed save can never cause a loop.
    sendToSetupIfNeeded(data) {
        let target = null;
        let flag = '';
        if (!data.patientName) {
            target = '/coveragechecker/profile-setup';
            flag = 'cc_sent_profile';
        } else if (!data.planName) {
            target = '/coveragechecker/insurance-setup';
            flag = 'cc_sent_insurance';
        }
        if (!target) return;
        try {
            if (window.sessionStorage.getItem(flag)) return;
            window.sessionStorage.setItem(flag, '1');
        } catch (e) {
            return;
        }
        window.location.href = target;
    }

    // ---- BUG-44: confirm a requested appointment after the office's callback ----
    confirmingId = '';
    // Each list shows 3 rows until the patient taps "Show more".
    expanded = { confirmed: false, requested: false, history: false, bills: false };
    confirmDate = '';
    confirmError = '';
    isConfirming = false;

    get minConfirmDate() {
        const t = new Date();
        const pad = (n) => String(n).padStart(2, '0');
        return `${t.getFullYear()}-${pad(t.getMonth() + 1)}-${pad(t.getDate())}`;
    }

    handleStartConfirm(event) {
        this.confirmingId = event.currentTarget.dataset.id;
        this.confirmDate = '';
        this.confirmError = '';
    }

    handleCancelConfirm() {
        this.confirmingId = '';
        this.confirmDate = '';
        this.confirmError = '';
    }

    handleConfirmDateChange(event) {
        this.confirmDate = event.target.value;
        this.confirmError = '';
    }

    async handleSaveConfirm() {
        if (!this.confirmDate) {
            this.confirmError = 'Please choose the date the office confirmed.';
            return;
        }
        if (this.confirmDate < this.minConfirmDate) {
            this.confirmError = 'The date cannot be in the past.';
            return;
        }
        this.isConfirming = true;
        try {
            await confirmAppointment({ appointmentId: this.confirmingId, confirmedDate: this.confirmDate });
            await refreshApex(this.wiredResult);
            this.handleCancelConfirm();
        } catch (e) {
            this.confirmError = (e && e.body && e.body.message) || 'Something went wrong. Please try again.';
        } finally {
            this.isConfirming = false;
        }
    }

    get confirmSaveLabel() {
        return this.isConfirming ? 'Saving…' : 'Confirm appointment';
    }

    // ---- state flags ----
    get isLoading() {
        return !this.loaded;
    }
    get hasPatient() {
        return !!this.data?.patientName;
    }
    // A patient with no bills, appointments or requests yet sees a welcome card instead of empty cards.
    get isNewPatient() {
        return this.loaded && !this.error && this.hasPatient
            && !this.hasBills && !this.hasAppointments && !this.hasHistory
            && (this.data?.billsChecked || 0) === 0;
    }
    get showDashboard() {
        return this.hasPatient && !this.isNewPatient;
    }
    get showEmpty() {
        return this.loaded && !this.error && !this.hasPatient;
    }
    get hasPlan() {
        return !!this.data?.planName;
    }
    get hasAppointments() {
        return this.appointments.length > 0;
    }
    get hasHistory() {
        return this.history.length > 0;
    }
    get hasBills() {
        return this.bills.length > 0;
    }
    get hasBilled() {
        return (this.data?.totalBilled || 0) > 0;
    }
    get hasOopMax() {
        return (this.data?.outOfPocketMax || 0) > 0;
    }

    // ---- savings view ----
    get billsChecked() {
        return this.data?.billsChecked || 0;
    }
    get flaggedCount() {
        return this.data?.flaggedCount || 0;
    }
    get flaggedAmountText() {
        return money(this.data?.flaggedAmount);
    }
    get billsCheckedNote() {
        return this.billsChecked === 0
            ? 'Check a bill to see how it compares with your plan.'
            : 'Each one is compared with your plan and typical prices.';
    }
    get flaggedNote() {
        if (this.billsChecked === 0) return 'Nothing to review yet.';
        return this.flaggedCount === 0
            ? 'None so far. Every charge is at or below the typical rate.'
            : 'Open the bill and use "Get dispute letter" to ask for a review.';
    }

    // ---- hero ----
    get firstName() {
        return this.data?.firstName || this.data?.patientName || '';
    }
    // Text shown in the banner above the cards.
    get heroTitle() {
        return this.hasPatient ? `${this.greeting}, ${this.firstName}` : 'Welcome to Care Compass';
    }
    get planLabel() {
        return this.hasPatient && this.hasPlan ? this.data.planName : '';
    }
    get greeting() {
        const h = new Date().getHours();
        if (h < 12) return 'Good morning';
        if (h < 18) return 'Good afternoon';
        return 'Good evening';
    }
    get insight() {
        if (!this.hasBilled) {
            return 'Check a bill and your coverage summary will show up here.';
        }
        return `Your plan has covered ${this.coveredPct}% of the ${this.billedText} billed so far.`;
    }

    // ---- out of pocket ----
    get spent() {
        return this.data?.outOfPocketSpent || 0;
    }
    get oopMax() {
        return this.data?.outOfPocketMax || 0;
    }
    get spentText() {
        return money(this.spent);
    }
    get oopMaxText() {
        return money(this.oopMax);
    }
    get oopRemainingText() {
        return money(Math.max(this.oopMax - this.spent, 0));
    }
    get oopPercent() {
        return this.oopMax ? clampPct((this.spent / this.oopMax) * 100) : 0;
    }
    get ringStyle() {
        return `background: conic-gradient(#E8A33D ${this.oopPercent * 3.6}deg, var(--cc-track, #EFEAE0) 0deg)`;
    }

    // ---- billed vs covered ----
    get billedText() {
        return money(this.data?.totalBilled);
    }
    get coveredText() {
        return money(this.data?.totalCovered);
    }
    get oweText() {
        return money(this.spent);
    }
    get coveredPct() {
        const billed = this.data?.totalBilled || 0;
        return billed ? clampPct(((this.data?.totalCovered || 0) / billed) * 100) : 0;
    }
    get oweePct() {
        return 100 - this.coveredPct;
    }
    get coveredSegStyle() {
        return `width: ${this.coveredPct}%`;
    }
    get oweSegStyle() {
        return `width: ${this.oweePct}%`;
    }

    // ---- lists ----
    get confirmedAppointments() {
        return this.appointments.filter((a) => a.isConfirmed);
    }
    get requestedAppointments() {
        return this.appointments.filter((a) => a.isRequested);
    }
    get visibleConfirmed() { return this.limitList('confirmed', this.confirmedAppointments); }
    get visibleRequested() { return this.limitList('requested', this.requestedAppointments); }
    get visibleHistory() { return this.limitList('history', this.history); }
    get visibleBills() { return this.limitList('bills', this.bills); }
    get moreConfirmed() { return this.moreInfo('confirmed', this.confirmedAppointments.length); }
    get moreRequested() { return this.moreInfo('requested', this.requestedAppointments.length); }
    get moreHistory() { return this.moreInfo('history', this.history.length); }
    get moreBills() { return this.moreInfo('bills', this.bills.length); }

    limitList(key, list) {
        return this.expanded[key] ? list : list.slice(0, LIST_LIMIT);
    }
    // { show, label } for the Show more / Show less button under a list.
    moreInfo(key, total) {
        if (total <= LIST_LIMIT) return { show: false, label: '' };
        return {
            show: true,
            label: this.expanded[key] ? 'Show less' : `Show ${total - LIST_LIMIT} more`
        };
    }
    toggleList(event) {
        const key = event.currentTarget.dataset.list;
        this.expanded = { ...this.expanded, [key]: !this.expanded[key] };
    }

    get hasConfirmed() {
        return this.confirmedAppointments.length > 0;
    }
    get hasRequested() {
        return this.requestedAppointments.length > 0;
    }

    get appointments() {
        return (this.data?.appointments || []).map((a) => {
            const dt = parseDate(a.apptDate);
            const pending = a.estimatedCost === null || a.estimatedCost === undefined;
            let badgeLabel = 'Network check pending';
            let badgeClass = 'pill pill-pending';
            if (!pending) {
                badgeLabel = a.inNetwork ? 'In network' : 'Out of network';
                badgeClass = a.inNetwork ? 'pill pill-in' : 'pill pill-out';
            }
            const isConfirmed = a.status === 'Confirmed';
            return {
                id: a.id,
                isRequested: !isConfirmed,
                isConfirmed,
                showForm: this.confirmingId === a.id,
                doctorName: a.doctorName,
                month: dt ? MONTHS[dt.getMonth()] : '',
                day: dt ? dt.getDate() : '',
                subline: [dt ? WEEKDAYS[dt.getDay()] : null, a.procedureType].filter(Boolean).join(' · '),
                costText: pending ? 'Estimate pending' : `${money(a.estimatedCost)} est.`,
                badgeLabel,
                badgeClass
            };
        });
    }

    // BUG-35: expired callback requests (requested date before today), newest first.
    get history() {
        return (this.data?.history || []).map((h) => {
            const req = parseDate(h.requestedOn);
            const visit = parseDate(h.apptDate);
            return {
                id: h.id,
                doctorName: h.doctorName,
                requestedText: req ? `${MONTHS[req.getMonth()]} ${req.getDate()}, ${req.getFullYear()}` : '',
                subline: [h.procedureType, visit ? `for ${MONTHS[visit.getMonth()]} ${visit.getDate()}, ${visit.getFullYear()}` : null]
                    .filter(Boolean).join(' · '),
                statusLabel: h.status === 'Confirmed' ? 'Past visit' : 'Expired'
            };
        });
    }

    get bills() {
        return (this.data?.bills || []).map((b) => {
            const dt = parseDate(b.billDate);
            const pct = b.billed ? clampPct(((b.covered || 0) / b.billed) * 100) : 0;
            return {
                id: b.id,
                provider: b.provider,
                billNumber: b.billNumber || '',
                dateText: dt ? `${MONTHS[dt.getMonth()]} ${dt.getDate()}, ${dt.getFullYear()}` : '',
                coveredPct: pct,
                barStyle: `width: ${pct}%`,
                oweText: money(b.patientOwes)
            };
        });
    }

    // ---- navigation ----
    goFindCare() {
        window.location.href = this.findCareUrl;
    }
    openBill(event) {
        const id = event.currentTarget.dataset.id;
        if (id) {
            window.location.href = `${this.checkBillUrl}?bill=${id}`;
        }
    }
    openBillKey(event) {
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            this.openBill(event);
        }
    }
    goCheckBill() {
        window.location.href = this.checkBillUrl;
    }
    goProfile() {
        window.location.href = this.profileUrl;
    }
    goHome() {
        window.location.href = this.homeUrl;
    }
}
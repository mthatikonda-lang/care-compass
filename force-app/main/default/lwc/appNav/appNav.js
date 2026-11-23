import { LightningElement, api, wire } from 'lwc';
import isGuest from '@salesforce/user/isGuest';
import getDashboard from '@salesforce/apex/PatientDashboardController.getDashboard';
import isSetupComplete from '@salesforce/apex/InsuranceSetupController.isSetupComplete';
import { getTheme, initTheme, setTheme } from 'c/themeService';

// Shared header for every Care Compass page: brand, page buttons, and the patient icon with details.
// Use it as <c-app-nav active="home" heading="..." subtitle="..."></c-app-nav>.
// Anything placed inside the tag shows under the title, inside the banner.
const money = (v) => new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 0 }).format(Number(v || 0));

export default class AppNav extends LightningElement {
    @api active = 'home'; // home | find | bill | insurance | about | help
    @api heading;
    @api subtitle;
    @api hideMenu = false; // true on first-time setup pages: logo only, no menu or patient icon

    @api homeUrl = '/coveragechecker/';
    @api findCareUrl = '/coveragechecker/book-appointment';
    @api checkBillUrl = '/coveragechecker/coverage-checker';
    @api profileUrl = '/coveragechecker/my-profile';
    @api insuranceUrl = '/coveragechecker/insurance-setup';
    @api aboutUrl = '/coveragechecker/about';
    @api helpUrl = '/coveragechecker/help';
    @api signOutUrl = '/secur/logout.jsp';

    menuOpen = false;
    isDark = false;
    patient;

    // Same cached call the dashboard uses, so the icon needs no extra request.
    @wire(getDashboard)
    wiredPatient({ data }) {
        if (data) {
            this.patient = data;
        }
    }

    connectedCallback() {
        // Apply the saved (or device) light/dark choice as soon as any page loads.
        this.isDark = initTheme() === 'dark';

        this._closeOutside = (event) => {
            const wrap = this.template.querySelector('.an-menu-wrap');
            if (this.menuOpen && wrap && !event.composedPath().includes(wrap)) {
                this.menuOpen = false;
            }
        };
        window.addEventListener('click', this._closeOutside);

        // First-time setup guard: a signed-in patient who has not finished insurance setup
        // goes back to it, whichever page or typed address they tried. Skipped on the setup
        // page itself (no redirect loop) and for guests (Help, About, Terms, login).
        const onSetupPage = window.location.pathname.startsWith(this.insuranceUrl);
        if (!isGuest && !this.hideMenu && !onSetupPage) {
            isSetupComplete()
                .then((done) => {
                    if (done === false) {
                        window.location.href = this.insuranceUrl;
                    }
                })
                .catch(() => {
                    // Never trap a patient because the check failed.
                });
        }
    }

    disconnectedCallback() {
        window.removeEventListener('click', this._closeOutside);
    }

    get showMenu() {
        return !this.hideMenu;
    }

    get tabs() {
        return [
            { key: 'home', label: 'Home', url: this.homeUrl },
            { key: 'find', label: 'Find care', url: this.findCareUrl },
            { key: 'bill', label: 'Check a bill', url: this.checkBillUrl },
            { key: 'about', label: 'About', url: this.aboutUrl },
            { key: 'help', label: 'Help', url: this.helpUrl }
        ].map((t) => ({ ...t, cls: t.key === this.active ? 'an-pill an-pill-active' : 'an-pill' }));
    }

    get patientName() {
        return this.patient?.fullName || this.patient?.patientName || 'My account';
    }
    get initials() {
        const words = (this.patient?.fullName || this.patient?.patientName || '').replace(/[^A-Za-z\s]/g, ' ').split(/\s+/).filter((w) => w);
        if (words.length === 0) return '+';
        if (words.length === 1) return words[0].slice(0, 2).toUpperCase();
        return (words[0][0] + words[1][0]).toUpperCase();
    }
    get avatarClass() {
        return this.menuOpen ? 'an-avatar an-avatar-open' : 'an-avatar';
    }
    get patientLabel() {
        return this.patient?.patientName ? `Patient ${this.patient.patientName}` : 'Patient';
    }
    get hasMemberId() {
        return !!this.patient?.memberId;
    }
    get memberId() {
        return this.patient?.memberId;
    }
    get hasPlan() {
        return !!this.patient?.planName;
    }
    get planName() {
        return this.patient?.planName;
    }
    get hasDeductible() {
        return this.patient?.deductible != null;
    }
    get deductibleText() {
        return money(this.patient?.deductible);
    }
    get hasOopMax() {
        return this.patient?.outOfPocketMax != null;
    }
    get oopMaxText() {
        return money(this.patient?.outOfPocketMax);
    }

    get themeLabel() {
        return this.isDark ? 'Switch to light mode' : 'Switch to dark mode';
    }
    toggleTheme(event) {
        event.stopPropagation();
        this.isDark = setTheme(getTheme() === 'dark' ? 'light' : 'dark') === 'dark';
    }

    toggleMenu(event) {
        event.stopPropagation();
        this.menuOpen = !this.menuOpen;
    }
    handleNav(event) {
        const url = event.currentTarget.dataset.url;
        if (url) {
            window.location.href = url;
        }
    }
    goHome() {
        window.location.href = this.homeUrl;
    }
    signOut() {
        window.location.href = this.signOutUrl;
    }
}
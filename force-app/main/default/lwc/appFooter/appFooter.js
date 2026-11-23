import { LightningElement, api } from 'lwc';
import isGuest from '@salesforce/user/isGuest';

export default class AppFooter extends LightningElement {
    // Confirm these match your site's page URLs.
    @api homeUrl = '/coveragechecker/';
    @api aboutUrl = '/coveragechecker/about';
    @api howUrl = '/coveragechecker/help';
    @api helpUrl = '/coveragechecker/help';
    @api contactUrl = '/coveragechecker/help';
    @api findCareUrl = '/coveragechecker/book-appointment';
    @api checkBillUrl = '/coveragechecker/coverage-checker';
    @api dashboardUrl = '/coveragechecker/patient-dashboard';
    @api profileUrl = '/coveragechecker/my-profile';
    @api termsUrl = '/coveragechecker/terms';
    @api privacyUrl = '/coveragechecker/privacy';
    @api welcomeUrl = '/coveragechecker/welcome';

    // Logged-out visitors get no real destination on locked links, so nothing can open them.
    get homeHref() { return isGuest ? '#' : this.homeUrl; }
    get aboutHref() { return isGuest ? '#' : this.aboutUrl; }
    get howHref() { return isGuest ? '#' : this.howUrl; }
    get helpHref() { return isGuest ? '#' : this.helpUrl; }
    get contactHref() { return isGuest ? '#' : this.contactUrl; }
    get termsHref() { return isGuest ? '#' : this.termsUrl; }
    get privacyHref() { return isGuest ? '#' : this.privacyUrl; }
    get findCareHref() { return isGuest ? '#' : this.findCareUrl; }
    get checkBillHref() { return isGuest ? '#' : this.checkBillUrl; }
    get dashboardHref() { return isGuest ? '#' : this.dashboardUrl; }
    get profileHref() { return isGuest ? '#' : this.profileUrl; }

    gateOpen = false;
    gateLabel = '';
    _gateTarget = '';

    connectedCallback() {
        this._onKey = (e) => {
            if (e.key === 'Escape' && this.gateOpen) {
                this.closeGate();
            }
        };
        window.addEventListener('keydown', this._onKey);
    }
    disconnectedCallback() {
        window.removeEventListener('keydown', this._onKey);
    }

    // Logged-in visitors follow the link as normal. Guests get the prompt.
    handleGated(event) {
        if (!isGuest) {
            return;
        }
        event.preventDefault();
        event.stopPropagation();
        this.gateLabel = event.currentTarget.dataset.gate;
        this._gateTarget = event.currentTarget.dataset.target;
        this.gateOpen = true;
    }
    closeGate() {
        this.gateOpen = false;
    }
    handleBackdrop(event) {
        if (event.target === event.currentTarget) {
            this.closeGate();
        }
    }
    goLogin() {
        this._go('login');
    }
    goSignup() {
        this._go('signup');
    }
    _go(auth) {
        this.gateOpen = false;
        // If the page can show its own login popup (the welcome page), let it. Otherwise go there.
        const request = new CustomEvent('authrequest', { detail: { mode: auth, next: this._gateTarget }, cancelable: true });
        if (!this.dispatchEvent(request)) {
            return;
        }
        // The welcome page opens the popup and sends them on to the page they wanted.
        window.location.href = this.welcomeUrl + '?auth=' + auth + '&next=' + encodeURIComponent(this._gateTarget);
    }
}
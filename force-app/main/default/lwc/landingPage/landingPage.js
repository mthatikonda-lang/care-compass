import { LightningElement, api } from 'lwc';
import isGuest from '@salesforce/user/isGuest';
import login from '@salesforce/apex/PatientLoginController.login';
import forgotPassword from '@salesforce/apex/PatientLoginController.forgotPassword';
import registerPatient from '@salesforce/apex/PatientRegistrationController.registerPatient';

const MIN_PASSWORD_LENGTH = 8;

// Public welcome page. Visitors can log in or create an account right here.
// Patients who are already signed in are sent straight to their home page.
export default class LandingPage extends LightningElement {
    @api startUrl = '/coveragechecker/';
    @api homeUrl = '/coveragechecker/';

    mode = 'login'; // 'signup' or 'login'
    isModalOpen = false;
    _focusPending = false;

    // Log in
    username = '';
    password = '';
    showPassword = false;
    loginError = '';
    infoMessage = '';
    isLoggingIn = false;

    // Create account
    firstName = '';
    lastName = '';
    email = '';
    regPassword = '';
    dob = '';
    gender = '';
    phone = '';
    regError = '';
    regSuccess = '';
    isSubmitting = false;
    isSubmitted = false;

    // Sample bill
    amount = 240;

    _observer;
    _sampleObserver;
    _ready = false;
    _raf;

    genderOptions = [
        { label: 'Male', value: 'Male' },
        { label: 'Female', value: 'Female' },
        { label: 'Other', value: 'Other' },
        { label: 'Prefer not to say', value: 'Prefer not to say' }
    ];

    // ---------- Lifecycle ----------
    connectedCallback() {
        if (!isGuest) {
            window.location.replace(this.homeUrl);
        }
        // Sent here from a locked footer link: open the popup and remember where to go after login.
        try {
            const params = new URLSearchParams(window.location.search);
            const next = params.get('next');
            if (next && next.startsWith('/coveragechecker/') && !next.startsWith('//')) {
                this.startUrl = next;
            }
            const auth = params.get('auth');
            if (auth === 'login') {
                this.showLogin();
            } else if (auth === 'signup') {
                this.showSignup();
            }
        } catch (e) {
            // ignore: the page still works without the shortcut
        }
        this._onKey = (event) => {
            if (event.key === 'Escape' && this.isModalOpen) {
                this.closeModal();
            }
        };
        window.addEventListener('keydown', this._onKey);
    }

    renderedCallback() {
        // Put the cursor in the first field when the popup opens or switches form.
        if (this._focusPending && this.isModalOpen) {
            this._focusPending = false;
            const field = this.template.querySelector('.lp-pane .lp-input') || this.template.querySelector('.lp-pane lightning-input');
            if (field && field.focus) {
                field.focus();
            }
        }
        if (this._ready) {
            return;
        }
        this._ready = true;

        const root = this.template.querySelector('.lp');
        const items = this.template.querySelectorAll('.lp-reveal');
        const sample = this.template.querySelector('.lp-sample');
        const reduce = window.matchMedia && window.matchMedia('(prefers-reduced-motion: reduce)').matches;

        // Without script support or with reduced motion, everything simply shows.
        if (!root || reduce || !('IntersectionObserver' in window)) {
            return;
        }
        root.classList.add('lp-js');
        this._observer = new IntersectionObserver(
            (entries) => {
                entries.forEach((entry) => {
                    if (entry.isIntersecting) {
                        entry.target.classList.add('lp-visible');
                        this._observer.unobserve(entry.target);
                    }
                });
            },
            { threshold: 0.15, rootMargin: '0px 0px -40px 0px' }
        );
        items.forEach((el, i) => {
            el.style.transitionDelay = `${(i % 3) * 90}ms`;
            this._observer.observe(el);
        });

        // Count the sample total up when it scrolls into view.
        if (sample) {
            this._sampleObserver = new IntersectionObserver(
                (entries) => {
                    if (entries.some((e) => e.isIntersecting)) {
                        this._sampleObserver.disconnect();
                        this.countUp();
                    }
                },
                { threshold: 0.4 }
            );
            this._sampleObserver.observe(sample);
        }
    }

    disconnectedCallback() {
        window.removeEventListener('keydown', this._onKey);
        if (this._observer) this._observer.disconnect();
        if (this._sampleObserver) this._sampleObserver.disconnect();
        if (this._raf) cancelAnimationFrame(this._raf);
    }

    countUp() {
        const target = 240;
        const start = performance.now();
        const run = (now) => {
            const t = Math.min((now - start) / 1400, 1);
            this.amount = Math.round(target * (1 - Math.pow(1 - t, 3)));
            if (t < 1) {
                this._raf = requestAnimationFrame(run);
            }
        };
        this.amount = 0;
        this._raf = requestAnimationFrame(run);
    }

    // ---------- Getters ----------
    get amountText() {
        return `$${this.amount}`;
    }
    get isLogin() {
        return this.mode === 'login';
    }
    get isSignup() {
        return this.mode === 'signup';
    }
    get loginTabClass() {
        return this.isLogin ? 'lp-tab lp-tab-on' : 'lp-tab';
    }
    get signupTabClass() {
        return this.isSignup ? 'lp-tab lp-tab-on' : 'lp-tab';
    }
    get loginLabel() {
        return this.isLoggingIn ? 'Logging in…' : 'Log in';
    }
    get passwordType() {
        return this.showPassword ? 'text' : 'password';
    }
    get toggleLabel() {
        return this.showPassword ? 'Hide' : 'Show';
    }
    get submitLabel() {
        return this.isSubmitting ? 'Creating your account…' : 'Sign Up';
    }

    // ---------- Popup: log in / create account ----------
    showLogin() {
        this.mode = 'login';
        this.loginError = '';
        this.isModalOpen = true;
        this._focusPending = true;
    }
    showSignup() {
        this.mode = 'signup';
        this.regError = '';
        this.isModalOpen = true;
        this._focusPending = true;
    }
    // The footer asks for the popup when a guest clicks a locked link.
    handleAuthRequest(event) {
        event.preventDefault();
        const next = event.detail && event.detail.next;
        if (next && next.startsWith('/coveragechecker/') && !next.startsWith('//')) {
            this.startUrl = next;
        }
        if (event.detail && event.detail.mode === 'signup') {
            this.showSignup();
        } else {
            this.showLogin();
        }
    }
    closeModal() {
        this.isModalOpen = false;
    }
    handleBackdrop(event) {
        // Close only when the dark area itself is clicked, not the card.
        if (event.target === event.currentTarget) {
            this.closeModal();
        }
    }

    // Soft gold spotlight that follows the cursor across a card.
    trackMouse(event) {
        const card = event.currentTarget;
        const rect = card.getBoundingClientRect();
        card.style.setProperty('--mx', `${event.clientX - rect.left}px`);
        card.style.setProperty('--my', `${event.clientY - rect.top}px`);
    }

    // ---------- Page navigation ----------
    scrollTop() {
        window.scrollTo({ top: 0, behavior: 'smooth' });
    }
    scrollToSection(event) {
        const id = event.currentTarget.dataset.target;
        const el = this.template.querySelector(`[data-anchor="${id}"]`);
        if (el) {
            el.scrollIntoView({ behavior: 'smooth', block: 'start' });
        }
    }

    // ---------- Log in (same behaviour as the login page) ----------
    handleUsername(event) {
        this.username = event.target.value;
    }
    handlePassword(event) {
        this.password = event.target.value;
    }
    toggleShow() {
        this.showPassword = !this.showPassword;
    }
    handleLoginKey(event) {
        if (event.key === 'Enter') {
            this.handleLogin();
        }
    }

    handleLogin() {
        if (this.isLoggingIn) return;
        this.loginError = '';
        this.infoMessage = '';
        if (!this.username.trim() || !this.password) {
            this.loginError = 'Enter your username and password.';
            return;
        }
        this.isLoggingIn = true;
        login({ username: this.username, password: this.password, startUrl: this.startUrl })
            .then((url) => {
                window.location.href = url;
            })
            .catch((error) => {
                this.isLoggingIn = false;
                this.loginError = error && error.body && error.body.message
                    ? error.body.message
                    : 'Something went wrong. Please try again.';
            });
    }

    handleForgot() {
        this.loginError = '';
        this.infoMessage = '';
        if (!this.username.trim()) {
            this.loginError = 'Type your username above, then choose Forgot password.';
            return;
        }
        forgotPassword({ username: this.username })
            .then(() => {
                this.infoMessage = 'If that username exists, we have emailed a link to reset the password.';
            })
            .catch((error) => {
                this.loginError = error && error.body && error.body.message
                    ? error.body.message
                    : 'Something went wrong. Please try again.';
            });
    }

    // ---------- Create account (same rules as the registration page) ----------
    handleFirstName(event) { this.firstName = event.target.value; }
    handleLastName(event)  { this.lastName = event.target.value; }
    handleEmail(event) {
        this.email = event.target.value;
        const problem = this.emailProblem(this.email);
        event.target.setCustomValidity(problem || '');
        event.target.reportValidity();
    }

    // Mirrors PatientRegistrationController.checkEmail.
    emailProblem(value) {
        if (!value) {
            return 'Please enter your email address.';
        }
        if (value.length > 64) {
            return 'Email address is too long (maximum 64 characters).';
        }
        if (!/^[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+(\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}$/.test(value)) {
            return 'Please enter a valid email address, for example name@example.com.';
        }
        return null;
    }

    handleDob(event) {
        this.dob = event.target.value;
        const problem = this.dobProblem(this.dob);
        event.target.setCustomValidity(problem || '');
        event.target.reportValidity();
    }

    // Latest selectable date of birth: today (local time), as YYYY-MM-DD.
    get maxDob() {
        const d = new Date();
        const mm = String(d.getMonth() + 1).padStart(2, '0');
        const dd = String(d.getDate()).padStart(2, '0');
        return `${d.getFullYear()}-${mm}-${dd}`;
    }

    // Mirrors PatientRegistrationController.checkDateOfBirth.
    dobProblem(value) {
        if (!value) {
            return 'Please enter your date of birth.';
        }
        if (value > this.maxDob) {
            return 'Date of birth cannot be in the future.';
        }
        const oldest = new Date();
        oldest.setFullYear(oldest.getFullYear() - 120);
        if (new Date(value) < oldest) {
            return 'Please enter a valid date of birth.';
        }
        return null;
    }

    handleGender(event) { this.gender = event.target.value; }
    handlePhone(event) {
        this.phone = event.target.value;
        const problem = this.phoneProblem(this.phone);
        event.target.setCustomValidity(problem || '');
        event.target.reportValidity();
    }

    // Mirrors PatientRegistrationController.checkPhone.
    phoneProblem(value) {
        if (!value) {
            return 'Please enter your mobile number.';
        }
        const digits = value.replace(/[\s().-]/g, '');
        return /^(\+1|\+91)?[0-9]{10}$/.test(digits)
            ? null
            : 'Mobile number must be 10 digits, optionally starting with +1 or +91.';
    }

    handleRegPassword(event) {
        this.regPassword = event.target.value;
        event.target.setCustomValidity(this.passwordProblem(this.regPassword) || '');
    }

    // Mirrors PatientRegistrationController.checkPasswordRules. The server is still the
    // source of truth (it also applies the org password policy).
    checksFor(pw) {
        const value = pw || '';
        const rules = [
            { key: 'len', text: `At least ${MIN_PASSWORD_LENGTH} characters`, met: value.length >= MIN_PASSWORD_LENGTH },
            { key: 'upper', text: 'One uppercase letter', met: /[A-Z]/.test(value) },
            { key: 'lower', text: 'One lowercase letter', met: /[a-z]/.test(value) },
            { key: 'num', text: 'One number', met: /[0-9]/.test(value) },
            { key: 'special', text: 'One special character (for example ! @ # $ %)', met: /[^A-Za-z0-9]/.test(value) }
        ];
        return rules.map((r) => ({
            ...r,
            icon: r.met ? '✓' : '○',
            cssClass: r.met ? 'lp-pw-ok' : 'lp-pw-todo'
        }));
    }

    // Only the rules the password still fails. Nothing is shown until the patient types.
    get passwordChecks() {
        if (!this.regPassword) {
            return [];
        }
        return this.checksFor(this.regPassword).filter((r) => !r.met);
    }
    get hasPasswordChecks() {
        return this.passwordChecks.length > 0;
    }

    passwordProblem(pw) {
        const missing = this.checksFor(pw).filter((r) => !r.met).map((r) => r.text.toLowerCase());
        return missing.length ? `Your password needs: ${missing.join(', ')}.` : null;
    }

    handleSubmit() {
        this.regError = '';

        if (!this.firstName || !this.lastName || !this.email || !this.regPassword || !this.dob || !this.phone) {
            this.regError = 'Please fill in all required fields.';
            return;
        }

        const problem = this.emailProblem(this.email) ||
            this.passwordProblem(this.regPassword) ||
            this.dobProblem(this.dob) ||
            this.phoneProblem(this.phone);
        if (problem) {
            this.regError = problem;
            return;
        }

        this.isSubmitting = true;

        registerPatient({
            firstName: this.firstName,
            lastName: this.lastName,
            email: this.email,
            password: this.regPassword,
            dob: this.dob,
            gender: this.gender,
            phone: this.phone
        })
            .then(() => {
                this.isSubmitting = false;
                this.isSubmitted = true;
                this.regSuccess = 'Account created! Taking you to the log in form…';
                // Move to the log in form after a short pause so they can read the message.
                // eslint-disable-next-line @lwc/lwc/no-async-operation
                setTimeout(() => {
                    // The username is the email plus '.coveragechecker' (set in the Apex class),
                    // so fill it in for them. They only need to type the password.
                    this.username = `${this.email.trim()}.coveragechecker`;
                    this.password = '';
                    this.infoMessage = 'Account created. Your username is filled in below. Enter your password to log in.';
                    this.regPassword = '';
                    this.isSubmitted = false;
                    this.mode = 'login';
                }, 5000);
            })
            .catch((error) => {
                this.isSubmitting = false;
                this.regError = error && error.body && error.body.message
                    ? error.body.message
                    : 'Something went wrong. Please try again.';
            });
    }
}
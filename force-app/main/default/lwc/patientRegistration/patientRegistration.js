import { LightningElement } from 'lwc';
import registerPatient from '@salesforce/apex/PatientRegistrationController.registerPatient';

const MIN_PASSWORD_LENGTH = 8;

export default class PatientRegistration extends LightningElement {
    firstName = '';
    lastName = '';
    email = '';
    password = '';
    dob = '';
    gender = '';
    phone = '';

    errorMessage = '';
    successMessage = '';
    isSubmitting = false;
    isSubmitted = false;

    genderOptions = [
        { label: 'Male', value: 'Male' },
        { label: 'Female', value: 'Female' },
        { label: 'Other', value: 'Other' },
        { label: 'Prefer not to say', value: 'Prefer not to say' }
    ];

    get submitLabel() {
        return this.isSubmitting ? 'Creating your account…' : 'Sign Up';
    }

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
    handleGender(event)    { this.gender = event.target.value; }
    handlePhone(event) {
        this.phone = event.target.value;
        const problem = this.phoneProblem(this.phone);
        event.target.setCustomValidity(problem || '');
        event.target.reportValidity();
    }

    // Mirrors PatientRegistrationController.checkPhone. Required field; it must
    // be exactly 10 digits, optionally preceded by +1 or +91
    // (spaces, dashes, dots, parentheses ignored).
    phoneProblem(value) {
        if (!value) {
            return 'Please enter your mobile number.';
        }
        const digits = value.replace(/[\s().-]/g, '');
        return /^(\+1|\+91)?[0-9]{10}$/.test(digits)
            ? null
            : 'Mobile number must be 10 digits, optionally starting with +1 or +91.';
    }

    handlePassword(event) {
        this.password = event.target.value;
        // The checklist under the field shows each rule as the patient types,
        // so only set the validity here (no pop-up on every keystroke).
        event.target.setCustomValidity(this.passwordProblem(this.password) || '');
    }

    // Each rule once, so the checklist and the submit check always agree.
    // Mirrors PatientRegistrationController.checkPasswordRules. The server
    // is still the source of truth (it also applies the org password policy).
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
            icon: r.met ? '\u2713' : '\u25CB',
            cssClass: r.met ? 'slds-text-color_success' : 'slds-text-color_weak'
        }));
    }

    // Only the rules the password still fails. Once all are met, the list is empty
    // and the checklist is hidden.
    // Nothing is shown until the patient starts typing.
    get passwordChecks() {
        if (!this.password) {
            return [];
        }
        return this.checksFor(this.password).filter((r) => !r.met);
    }

    get hasPasswordChecks() {
        return this.passwordChecks.length > 0;
    }

    passwordProblem(pw) {
        const missing = this.checksFor(pw).filter((r) => !r.met).map((r) => r.text.toLowerCase());
        return missing.length ? `Your password needs: ${missing.join(', ')}.` : null;
    }

    handleSubmit() {
        this.errorMessage = '';

        if (!this.firstName || !this.lastName || !this.email || !this.password || !this.dob || !this.phone) {
            this.errorMessage = 'Please fill in all required fields.';
            return;
        }

        const problem = this.emailProblem(this.email) ||
            this.passwordProblem(this.password) ||
            this.dobProblem(this.dob) ||
            this.phoneProblem(this.phone);
        if (problem) {
            this.errorMessage = problem;
            return;
        }

        this.isSubmitting = true;

        registerPatient({
            firstName: this.firstName,
            lastName: this.lastName,
            email: this.email,
            password: this.password,
            dob: this.dob,
            gender: this.gender,
            phone: this.phone
        })
            .then(() => {
                this.isSubmitting = false;
                this.isSubmitted = true;
                this.successMessage = 'Account created! Please check your email for your username details. Taking you to the log in page…';
                setTimeout(() => {
                    window.location.href = '/coveragechecker/login';
                }, 6000);
            })
            .catch((error) => {
                this.isSubmitting = false;
                this.errorMessage = (error && error.body && error.body.message)
                    ? error.body.message
                    : 'Something went wrong. Please try again.';
            });
    }

    handleBack() {
        window.history.back();
    }
}
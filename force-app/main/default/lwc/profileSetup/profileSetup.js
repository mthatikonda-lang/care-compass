import { LightningElement, wire } from 'lwc';
import getCurrentPatient from '@salesforce/apex/PatientHomeController.getCurrentPatient';
import saveProfileDetails from '@salesforce/apex/ProfileSetupController.saveProfileDetails';

export default class ProfileSetup extends LightningElement {
    dateOfBirth;
    gender;
    phone;
    isLoading = true;
    isSubmitting = false;
    errorMessage;
    confirmingChange = false;

    // Values as last loaded or saved, used to tell whether the patient has unsaved changes.
    savedDateOfBirth = '';
    savedGender = '';
    savedPhone = '';

    genderOptions = [
        { label: 'Male', value: 'Male' },
        { label: 'Female', value: 'Female' },
        { label: 'Other', value: 'Other' },
        { label: 'Prefer not to say', value: 'Prefer not to say' }
    ];

    // Chrome's Back button can restore this page from its back/forward cache exactly as it
    // was when the patient left, including the "Saving…" button state from the Save click.
    // Nothing is saved by Back; this just clears the leftover state when the page returns.
    pageShowHandler = (event) => {
        if (event.persisted) {
            this.isSubmitting = false;
            this.errorMessage = null;
        }
    };

    // Asks the browser to confirm before the patient reloads, closes the tab or goes back
    // while there are unsaved changes. Browsers show their own generic message; the text
    // cannot be customised.
    beforeUnloadHandler = (event) => {
        if (this.hasUnsavedChanges && !this.isSubmitting) {
            event.preventDefault();
            event.returnValue = '';
        }
    };

    get hasUnsavedChanges() {
        return (this.dateOfBirth || '') !== this.savedDateOfBirth
            || (this.gender || '') !== this.savedGender
            || (this.phone || '') !== this.savedPhone;
    }

    connectedCallback() {
        window.addEventListener('pageshow', this.pageShowHandler);
        window.addEventListener('beforeunload', this.beforeUnloadHandler);
    }

    disconnectedCallback() {
        window.removeEventListener('pageshow', this.pageShowHandler);
        window.removeEventListener('beforeunload', this.beforeUnloadHandler);
    }

    @wire(getCurrentPatient)
    wiredPatient({ data, error }) {
        this.isLoading = false;
        console.log('ProfileSetup.wiredPatient - data:', JSON.stringify(data));
        console.log('ProfileSetup.wiredPatient - error:', JSON.stringify(error));

        if (data) {
            this.dateOfBirth = data.Date_of_Birth__c || undefined;
            this.gender = data.Gender__c || undefined;
            this.phone = data.Phone__c || undefined;
            this.savedDateOfBirth = this.dateOfBirth || '';
            this.savedGender = this.gender || '';
            this.savedPhone = this.phone || '';
            console.log('ProfileSetup.wiredPatient - prefilled dateOfBirth:', this.dateOfBirth, ' gender:', this.gender, ' phone:', this.phone);
        } else if (error) {
            console.error('ProfileSetup.wiredPatient - error details:', error.body ? error.body.message : error.message, error);
            this.errorMessage = 'Could not load your profile. Please try again.';
        } else {
            console.log('ProfileSetup.wiredPatient - no data and no error (query returned zero rows)');
        }
    }

    // Opened from the profile page (?from=profile) to change saved details, not first-time setup.
    get isEdit() {
        return new URLSearchParams(window.location.search).get('from') === 'profile';
    }
    get pageHeading() {
        return this.isEdit ? 'Edit your profile' : 'Just a few details';
    }
    get pageSubtitle() {
        return this.isEdit
            ? 'Update your date of birth, gender or phone number.'
            : 'We need this to personalize your coverage checks and doctor matches. This takes less than a minute.';
    }
    get hideNav() {
        return !this.isEdit;
    }
    get submitLabel() {
        if (this.isSubmitting) return 'Saving…';
        return this.isEdit ? 'Save changes' : 'Save and Continue';
    }

    // Latest selectable date of birth: today (local time), as YYYY-MM-DD.
    get maxDob() {
        const d = new Date();
        const mm = String(d.getMonth() + 1).padStart(2, '0');
        const dd = String(d.getDate()).padStart(2, '0');
        return `${d.getFullYear()}-${mm}-${dd}`;
    }

    // Same rule as the registration page and PatientRegistrationController.checkDateOfBirth.
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

    // Same rule as the registration page and PatientRegistrationController.checkPhone:
    // exactly 10 digits, optionally preceded by +1 or +91 (spaces, dashes, dots,
    // parentheses ignored).
    phoneProblem(value) {
        if (!value) {
            return 'Please enter your mobile number.';
        }
        const digits = value.replace(/[\s().-]/g, '');
        return /^(\+1|\+91)?[0-9]{10}$/.test(digits)
            ? null
            : 'Mobile number must be 10 digits, optionally starting with +1 or +91.';
    }

    handleDobChange(event) {
        this.dateOfBirth = event.target.value;
        console.log('ProfileSetup.handleDobChange - dateOfBirth:', this.dateOfBirth);
        const problem = this.dobProblem(this.dateOfBirth);
        event.target.setCustomValidity(problem || '');
        event.target.reportValidity();
    }

    handleGenderChange(event) {
        this.gender = event.detail.value;
        console.log('ProfileSetup.handleGenderChange - gender:', this.gender);
    }

    handlePhoneChange(event) {
        this.phone = event.target.value;
        console.log('ProfileSetup.handlePhoneChange - phone:', this.phone);
        const problem = this.phoneProblem(this.phone);
        event.target.setCustomValidity(problem || '');
        event.target.reportValidity();
    }

    // BUG-23: changing a saved date of birth asks for confirmation first.
    get dobChangeMessage() {
        return `You're changing your date of birth from ${this.prettyDate(this.savedDateOfBirth)} to ${this.prettyDate(this.dateOfBirth)}. `
            + 'It is used to match your insurance record. Save this change?';
    }

    // "1998-09-17" -> "Sep 17, 1998"
    prettyDate(value) {
        if (!value) return '';
        const [y, m, d] = value.split('-').map(Number);
        const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
        return `${months[m - 1]} ${d}, ${y}`;
    }

    get changingSavedDob() {
        return !!this.savedDateOfBirth && (this.dateOfBirth || '') !== this.savedDateOfBirth;
    }

    handleCancelChange() {
        this.confirmingChange = false;
    }

    handleConfirmChange() {
        this.confirmingChange = false;
        this.handleSave(true);
    }

    handleSave(confirmed) {
        console.log('ProfileSetup.handleSave - submitting:', { dateOfBirth: this.dateOfBirth, gender: this.gender, phone: this.phone });

        if (!this.dateOfBirth || !this.gender || !this.phone) {
            this.errorMessage = 'Please fill in all fields.';
            console.log('ProfileSetup.handleSave - validation failed, missing fields');
            return;
        }

        const problem = this.dobProblem(this.dateOfBirth) || this.phoneProblem(this.phone);
        if (problem) {
            this.errorMessage = problem;
            console.log('ProfileSetup.handleSave - validation failed:', problem);
            return;
        }

        if (confirmed !== true && this.changingSavedDob) {
            this.errorMessage = null;
            this.confirmingChange = true;
            return;
        }

        this.errorMessage = null;
        this.isSubmitting = true;

        saveProfileDetails({
            dateOfBirth: this.dateOfBirth,
            gender: this.gender,
            phone: this.phone
        })
            .then(() => {
                // Saved, so there is nothing left to warn about when we leave this page.
                this.savedDateOfBirth = this.dateOfBirth || '';
                this.savedGender = this.gender || '';
                this.savedPhone = this.phone || '';
                console.log('ProfileSetup.handleSave - save succeeded, redirecting to insurance-setup');
                const fromProfile = new URLSearchParams(window.location.search).get('from') === 'profile';
                window.location.href = fromProfile ? '/coveragechecker/my-profile' : '/coveragechecker/insurance-setup';
            })
            .catch((error) => {
                this.isSubmitting = false;
                console.error('ProfileSetup.handleSave - save failed:', error);
                this.errorMessage = (error && error.body && error.body.message)
                    ? error.body.message
                    : 'Something went wrong. Please try again.';
            });
    }
}
import { LightningElement, wire } from 'lwc';
import getCurrentPatient from '@salesforce/apex/PatientHomeController.getCurrentPatient';
import getInsurancePlans from '@salesforce/apex/InsuranceSetupController.getInsurancePlans';
import saveInsuranceSetup from '@salesforce/apex/InsuranceSetupController.saveInsuranceSetup';

export default class InsuranceSetup extends LightningElement {
    planOptions = [];
    selectedPlanId = '';
    subscriberId = '';
    hasInsurance = '';
    isLoading = true;
    isSubmitting = false;
    errorMessage = '';
    confirmingChange = false;
    plansLoaded = false;
    patientLoaded = false;
    setupCompleted = false;
    patientLoadFailed = false;

    // Values as last loaded or saved, used to tell whether the patient has unsaved changes.
    savedHasInsurance = '';
    savedPlanId = '';
    savedSubscriberId = '';

    insuranceOptions = [
        { label: 'Yes, I have insurance', value: 'yes' },
        { label: "No, I'm paying for myself", value: 'no' }
    ];

    // Chrome's Back button can restore this page from its back/forward cache exactly as it
    // was when the patient left, including a stuck "Saving…" button. Nothing is saved by
    // Back; this just clears the leftover state when the page returns.
    pageShowHandler = (event) => {
        if (event.persisted) {
            this.isSubmitting = false;
            this.errorMessage = '';
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
        return (this.hasInsurance || '') !== this.savedHasInsurance
            || (this.selectedPlanId || '') !== this.savedPlanId
            || (this.subscriberId || '').trim() !== this.savedSubscriberId;
    }

    connectedCallback() {
        window.addEventListener('pageshow', this.pageShowHandler);
        window.addEventListener('beforeunload', this.beforeUnloadHandler);
    }

    disconnectedCallback() {
        window.removeEventListener('pageshow', this.pageShowHandler);
        window.removeEventListener('beforeunload', this.beforeUnloadHandler);
    }

    rememberSavedValues() {
        this.savedHasInsurance = this.hasInsurance || '';
        this.savedPlanId = this.selectedPlanId || '';
        this.savedSubscriberId = (this.subscriberId || '').trim();
    }

    @wire(getInsurancePlans)
    wiredPlans({ data, error }) {
        this.plansLoaded = true;
        if (data) {
            this.planOptions = data.map((p) => ({ label: p.label, value: p.id }));
        } else if (error) {
            this.errorMessage = 'Could not load insurance plans. Please try again later.';
        }
        this.checkLoadingDone();
    }

    @wire(getCurrentPatient)
    wiredPatient({ data, error }) {
        this.patientLoaded = true;
        if (data) {
            // Setup counts as finished when the flag is set or a plan is saved
            // (self-pay patients have no plan).
            this.setupCompleted = !!(data.Insurance_Setup_Completed__c || data.Insurance_Plan__c);
            if (data.Insurance_Plan__c) {
                this.hasInsurance = 'yes';
                this.selectedPlanId = data.Insurance_Plan__c;
                this.subscriberId = data.Subscriber_ID__c || '';
            } else if (data.Insurance_Setup_Completed__c) {
                this.hasInsurance = 'no';
            }
        } else if (error) {
            this.patientLoadFailed = true;
            this.errorMessage = 'Could not load your current insurance details.';
        }
        this.rememberSavedValues();
        this.checkLoadingDone();
    }

    checkLoadingDone() {
        if (this.plansLoaded && this.patientLoaded) {
            this.isLoading = false;
        }
    }

    get showInsuranceFields() {
        return this.hasInsurance === 'yes';
    }

    get submitLabel() {
        return this.isSubmitting ? 'Saving…' : 'Save and Continue';
    }

    // First-time setup: hide the top menu until the patient has finished this page once.
    get hideMenu() {
        return !this.patientLoaded || (!this.setupCompleted && !this.patientLoadFailed);
    }

    get showBack() {
        return !this.hideMenu;
    }

    // The two answer cards ("Yes, I have insurance" / "No, I'm paying for myself").
    get optionCards() {
        return (this.insuranceOptions || []).map((o) => {
            const selected = o.value === this.hasInsurance;
            return {
                value: o.value,
                label: o.label,
                checked: selected ? 'true' : 'false',
                cls: selected ? 'ins-opt ins-opt-on' : 'ins-opt'
            };
        });
    }

    // A card click does what the old radio group did.
    handleOptionClick(event) {
        this.handleHasInsuranceChange({ detail: { value: event.currentTarget.dataset.value } });
    }

    handleOptionKey(event) {
        if (event.key === 'Enter' || event.key === ' ') {
            event.preventDefault();
            this.handleOptionClick(event);
        }
    }

    handleHasInsuranceChange(event) {
        this.hasInsurance = event.detail.value;
        // Picking an answer clears the "please answer" message.
        this.errorMessage = '';
    }

    handlePlanChange(event) {
        this.selectedPlanId = event.detail.value;
    }

    handleSubscriberIdChange(event) {
        this.subscriberId = event.target.value;
        const problem = this.subscriberIdProblem(this.subscriberId);
        event.target.setCustomValidity(problem || '');
        event.target.reportValidity();
    }

    // Loose check only: carriers use different ID layouts, so we do not match one exact
    // pattern. Accepts 5 to 20 characters of letters, numbers, dashes and spaces.
    subscriberIdProblem(value) {
        const id = (value || '').trim();
        if (!id) {
            return 'Please enter your Subscriber ID. You can find it on your insurance card.';
        }
        if (id.length < 5 || id.length > 20) {
            return 'Subscriber ID should be 5 to 20 characters. Check it against your insurance card.';
        }
        if (!/^[A-Za-z0-9 -]+$/.test(id)) {
            return 'Subscriber ID can only have letters, numbers, dashes and spaces.';
        }
        return null;
    }

    // Goes to the previous page (Profile Setup) without saving anything on this page.
    handleBack() {
        window.history.back();
    }

    // BUG-23: changing a saved Subscriber ID asks for confirmation first.
    get subscriberChangeMessage() {
        return `You're changing your Subscriber ID from ${this.savedSubscriberId} to ${(this.subscriberId || '').trim()}. `
            + 'Your coverage checks and estimates will use the new ID. Save this change?';
    }

    get changingSavedSubscriberId() {
        return this.hasInsurance === 'yes'
            && !!this.savedSubscriberId
            && (this.subscriberId || '').trim() !== this.savedSubscriberId;
    }

    handleCancelChange() {
        this.confirmingChange = false;
    }

    handleConfirmChange() {
        this.confirmingChange = false;
        this.handleSave(true);
    }

    handleSave(confirmed) {
        if (!this.hasInsurance) {
            this.errorMessage = 'Please answer whether you have insurance.';
            return;
        }
        if (this.hasInsurance === 'yes' && !this.selectedPlanId) {
            this.errorMessage = 'Please select your insurance provider.';
            return;
        }
        // Subscriber ID is needed to check bills against the plan, so it is required
        // whenever the patient has insurance.
        if (this.hasInsurance === 'yes') {
            const idProblem = this.subscriberIdProblem(this.subscriberId);
            if (idProblem) {
                this.errorMessage = idProblem;
                return;
            }
        }

        if (confirmed !== true && this.changingSavedSubscriberId) {
            this.errorMessage = '';
            this.confirmingChange = true;
            return;
        }

        this.errorMessage = '';
        this.isSubmitting = true;

        saveInsuranceSetup({
            hasInsurance: this.hasInsurance === 'yes',
            planId: this.selectedPlanId,
            subscriberId: this.hasInsurance === 'yes' ? this.subscriberId.trim() : ''
        })
            .then(() => {
                // Saved, so there is nothing left to warn about when we leave this page.
                this.rememberSavedValues();
                window.location.href = '/coveragechecker/';
            })
            .catch((error) => {
                this.isSubmitting = false;
                this.errorMessage = (error && error.body && error.body.message)
                    ? error.body.message
                    : 'Something went wrong. Please try again.';
            });
    }
}
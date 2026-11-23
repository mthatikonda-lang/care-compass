import { LightningElement, api } from 'lwc';
import forgotPassword from '@salesforce/apex/PatientLoginController.forgotPassword';

export default class PatientForgotPassword extends LightningElement {
    @api loginUrl = '/coveragechecker/login';

    username = '';
    errorMessage = '';
    isSubmitting = false;
    isSent = false;

    get isForm() {
        return !this.isSent;
    }
    get submitLabel() {
        return this.isSubmitting ? 'Sending…' : 'Send reset link';
    }

    handleUsername(event) {
        this.username = event.target.value;
    }
    handleKey(event) {
        if (event.key === 'Enter') {
            this.handleSend();
        }
    }

    handleSend() {
        if (this.isSubmitting) return;
        this.errorMessage = '';
        if (!this.username.trim()) {
            this.errorMessage = 'Enter your username.';
            return;
        }
        this.isSubmitting = true;
        forgotPassword({ username: this.username })
            .then(() => {
                this.isSubmitting = false;
                this.isSent = true;
            })
            .catch((error) => {
                this.isSubmitting = false;
                this.errorMessage = (error && error.body && error.body.message)
                    ? error.body.message
                    : 'Something went wrong. Please try again.';
            });
    }

    goLogin() {
        window.location.href = this.loginUrl;
    }
}
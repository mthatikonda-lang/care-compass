import { LightningElement, api } from 'lwc';
import login from '@salesforce/apex/PatientLoginController.login';
import forgotPassword from '@salesforce/apex/PatientLoginController.forgotPassword';

export default class PatientLogin extends LightningElement {
    @api startUrl = '/coveragechecker/';
    @api registerUrl = '/coveragechecker/SelfRegister';
    @api employeeUrl = '/login';

    username = '';
    password = '';
    errorMessage = '';
    infoMessage = '';
    isSubmitting = false;
    showPassword = false;

    get submitLabel() {
        return this.isSubmitting ? 'Logging in…' : 'Log in';
    }
    get passwordType() {
        return this.showPassword ? 'text' : 'password';
    }
    get toggleLabel() {
        return this.showPassword ? 'Hide' : 'Show';
    }

    handleUsername(event) {
        this.username = event.target.value;
    }
    handlePassword(event) {
        this.password = event.target.value;
    }
    toggleShow() {
        this.showPassword = !this.showPassword;
    }
    handleKey(event) {
        if (event.key === 'Enter') {
            this.handleLogin();
        }
    }

    handleLogin() {
        if (this.isSubmitting) return;
        this.errorMessage = '';
        this.infoMessage = '';
        if (!this.username.trim() || !this.password) {
            this.errorMessage = 'Enter your username and password.';
            return;
        }
        this.isSubmitting = true;
        login({ username: this.username, password: this.password, startUrl: this.startUrl })
            .then((url) => {
                window.location.href = url;
            })
            .catch((error) => {
                this.isSubmitting = false;
                this.errorMessage = (error && error.body && error.body.message)
                    ? error.body.message
                    : 'Something went wrong. Please try again.';
            });
    }

    handleForgot() {
        this.errorMessage = '';
        this.infoMessage = '';
        if (!this.username.trim()) {
            this.errorMessage = 'Type your username above, then choose Forgot password.';
            return;
        }
        forgotPassword({ username: this.username })
            .then(() => {
                this.infoMessage = 'If that username exists, we have emailed a link to reset the password.';
            })
            .catch((error) => {
                this.errorMessage = (error && error.body && error.body.message)
                    ? error.body.message
                    : 'Something went wrong. Please try again.';
            });
    }

    goRegister() {
        window.location.href = this.registerUrl;
    }
}
import { LightningElement, api } from 'lwc';

export default class PatientCheckEmail extends LightningElement {
    @api loginUrl = '/coveragechecker/login';

    goLogin() {
        window.location.href = this.loginUrl;
    }
}
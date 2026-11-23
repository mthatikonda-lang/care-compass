import { LightningElement, api } from 'lwc';

// "About" page. The page text lives in aboutCare.html, so edit the wording there.
export default class AboutCare extends LightningElement {
    @api findCareUrl = '/coveragechecker/book-appointment';
    @api checkBillUrl = '/coveragechecker/coverage-checker';

    goFindCare() {
        window.location.href = this.findCareUrl;
    }
    goCheckBill() {
        window.location.href = this.checkBillUrl;
    }
}
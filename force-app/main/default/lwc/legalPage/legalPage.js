import { LightningElement, api } from 'lwc';

// Terms of use and Privacy notice. One component serves both pages: it shows the Privacy notice when
// the page address contains "privacy" and the Terms otherwise. The wording is in TERMS and PRIVACY below.
const UPDATED = 'October 27, 2026';

const TERMS = {
    heading: 'Terms of use',
    subtitle: 'The ground rules for using Care Compass.',
    sections: [
        ['About Care Compass', 'Care Compass helps patients compare a medical bill with their coverage and find in-network care. It is not a hospital, a doctor, an insurer or a payment service.'],
        ['Estimates, not advice', 'Everything Care Compass shows is an estimate based on the plan rules and prices we have on file. It is not medical, legal or financial advice. Your insurer and your provider set the final amount, and the insurer\'s decision on a claim is final. Always check with your provider or insurer before you rely on a figure.'],
        ['Not for emergencies', 'Care Compass does not provide medical care. If you think you are having an emergency, call 911 or go to the nearest emergency room.'],
        ['Callback requests', 'Sending a callback request does not book an appointment. The office decides whether and when to see you, and you confirm the date after the office calls you.'],
        ['Your account', 'Keep your password private. Give us accurate details, because the estimates depend on your plan information. You may stop using Care Compass at any time.'],
        ['Using the service fairly', 'Do not try to break, overload or misuse the service, and do not enter another person\'s information without their permission.'],
        ['No guarantees', 'The service is provided as it is. It may contain mistakes or be unavailable at times, and we do not promise that any estimate is correct.'],
        ['Changes to these terms', 'We may update these terms. The date at the top shows when they last changed.'],
        ['Contact', 'Questions about these terms: contact@carecompass.example.com.']
    ]
};

const PRIVACY = {
    heading: 'Privacy notice',
    subtitle: 'What Care Compass collects, why, and who sees it.',
    sections: [
        ['Who we are', 'Care Compass helps patients check medical bills against their coverage and find in-network care. This notice explains how we handle your information.'],
        ['What we collect', 'Your account details (name, email, phone number and date of birth), your insurance plan and member ID, the charges from bills you check, the callback requests you send and the date you confirm with an office. If you use WhatsApp, we also keep the messages in that conversation.'],
        ['Your bill files', 'When you upload a bill, the file is read for text only and the file itself is not saved. The text is read by an outside text-reading service, and we keep the charges from the bill so you can open it again from your dashboard.'],
        ['How we use it', 'To work out estimates, to show your bills, appointments and requests, to send a callback request to the doctor\'s office you choose, and to email you about your account and appointments (for example a confirmation, a reminder the day before, or a password reset).'],
        ['What the office receives', 'When you request a callback, the doctor\'s office receives your name, phone number, the visit type, your requested date and the reason you gave.'],
        ['Emails', 'Appointment emails contain the doctor, the office, the visit type, the date and an estimated cost. They do not contain health details beyond that.'],
        ['We do not sell your information', 'We do not sell your information or use it for advertising.'],
        ['Cookies', 'The site uses the cookies and storage needed to keep you logged in and to remember small things during your visit.'],
        ['Your choices', 'You can update your insurance and personal details on the My profile page. To ask us to correct or remove your information, contact us.'],
        ['Health and insurance information', 'Your insurance and bill details are used only for the purposes described above.'],
        ['Changes and contact', 'We may update this notice, and the date at the top shows when. Questions: contact@carecompass.example.com.']
    ]
};

export default class LegalPage extends LightningElement {
    @api kind; // optional: "terms" or "privacy". Normally decided from the page address.

    get content() {
        let k = (this.kind || '').toLowerCase();
        if (k !== 'terms' && k !== 'privacy') {
            let path = '';
            try { path = window.location.pathname.toLowerCase(); } catch (e) { path = ''; }
            k = path.includes('privacy') ? 'privacy' : 'terms';
        }
        return k === 'privacy' ? PRIVACY : TERMS;
    }
    get heading() { return this.content.heading; }
    get subtitle() { return `${this.content.subtitle} Last updated ${UPDATED}.`; }
    get sections() {
        return this.content.sections.map(([title, text], i) => ({ key: `s${i}`, title, text }));
    }
}
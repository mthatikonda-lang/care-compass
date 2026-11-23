import { LightningElement, api } from 'lwc';

// Help page. The questions and answers live in FAQ below, so edit the wording here.
const FAQ = [
    {
        title: 'Getting started',
        items: [
            ['What is Care Compass?', 'Care Compass brings your insurance plan, your doctors and your bills into one place so you can see what you are likely to owe, in plain language.'],
            ['Is my information private?', 'Your bill is read for text only and checked against your plan. The file itself is not saved, and your bill is not shared.'],
            ['How do I change my insurance or personal details?', 'Open My profile from the menu. Insurance and Personal details each have their own Edit button.']
        ]
    },
    {
        title: 'Finding care and booking',
        items: [
            ['How are doctors matched to my issue?', 'Describe what is going on in your own words. We match it to the right kind of doctor and show whether each doctor is in or out of your network.'],
            ['Is the price I see my final cost?', 'No. It is an estimate of what you pay after your plan, based on the price we have on file for that service. Your actual cost may differ. For some services the estimate covers the doctor\'s fee only, and lab tests or other tests are billed separately.'],
            ['Does requesting a callback book my appointment?', 'No. It sends a request to the office, and no time slot is booked. The office calls you to agree a time. After the call, tap Confirm on your dashboard and enter the date you agreed. Then it becomes a confirmed appointment, and we email you a reminder the day before.'],
            ['I already have a request with this doctor. Can I send another?', 'Yes. We show a notice so you know about the earlier request, but we never stop you from sending another.']
        ]
    },
    {
        title: 'Checking a bill',
        items: [
            ['How do I check a bill?', 'Upload a PDF, PNG or JPG of your itemized bill, or type the line items yourself with one charge per line: a description, an optional 5-digit CPT code, then the amount. Add the bill number, then choose Analyze Bill.'],
            ['Why do I need to enter the bill number?', 'The bill number lets us recognise the same bill. If you check it again, we update that bill instead of saving a copy.'],
            ['What does "Not matched" mean?', 'We could not match that charge to a service in your plan rules, so we cannot say how your plan treats it. Ask your provider or insurer about that line.'],
            ['What does "priced above the typical rate" mean?', 'That charge is higher than the typical price we have for the same service. Ask the provider to review it. We write a letter and a phone script you can use.'],
            ['How do I keep a copy of my result?', 'Choose Download summary, then pick Save as PDF in the print window. You can also open any bill again from Recent bills on your dashboard.']
        ]
    },
    {
        title: 'Insurance words, in plain English',
        items: [
            ['Deductible', 'What you pay yourself each year before your insurance starts paying its share.'],
            ['Copay', 'A fixed amount you pay for a visit or service.'],
            ['Coinsurance', 'Your share, as a percentage, of costs after the deductible.'],
            ['Out-of-pocket maximum', 'The most you pay in a year for covered care. After that, your plan pays the rest.'],
            ['In-network and out-of-network', 'In-network doctors have an agreement with your insurance, so you usually pay less. Out-of-network doctors do not, so you may pay more, up to the full price.']
        ]
    },
    {
        title: 'Your account',
        items: [
            ['I forgot my password.', 'On the log in page choose Forgot password and enter your username. We email you a link to set a new one. The message looks the same whether or not the username exists, so check your spam folder if nothing arrives.'],
            ['Where do I see my past requests and appointments?', 'On your dashboard. Confirmed appointments, requests waiting for the office, request history and recent bills each show three at a time, with a Show more button.']
        ]
    }
];

export default class HelpCenter extends LightningElement {
    @api findCareUrl = '/coveragechecker/book-appointment';
    @api checkBillUrl = '/coveragechecker/coverage-checker';

    get groups() {
        return FAQ.map((g, gi) => ({
            key: `g${gi}`,
            title: g.title,
            items: g.items.map(([q, a], i) => ({ key: `g${gi}-${i}`, question: q, answer: a }))
        }));
    }

    goFindCare() {
        window.location.href = this.findCareUrl;
    }
    goCheckBill() {
        window.location.href = this.checkBillUrl;
    }
}
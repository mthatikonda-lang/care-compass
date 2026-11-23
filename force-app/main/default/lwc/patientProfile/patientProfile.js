import { LightningElement, api, wire } from 'lwc';
import getProfile from '@salesforce/apex/ProfileViewController.getProfile';

const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

function money(v) {
    if (v === null || v === undefined) return '—';
    return new Intl.NumberFormat('en-US', { style: 'currency', currency: 'USD', maximumFractionDigits: 0 }).format(v);
}

export default class PatientProfile extends LightningElement {
    @api editInsuranceUrl = '/coveragechecker/insurance-setup';
    @api editProfileUrl = '/coveragechecker/profile-setup?from=profile';

    profile;
    error;
    loaded = false;

    @wire(getProfile)
    wiredProfile({ data, error }) {
        if (data) {
            this.profile = data;
            this.error = undefined;
        } else if (error) {
            this.error = error?.body?.message || 'We could not load your profile.';
        }
        if (data || error) this.loaded = true;
    }

    get hasData() {
        return !!this.profile;
    }
    get initials() {
        const w = (this.profile?.fullName || '').replace(/[^A-Za-z\s]/g, ' ').split(/\s+/).filter((x) => x);
        if (!w.length) return '•';
        return (w.length === 1 ? w[0].slice(0, 2) : w[0][0] + w[1][0]).toUpperCase();
    }
    get insuranceRows() {
        const p = this.profile || {};
        return [
            { label: 'Plan', value: p.planName || '—' },
            { label: 'Member ID', value: p.memberId || '—' },
            { label: 'Deductible', value: money(p.deductible) },
            { label: 'Out-of-pocket max', value: money(p.outOfPocketMax) }
        ];
    }
    get personalRows() {
        const p = this.profile || {};
        let dob = '—';
        if (p.dateOfBirth) {
            const [y, m, d] = p.dateOfBirth.split('-').map(Number);
            dob = `${MONTHS[m - 1]} ${d}, ${y}`;
        }
        return [
            { label: 'Name', value: p.fullName || '—' },
            { label: 'Email', value: p.email || '—' },
            { label: 'Phone', value: p.phone || '—' },
            { label: 'Date of birth', value: dob },
            { label: 'Gender', value: p.gender || '—' }
        ];
    }
    goEditInsurance() {
        window.location.href = this.editInsuranceUrl;
    }
    goEditProfile() {
        window.location.href = this.editProfileUrl;
    }
}
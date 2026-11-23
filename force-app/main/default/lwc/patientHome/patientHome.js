import { LightningElement, wire } from 'lwc';
import getCurrentPatient from '@salesforce/apex/PatientHomeController.getCurrentPatient';

export default class PatientHome extends LightningElement {
    patient;
    isLoading = true;
    isProfileMenuOpen = false;

    @wire(getCurrentPatient)
    wiredPatient({ data, error }) {
        this.isLoading = false;
        if (data) {
            this.patient = data;
            if (!data.Profile_Completed__c) {
                window.location.href = '/coveragechecker/profile-setup';
            } else if (!data.Insurance_Setup_Completed__c) {
                window.location.href = '/coveragechecker/insurance-setup';
            }
        } else if (error) {
            this.patient = undefined;
        }
    }

    get initials() {
        if (!this.patient) return '';
        const first = this.patient.First_Name__c ? this.patient.First_Name__c.charAt(0) : '';
        const last = this.patient.Last_Name__c ? this.patient.Last_Name__c.charAt(0) : '';
        return (first + last).toUpperCase();
    }

    toggleProfileMenu() {
        this.isProfileMenuOpen = !this.isProfileMenuOpen;
    }

    handleLogout() {
        window.location.href = '/coveragechecker/secur/logout.jsp';
    }

    goToCoverageChecker() {
        window.location.href = '/coveragechecker/coverage-checker';
    }

    goToBookAppointment() {
        window.location.href = '/coveragechecker/book-appointment';
    }

    goToInsuranceSetup() {
        window.location.href = '/coveragechecker/insurance-setup';
    }

    // NEW: opens the My Dashboard page (confirm the URL in Page Properties)
    goToDashboard() {
        window.location.href = '/coveragechecker/my-dashboard';
    }
}
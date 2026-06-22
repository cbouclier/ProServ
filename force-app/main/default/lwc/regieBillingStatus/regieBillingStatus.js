import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getBillingOverview from '@salesforce/apex/RegieBillingController.getBillingOverview';

export default class RegieBillingStatus extends LightningElement {
    @api recordId;
    overview;
    months = [];
    openSections = [];
    wiredResult;

    @wire(getBillingOverview, { orderId: '$recordId' })
    wired(result) {
        this.wiredResult = result;
        if (result.data) {
            this.overview = result.data;
            this.months = (result.data.months || []).map((m) => ({
                ...m,
                badgeClass: 'slds-badge ' + this.variantClass(m.statusVariant),
                hasFrais: m.fraisLines && m.fraisLines.length > 0
            }));
            // mois Facturé collapsés par défaut, "À facturer" ouverts
            this.openSections = this.months.filter((m) => m.statusLabel !== 'Facturé').map((m) => m.monthIso);
        }
    }

    handleToggle(e) {
        this.openSections = e.detail.openSections;
    }

    variantClass(v) {
        if (v === 'success') return 'slds-theme_success';
        if (v === 'warning') return 'slds-badge_lightest slds-text-color_warning';
        return 'slds-badge_inverse';
    }

    refresh() {
        return refreshApex(this.wiredResult);
    }

    get hasMonths() {
        return this.months && this.months.length > 0;
    }
}
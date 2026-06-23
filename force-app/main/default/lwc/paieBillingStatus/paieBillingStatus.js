import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import getBillingOverview from '@salesforce/apex/PaieBillingController.getBillingOverview';

export default class PaieBillingStatus extends LightningElement {
    @api recordId;
    overview;
    months = [];
    wiredResult;

    @wire(getBillingOverview, { orderId: '$recordId' })
    wired(result) {
        this.wiredResult = result;
        if (result.data) {
            this.overview = result.data;
            this.months = result.data.months || [];
        }
    }

    get hasMonths() { return this.months && this.months.length > 0; }
    refresh() { return refreshApex(this.wiredResult); }
}
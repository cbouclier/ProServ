import { LightningElement, api } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { RefreshEvent } from 'lightning/refresh';
import invoiceMilestone from '@salesforce/apex/MilestoneBillingController.invoiceMilestone';
import linkInvoices from '@salesforce/apex/MilestoneBillingController.linkInvoices';

export default class MilestoneFacturerAction extends LightningElement {
    @api recordId;

    @api async invoke() {
        try {
            const res = await invoiceMilestone({ orderId: this.recordId });
            await this.pollLink();
            this.toast('Jalon facturé', res, 'success');
            this.dispatchEvent(new RefreshEvent());
        } catch (e) {
            this.toast('Erreur', this.msg(e), 'error');
        }
    }

    async pollLink() {
        for (let i = 0; i < 5; i++) {
            // eslint-disable-next-line no-await-in-loop
            await new Promise((r) => setTimeout(r, 2500));
            // eslint-disable-next-line no-await-in-loop
            const n = await linkInvoices({ orderId: this.recordId });
            if (n > 0) return;
        }
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    msg(e) {
        return e && e.body && e.body.message ? e.body.message : e && e.message ? e.message : 'Erreur inconnue';
    }
}
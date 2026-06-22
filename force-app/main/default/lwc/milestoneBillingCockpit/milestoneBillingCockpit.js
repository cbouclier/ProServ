import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { RefreshEvent } from 'lightning/refresh';
import LightningConfirm from 'lightning/confirm';
import getMilestones from '@salesforce/apex/MilestoneBillingController.getMilestones';
import accomplishMilestone from '@salesforce/apex/MilestoneBillingController.accomplishMilestone';
import invoiceMilestone from '@salesforce/apex/MilestoneBillingController.invoiceMilestone';
import linkInvoices from '@salesforce/apex/MilestoneBillingController.linkInvoices';

export default class MilestoneBillingCockpit extends LightningElement {
    @api recordId;
    overview;
    jalons = [];
    loading = false;
    wiredResult;

    @wire(getMilestones, { orderId: '$recordId' })
    wired(result) {
        this.wiredResult = result;
        if (result.data) {
            this.overview = result.data;
            this.jalons = result.data.jalons || [];
        }
    }

    get hasJalons() {
        return this.jalons && this.jalons.length > 0;
    }

    async handleAccomplish(e) {
        const name = e.target.dataset.name;
        const ok = await LightningConfirm.open({
            label: 'Réaliser le jalon',
            theme: 'warning',
            message: `Marquer « ${name} » comme réalisé ? Le montant correspondant deviendra facturable.`
        });
        if (!ok) return;
        this.loading = true;
        try {
            const msg = await accomplishMilestone({ orderId: this.recordId, milestoneName: name });
            this.toast('Jalon réalisé', msg, 'success');
            await refreshApex(this.wiredResult);
            this.dispatchEvent(new RefreshEvent());
        } catch (err) {
            this.toast('Erreur', err.body ? err.body.message : err.message, 'error');
        } finally {
            this.loading = false;
        }
    }

    async handleInvoice(e) {
        const name = e.target.dataset.name;
        const ok = await LightningConfirm.open({
            label: 'Facturer le jalon',
            theme: 'warning',
            message: `Facturer et poster « ${name} » ? La facture postée est définitive.`
        });
        if (!ok) return;
        this.loading = true;
        try {
            const msg = await invoiceMilestone({ orderId: this.recordId });
            await this.pollLink();
            this.toast('Jalon facturé', msg, 'success');
            await refreshApex(this.wiredResult);
            this.dispatchEvent(new RefreshEvent());
        } catch (err) {
            this.toast('Erreur', err.body ? err.body.message : err.message, 'error');
        } finally {
            this.loading = false;
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

    refresh() {
        return refreshApex(this.wiredResult);
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
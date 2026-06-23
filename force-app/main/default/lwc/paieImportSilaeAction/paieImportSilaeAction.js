import { LightningElement, api, track, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CloseActionScreenEvent } from 'lightning/actions';
import { publish, MessageContext } from 'lightning/messageService';
import REFRESH_CHANNEL from '@salesforce/messageChannel/RegieRefresh__c';
import simulerImportSilae from '@salesforce/apex/PaieBillingController.simulerImportSilae';

const FR = ['Janvier', 'Février', 'Mars', 'Avril', 'Mai', 'Juin',
    'Juillet', 'Août', 'Septembre', 'Octobre', 'Novembre', 'Décembre'];

export default class PaieImportSilaeAction extends LightningElement {
    @api recordId;
    @track monthOptions = [];
    selectedMonth;
    loading = false;

    @wire(MessageContext) messageContext;

    connectedCallback() {
        const now = new Date();
        const opts = [];
        // 3 mois passés -> 9 mois à venir
        for (let i = -3; i <= 9; i++) {
            const d = new Date(now.getFullYear(), now.getMonth() + i, 1);
            const mm = String(d.getMonth() + 1).padStart(2, '0');
            opts.push({ label: `${FR[d.getMonth()]} ${d.getFullYear()}`, value: `${d.getFullYear()}-${mm}-01` });
        }
        this.monthOptions = opts;
        this.selectedMonth = opts[3].value; // mois courant par défaut
    }

    handleChange(e) { this.selectedMonth = e.detail.value; }

    async handleImport() {
        this.loading = true;
        try {
            const res = await simulerImportSilae({ orderId: this.recordId, monthIso: this.selectedMonth });
            publish(this.messageContext, REFRESH_CHANNEL, {}); // rafraîchit le cockpit Paie
            this.close();
            this.toast('Import Silae', res, 'success');
        } catch (e) {
            this.toast('Erreur', this.msg(e), 'error');
            this.loading = false;
        }
    }

    close() { this.dispatchEvent(new CloseActionScreenEvent()); }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
    msg(e) {
        return e && e.body && e.body.message ? e.body.message : e && e.message ? e.message : 'Erreur inconnue';
    }
}
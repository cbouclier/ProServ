import { LightningElement, api, track, wire } from 'lwc';
import { loadStyle } from 'lightning/platformResourceLoader';
import RSM_STYLES from '@salesforce/resourceUrl/rsmCockpitStyles';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { RefreshEvent } from 'lightning/refresh';
import { subscribe, MessageContext } from 'lightning/messageService';
import REFRESH_CHANNEL from '@salesforce/messageChannel/RegieRefresh__c';
import getMonths from '@salesforce/apex/PaieBillingController.getMonths';
import simulerImportSilae from '@salesforce/apex/PaieBillingController.simulerImportSilae';
import saveLines from '@salesforce/apex/PaieBillingController.saveLines';
import prepareMonth from '@salesforce/apex/PaieBillingController.prepareMonth';
import createSchedules from '@salesforce/apex/PaieBillingController.createSchedules';
import finalizeForMonth from '@salesforce/apex/PaieBillingController.finalizeForMonth';
import createAndPostInvoice from '@salesforce/apex/PaieBillingController.createAndPostInvoice';
import linkInvoicesToOrder from '@salesforce/apex/PaieBillingController.linkInvoicesToOrder';

const COLUMNS = [
    { label: 'Mois', fieldName: 'monthLabel', cellAttributes: { class: 'slds-text-title_bold' } },
    { label: '✎ Nb bulletins', fieldName: 'nbBulletins', type: 'number', editable: true, initialWidth: 140,
        cellAttributes: { alignment: 'right', class: 'rsm-edit' } },
    { label: 'Prix unitaire', fieldName: 'prixUnitaire', type: 'currency', initialWidth: 130,
        typeAttributes: { currencyCode: 'EUR' }, cellAttributes: { alignment: 'right' } },
    { label: 'Montant HT', fieldName: 'montant', type: 'currency', initialWidth: 140,
        typeAttributes: { currencyCode: 'EUR', maximumFractionDigits: 0 },
        cellAttributes: { alignment: 'right', class: 'slds-text-title_bold' } },
    { label: 'Statut', fieldName: 'status', initialWidth: 110,
        cellAttributes: { class: { fieldName: 'statutClass' } } },
    { type: 'button', initialWidth: 130, typeAttributes: {
        label: 'Valider', name: 'validate', variant: 'brand-outline',
        disabled: { fieldName: 'cannotValidate' } } },
    { type: 'button', initialWidth: 150, typeAttributes: {
        label: 'Facturer', name: 'invoice', variant: 'success', iconName: 'utility:apex',
        disabled: { fieldName: 'cannotInvoice' } } }
];

const FR = ['Janvier', 'Février', 'Mars', 'Avril', 'Mai', 'Juin',
    'Juillet', 'Août', 'Septembre', 'Octobre', 'Novembre', 'Décembre'];

export default class PaieBillingCockpit extends LightningElement {
    @api recordId;
    columns = COLUMNS;
    @track months = [];
    @track draftValues = [];
    @track importMonthOptions = [];
    importMonth;
    loading = false;
    subscription;

    @wire(MessageContext) messageContext;

    buildMonthOptions() {
        const now = new Date();
        const opts = [];
        for (let i = -3; i <= 9; i++) {
            const d = new Date(now.getFullYear(), now.getMonth() + i, 1);
            const mm = String(d.getMonth() + 1).padStart(2, '0');
            opts.push({ label: `${FR[d.getMonth()]} ${d.getFullYear()}`, value: `${d.getFullYear()}-${mm}-01` });
        }
        this.importMonthOptions = opts;
        this.importMonth = opts[3].value;
    }

    handleImportMonth(e) { this.importMonth = e.detail.value; }

    async handleImport() {
        this.loading = true;
        try {
            const res = await simulerImportSilae({ orderId: this.recordId, monthIso: this.importMonth });
            this.toast('Import Silae', res, 'success');
            await this.load();
        } catch (e) {
            this.toast('Erreur', this.msg(e), 'error');
            this.loading = false;
        }
    }

    renderedCallback() {
        if (this._styled) return;
        this._styled = true;
        loadStyle(this, RSM_STYLES).catch(() => {});
    }

    connectedCallback() {
        this.buildMonthOptions();
        this.load();
        // Recharge quand l'Import Silae publie un refresh
        this.subscription = subscribe(this.messageContext, REFRESH_CHANNEL, () => this.load());
    }

    async load() {
        this.loading = true;
        try {
            const data = await getMonths({ orderId: this.recordId });
            this.months = (data || []).map((m) => ({
                ...m,
                statutClass: this.statutClass(m.status),
                cannotValidate: m.status !== 'Brouillon',
                cannotInvoice: m.status !== 'Validé'
            }));
            this.draftValues = [];
        } catch (e) {
            this.toast('Erreur de chargement', this.msg(e), 'error');
        }
        this.loading = false;
    }

    statutClass(s) {
        if (s === 'Facturé') return 'slds-text-color_success slds-text-title_bold';
        if (s === 'Validé') return 'slds-text-title_bold';
        return 'slds-text-color_weak';
    }

    get hasMonths() { return this.months && this.months.length > 0; }
    get totalAFacturer() {
        return this.months.filter((m) => m.status === 'Validé').reduce((s, m) => s + (m.montant || 0), 0);
    }
    get totalFacture() {
        return this.months.filter((m) => m.status === 'Facturé').reduce((s, m) => s + (m.montant || 0), 0);
    }

    async handleSave(e) {
        const payload = (e.detail.draftValues || []).map((d) => ({ id: d.planId, nbBulletins: d.nbBulletins }));
        if (!payload.length) return;
        this.loading = true;
        try {
            await saveLines({ linesJson: JSON.stringify(payload) });
            this.toast('Enregistré', 'Nombre de bulletins mis à jour.', 'success');
            await this.load();
        } catch (err) {
            this.toast('Erreur', this.msg(err), 'error');
            this.loading = false;
        }
    }

    handleRowAction(e) {
        const name = e.detail.action.name;
        const row = e.detail.row;
        if (name === 'validate') this.validate(row.monthIso);
        else if (name === 'invoice') this.invoice(row.monthIso, row.montant);
    }

    async validate(monthIso) {
        this.loading = true;
        try {
            await prepareMonth({ orderId: this.recordId, monthIso });
            await createSchedules({ orderId: this.recordId });
            const res = await this.pollFinalize(monthIso);
            this.toast('Échéancier généré', res, 'success');
            await this.load();
            this.dispatchEvent(new RefreshEvent());
        } catch (err) {
            this.toast('Erreur', this.msg(err), 'error');
            this.loading = false;
        }
    }

    async invoice(monthIso) {
        this.loading = true;
        try {
            const res = await createAndPostInvoice({ orderId: this.recordId, monthIso });
            await this.pollLink();
            this.toast('Facture postée', res, 'success');
            await this.load();
            this.dispatchEvent(new RefreshEvent());
        } catch (err) {
            this.toast('Erreur', this.msg(err), 'error');
            this.loading = false;
        }
    }

    async pollFinalize(monthIso) {
        for (let i = 0; i < 6; i++) {
            // eslint-disable-next-line no-await-in-loop
            await this.sleep(2500);
            // eslint-disable-next-line no-await-in-loop
            const res = await finalizeForMonth({ orderId: this.recordId, monthIso });
            if (res !== 'PENDING') return res;
        }
        return 'Génération lancée — les échéanciers apparaîtront dans un instant (rafraîchis).';
    }

    async pollLink() {
        for (let i = 0; i < 5; i++) {
            // eslint-disable-next-line no-await-in-loop
            await this.sleep(2500);
            // eslint-disable-next-line no-await-in-loop
            const n = await linkInvoicesToOrder({ orderId: this.recordId });
            if (n > 0) return;
        }
    }

    refresh() { return this.load(); }
    sleep(ms) {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        return new Promise((r) => setTimeout(r, ms));
    }
    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
    msg(e) {
        return e && e.body && e.body.message ? e.body.message : e && e.message ? e.message : 'Erreur inconnue';
    }
}
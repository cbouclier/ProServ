import { LightningElement, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import LightningConfirm from 'lightning/confirm';
import getMissions from '@salesforce/apex/GlobalBillingController.getMissions';
import facturerSelection from '@salesforce/apex/GlobalBillingController.facturerSelection';
import invoiceMilestone from '@salesforce/apex/MilestoneBillingController.invoiceMilestone';
import linkMilestoneInvoices from '@salesforce/apex/MilestoneBillingController.linkInvoices';
import invoicePaieOrder from '@salesforce/apex/PaieBillingController.invoiceOrder';
import linkPaieInvoices from '@salesforce/apex/PaieBillingController.linkInvoicesToOrder';

const FR = ['Janvier', 'Février', 'Mars', 'Avril', 'Mai', 'Juin',
    'Juillet', 'Août', 'Septembre', 'Octobre', 'Novembre', 'Décembre'];

const COLUMNS = [
    { label: 'Mission', fieldName: 'orderName', wrapText: true },
    { label: 'N°', fieldName: 'orderNumber', initialWidth: 90 },
    { label: 'Client', fieldName: 'account', initialWidth: 160 },
    { label: 'Modèle', fieldName: 'modelLabel', initialWidth: 100,
        cellAttributes: { class: { fieldName: 'modelClass' } } },
    { label: 'Staffing Napta à valider', fieldName: 'aValiderLabel', initialWidth: 170,
        cellAttributes: { class: { fieldName: 'aValiderClass' },
            iconName: { fieldName: 'aValiderIcon' }, iconPosition: 'left' } },
    { label: 'Montant HT', fieldName: 'montant', type: 'currency', initialWidth: 130,
        typeAttributes: { currencyCode: 'EUR', maximumFractionDigits: 0 },
        cellAttributes: { alignment: 'right' } },
    { label: 'Statut', fieldName: 'statut', initialWidth: 120,
        cellAttributes: { class: { fieldName: 'statutClass' } } },
    { type: 'button', initialWidth: 110, typeAttributes: {
        label: 'Ouvrir', name: 'open', variant: 'brand-outline',
        disabled: { fieldName: 'nonActionnable' } } },
    { type: 'button', initialWidth: 150, typeAttributes: {
        label: 'Facturer', name: 'invoice', variant: 'success', iconName: 'utility:apex',
        disabled: { fieldName: 'cannotInvoice' } } }
];

export default class CockpitFacturationGlobal extends LightningElement {
    columns = COLUMNS;
    monthOptions = [];
    selectedMonth;
    modelFilter = 'Tous';
    statutFilter = 'Tous';
    accountFilter = 'Tous';
    onlyAValider = false;
    summary;
    missions = [];
    selectedIds = [];
    loading = false;
    showModal = false;
    modalOrderId;
    modalTitle = '';
    modalModel = 'Regie';
    modalShowRecap = true; // recap affiché dans la modale (masqué sur la page Order)
    wiredResult;

    get modalIsRegie() { return this.modalModel === 'Regie'; }
    get modalIsForfait() { return this.modalModel === 'Forfait'; }
    get modalIsUsage() { return this.modalModel === 'Usage'; }

    connectedCallback() {
        const now = new Date();
        const opts = [];
        for (let i = 0; i < 12; i++) {
            const d = new Date(now.getFullYear(), now.getMonth() + i, 1);
            const mm = String(d.getMonth() + 1).padStart(2, '0');
            opts.push({ label: `${FR[d.getMonth()]} ${d.getFullYear()}`, value: `${d.getFullYear()}-${mm}-01` });
        }
        this.monthOptions = opts;
        this.selectedMonth = opts[0].value;
    }

    @wire(getMissions, { monthIso: '$selectedMonth' })
    wired(result) {
        this.wiredResult = result;
        if (result.data) {
            this.summary = result.data;
            this.missions = (result.data.missions || [])
                .map((m) => ({
                    ...m,
                    modelClass: this.modelClass(m.model),
                    statutClass: this.statutClass(m.statutVariant),
                    aValiderClass: m.hasAValider
                        ? 'slds-text-color_error slds-text-title_bold'
                        : 'slds-text-color_weak',
                    aValiderIcon: m.hasAValider ? 'utility:warning' : '',
                    // Facturable directement : régie -> mois validé ; forfait -> jalon réalisé non facturé
                    cannotInvoice: m.model === 'Forfait'
                        ? m.statut !== 'À facturer'
                        : m.statut !== 'Validé'
                }))
                // Missions avec staffing Napta à valider remontées en tête
                .sort((a, b) => (b.hasAValider ? 1 : 0) - (a.hasAValider ? 1 : 0));
        }
    }

    modelClass(model) {
        if (model === 'Regie') return 'slds-text-title_bold';
        if (model === 'Usage') return 'slds-text-color_default';
        return 'slds-text-color_weak';
    }
    statutClass(v) {
        if (v === 'success') return 'slds-text-color_success slds-text-title_bold';
        if (v === 'warning') return 'slds-text-color_error slds-text-title_bold';
        if (v === 'info') return 'slds-text-title_bold';
        return 'slds-text-color_weak';
    }

    get filteredMissions() {
        return this.missions.filter((m) =>
            (this.modelFilter === 'Tous' || m.modelLabel === this.modelFilter) &&
            (this.statutFilter === 'Tous' || m.statut === this.statutFilter) &&
            (this.accountFilter === 'Tous' || m.account === this.accountFilter) &&
            (!this.onlyAValider || m.hasAValider));
    }
    get accountOptions() {
        const set = new Set(this.missions.map((m) => m.account).filter(Boolean));
        return [{ label: 'Tous les clients', value: 'Tous' },
            ...[...set].map((a) => ({ label: a, value: a }))];
    }
    get modelOptions() {
        return [
            { label: 'Tous les modèles', value: 'Tous' },
            { label: 'Régie', value: 'Régie' },
            { label: 'Forfait', value: 'Forfait' },
            { label: 'Usage', value: 'Usage' }
        ];
    }
    get statutOptions() {
        return [
            { label: 'Tous les statuts', value: 'Tous' },
            { label: 'À valider', value: 'À valider' },
            { label: 'Validé', value: 'Validé' },
            { label: 'À réaliser', value: 'À réaliser' },
            { label: 'À facturer', value: 'À facturer' },
            { label: 'À activer', value: 'À activer' },
            { label: 'Facturé', value: 'Facturé' }
        ];
    }
    get hasMissions() { return this.filteredMissions.length > 0; }
    get noSelection() { return this.selectedIds.length === 0; }

    handleOnlyAValider(e) { this.onlyAValider = e.target.checked; }
    focusAValider() { this.onlyAValider = true; }
    handleMonth(e) { this.selectedMonth = e.detail.value; }
    handleModel(e) { this.modelFilter = e.detail.value; }
    handleStatut(e) { this.statutFilter = e.detail.value; }
    handleAccount(e) { this.accountFilter = e.detail.value; }

    handleRowSelection(e) {
        this.selectedIds = e.detail.selectedRows.map((r) => r.orderId);
    }
    handleRowAction(e) {
        const name = e.detail.action.name;
        const row = e.detail.row;
        if (name === 'open') {
            this.modalOrderId = row.orderId;
            this.modalTitle = row.orderName;
            this.modalModel = row.model; // 'Regie' | 'Forfait' | 'Usage'
            this.showModal = true;
        } else if (name === 'invoice') {
            this.invoiceOne(row);
        }
    }

    async invoiceOne(row) {
        const isForfait = row.model === 'Forfait';
        const isUsage = row.model === 'Usage';
        const ok = await LightningConfirm.open({
            label: 'Facturer & Poster',
            theme: 'warning',
            message: isForfait
                ? `Facturer et poster le jalon réalisé de « ${row.orderName} » ? La facture postée est définitive.`
                : `Facturer et poster les mois validés de « ${row.orderName} » ? La facture postée est définitive.`
        });
        if (!ok) return;
        this.loading = true;
        try {
            let msg;
            if (isForfait) {
                msg = await invoiceMilestone({ orderId: row.orderId });
                await this.pollMilestoneLink(row.orderId);
            } else if (isUsage) {
                msg = await invoicePaieOrder({ orderId: row.orderId });
                await this.pollPaieLink(row.orderId);
            } else {
                msg = await facturerSelection({ orderIds: [row.orderId] });
            }
            this.toast('Facturation', msg, 'success');
            await refreshApex(this.wiredResult);
        } catch (err) {
            this.toast('Erreur', err.body ? err.body.message : err.message, 'error');
        } finally {
            this.loading = false;
        }
    }

    async pollPaieLink(orderId) {
        for (let i = 0; i < 5; i++) {
            // eslint-disable-next-line no-await-in-loop
            await new Promise((r) => setTimeout(r, 2500));
            // eslint-disable-next-line no-await-in-loop
            const n = await linkPaieInvoices({ orderId });
            if (n > 0) return;
        }
    }

    async pollMilestoneLink(orderId) {
        for (let i = 0; i < 5; i++) {
            // eslint-disable-next-line no-await-in-loop
            await new Promise((r) => setTimeout(r, 2500));
            // eslint-disable-next-line no-await-in-loop
            const n = await linkMilestoneInvoices({ orderId });
            if (n > 0) return;
        }
    }
    closeModal() {
        this.showModal = false;
        this.modalOrderId = undefined;
        return refreshApex(this.wiredResult);
    }
    refresh() { return refreshApex(this.wiredResult); }

    async facturer() {
        if (this.noSelection) return;
        this.loading = true;
        try {
            const msg = await facturerSelection({ orderIds: this.selectedIds });
            this.toast('Facturation', msg, 'success');
            await refreshApex(this.wiredResult);
        } catch (err) {
            this.toast('Erreur', err.body ? err.body.message : err.message, 'error');
        } finally {
            this.loading = false;
        }
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
}
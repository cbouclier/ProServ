import { LightningElement, api, track, wire } from 'lwc';
import { loadStyle } from 'lightning/platformResourceLoader';
import RSM_STYLES from '@salesforce/resourceUrl/rsmCockpitStyles';
import { subscribe, MessageContext } from 'lightning/messageService';
import REFRESH_CHANNEL from '@salesforce/messageChannel/RegieRefresh__c';
import getMonths from '@salesforce/apex/RegieBillingController.getMonths';
import getOrderRecap from '@salesforce/apex/RegieBillingController.getOrderRecap';
import saveLines from '@salesforce/apex/RegieBillingController.saveLines';
import prepareMonth from '@salesforce/apex/RegieBillingController.prepareMonth';
import createSchedules from '@salesforce/apex/RegieBillingController.createSchedules';
import finalizeForMonth from '@salesforce/apex/RegieBillingController.finalizeForMonth';
import createAndPostInvoice from '@salesforce/apex/RegieBillingController.createAndPostInvoice';
import linkInvoicesToOrder from '@salesforce/apex/RegieBillingController.linkInvoicesToOrder';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { RefreshEvent } from 'lightning/refresh';

export default class RegieBillingCockpit extends LightningElement {
    @api recordId;
    @api showRecap = false; // récap masqué par défaut (page Order) ; activé dans la modale globale
    @track months = [];
    @track openSections = [];
    @track recap;
    loading = false;
    subscription;

    @wire(MessageContext) messageContext;

    renderedCallback() {
        if (this._stylesLoaded) return;
        this._stylesLoaded = true;
        loadStyle(this, RSM_STYLES).catch(() => {});
    }

    connectedCallback() {
        this.load();
        // Recharge automatiquement quand l'Import Napta publie un refresh
        this.subscription = subscribe(this.messageContext, REFRESH_CHANNEL, () => this.load());
    }

    async load() {
        this.loading = true;
        try {
            const [data, recap] = await Promise.all([
                getMonths({ orderId: this.recordId }),
                getOrderRecap({ orderId: this.recordId })
            ]);
            this.recap = recap;
            this.months = (data || []).map((m) => this.decorate(m));
            // Par défaut : on ouvre les mois NON facturés, on collapse les Facturé
            this.openSections = this.months.filter((m) => m.status !== 'Facturé').map((m) => m.monthIso);
        } catch (e) {
            this.toast('Erreur de chargement', this.msg(e), 'error');
        }
        this.loading = false;
    }

    handleToggle(e) {
        // On suit l'état d'ouverture choisi par l'utilisateur (évite que l'édition réexpande tout)
        this.openSections = e.detail.openSections;
    }

    decorate(m) {
        const withMontant = (l) => ({ ...l, montant: this.num(l.jours) * this.num(l.tjm) });
        const lines = (m.lines || []).map(withMontant);
        const fraisLines = (m.fraisLines || []).map(withMontant);
        const billed = m.status !== 'Brouillon';
        return {
            ...m,
            lines,
            fraisLines,
            hasFrais: fraisLines.length > 0,
            isBilled: billed, // verrouillé dès que les échéanciers sont générés
            canInvoice: m.status === 'Validé', // échéanciers générés mais pas encore facturés
            badgePill: 'slds-badge ' + this.theme(m.status),
            recomputedTotal: [...lines, ...fraisLines].reduce((s, l) => s + l.montant, 0),
            gradeColumns: this.colGrades(!billed),
            fraisColumns: this.colFrais(!billed)
        };
    }

    colGrades(editable) {
        return [
            { label: 'Grade', fieldName: 'grade', cellAttributes: { class: 'slds-text-title_bold' } },
            { label: 'Consultant', fieldName: 'consultant', cellAttributes: { class: 'slds-text-color_weak' } },
            { label: '✎ Jours', fieldName: 'jours', type: 'number', editable, initialWidth: 110,
                cellAttributes: { alignment: 'right', class: 'rsm-edit' }, typeAttributes: { step: '0.5' } },
            { label: '✎ TJM HT', fieldName: 'tjm', type: 'currency', editable, initialWidth: 130,
                cellAttributes: { alignment: 'right', class: 'rsm-edit' },
                typeAttributes: { currencyCode: 'EUR', maximumFractionDigits: 0 } },
            { label: 'Montant HT', fieldName: 'montant', type: 'currency', initialWidth: 140,
                cellAttributes: { alignment: 'right' },
                typeAttributes: { currencyCode: 'EUR', maximumFractionDigits: 0 } }
        ];
    }
    colFrais(editable) {
        // Largeurs alignées sur les grades (auto, auto, 110, 130, 140) -> pleine largeur + aligné.
        // Colonnes utiles : Frais, Qté (non éditable), Montant HT (éditable). Les 2 vides ne servent qu'au calage.
        return [
            { label: 'Frais', fieldName: 'grade', cellAttributes: { class: 'slds-text-title_bold' } },
            { label: '', fieldName: 'rsmBlank1' },
            { label: 'Qté', fieldName: 'jours', type: 'number', initialWidth: 110,
                cellAttributes: { alignment: 'right' } },
            { label: '', fieldName: 'rsmBlank2', initialWidth: 130 },
            { label: '✎ Montant HT', fieldName: 'tjm', type: 'currency', editable, initialWidth: 140,
                cellAttributes: { alignment: 'right', class: 'rsm-edit' },
                typeAttributes: { currencyCode: 'EUR', maximumFractionDigits: 0 } }
        ];
    }

    theme(status) {
        if (status === 'Facturé') return 'slds-theme_success';
        if (status === 'Validé') return 'slds-badge_lightest slds-text-color_success';
        return '';
    }

    // Lit les éditions inline en cours sur les datatables d'un mois (grades + frais)
    pendingDrafts(month) {
        const map = {};
        this.template
            .querySelectorAll(`lightning-datatable[data-month="${month}"]`)
            .forEach((dt) => {
                (dt.draftValues || []).forEach((d) => {
                    map[d.id] = { ...(map[d.id] || {}), ...d };
                });
            });
        return Object.values(map).map((d) => ({ id: d.id, jours: d.jours, tjm: d.tjm }));
    }

    clearDrafts() {
        this.template.querySelectorAll('lightning-datatable').forEach((dt) => {
            dt.draftValues = [];
        });
    }

    // Enregistrement via la barre native d'inline editing (onsave)
    async handleSave(e) {
        const payload = (e.detail.draftValues || []).map((d) => ({ id: d.id, jours: d.jours, tjm: d.tjm }));
        if (!payload.length) return;
        this.loading = true;
        try {
            await saveLines({ linesJson: JSON.stringify(payload) });
            this.clearDrafts();
            this.toast('Enregistré', 'Jours / TJM / frais mis à jour.', 'success');
            await this.load();
        } catch (err) {
            this.toast('Erreur', this.msg(err), 'error');
            this.loading = false;
        }
    }

    async handleValidate(e) {
        const month = e.target.dataset.month;
        this.loading = true;
        try {
            const pending = this.pendingDrafts(month);
            if (pending.length) await saveLines({ linesJson: JSON.stringify(pending) });
            this.clearDrafts();
            await prepareMonth({ orderId: this.recordId, monthIso: month });
            await createSchedules({ orderId: this.recordId });
            const res = await this.pollFinalize(month);
            // Grisage optimiste : on garde les valeurs saisies et on verrouille le mois tout de suite
            this.months = this.months.map((m) =>
                m.monthIso === month
                    ? {
                          ...m,
                          status: 'Validé',
                          isBilled: true,
                          badgePill: 'slds-badge slds-theme_success',
                          lines: m.lines.map((l) => ({ ...l, billed: true })),
                          fraisLines: m.fraisLines.map((l) => ({ ...l, billed: true }))
                      }
                    : m
            );
            this.toast('Échéanciers générés', res, 'success');
            await this.load();
            this.refreshPage();
        } catch (err) {
            this.toast('Erreur', this.msg(err), 'error');
            this.loading = false;
        }
    }

    async handleInvoice(e) {
        const month = e.target.dataset.month;
        this.loading = true;
        try {
            const res = await createAndPostInvoice({ orderId: this.recordId, monthIso: month });
            await this.pollLink(); // rattache l'invoice à l'order (async) pour la related list
            this.toast('Facture postée', res, 'success');
            await this.load();
            this.refreshPage();
        } catch (err) {
            this.toast('Erreur', this.msg(err), 'error');
            this.loading = false;
        }
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

    async pollFinalize(month) {
        for (let i = 0; i < 6; i++) {
            await this.sleep(2500);
            // eslint-disable-next-line no-await-in-loop
            const res = await finalizeForMonth({ orderId: this.recordId, monthIso: month });
            if (res !== 'PENDING') return res;
        }
        return 'Génération lancée — les échéanciers apparaîtront dans un instant (rafraîchis).';
    }

    sleep(ms) {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        return new Promise((r) => setTimeout(r, ms));
    }

    refreshPage() {
        // Rafraîchit les composants standard de la page (décompte sur Order Product, échéanciers...)
        this.dispatchEvent(new RefreshEvent());
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    num(v) {
        const n = Number(v);
        return isNaN(n) ? 0 : n;
    }

    msg(e) {
        return e && e.body && e.body.message ? e.body.message : e && e.message ? e.message : 'Erreur inconnue';
    }

    get hasMonths() {
        return this.months && this.months.length > 0;
    }

    get hasRecap() {
        return this.recap && this.recap.lines && this.recap.lines.length > 0;
    }

    get displayRecap() {
        return this.showRecap && this.hasRecap;
    }
}
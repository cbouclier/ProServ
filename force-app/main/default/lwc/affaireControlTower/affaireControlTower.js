import { LightningElement, api, wire } from 'lwc';
import { refreshApex } from '@salesforce/apex';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { RefreshEvent } from 'lightning/refresh';
import LightningConfirm from 'lightning/confirm';
import getPilotage from '@salesforce/apex/AffaireControlTowerController.getPilotage';
import genererFAE from '@salesforce/apex/AffaireControlTowerController.genererFAE';
import linkFAE from '@salesforce/apex/AffaireControlTowerController.linkFAE';
import setCoutReel from '@salesforce/apex/AffaireControlTowerController.setCoutReel';

export default class AffaireControlTower extends LightningElement {
    @api recordId;
    p;
    loading = false;
    wiredResult;
    editingCost = false;
    costInput;

    @wire(getPilotage, { orderId: '$recordId' })
    wired(result) {
        this.wiredResult = result;
        if (result.data) this.p = result.data;
        if (result.error) this.toast('Erreur de chargement', this.msg(result.error), 'error');
    }

    // ---- Modèle ----
    get isForfait() { return this.p && this.p.model === 'Forfait'; }
    get isUsage() { return this.p && this.p.isUsage; }
    get unite() { return this.isUsage ? 'bull.' : 'j'; }
    get gaugeSubLabel() {
        if (!this.p) return '';
        return this.isUsage
            ? `${this.p.tauxConsommation}% du contrat écoulé (${this.p.moisImportes}/${this.p.nbMois} mois)`
            : `${this.p.tauxConsommation}% du budget jours consommé`;
    }

    // ---- Hero / Boni-Mali ----
    get isBoni() { return this.p && this.p.boniMaliStatut === 'Boni'; }
    get isMali() { return this.p && this.p.boniMaliStatut === 'Mali'; }
    get rentabColorClass() {
        if (this.isBoni) return 'rsm-c-boni';
        if (this.isMali) return 'rsm-c-mali';
        return 'rsm-c-neutre';
    }
    get boniMaliLabel() {
        if (this.isBoni) return 'BONI';
        if (this.isMali) return 'MALI';
        return 'À L\'ÉQUILIBRE';
    }
    get boniMaliSignedAbs() { return this.p ? Math.abs(this.p.boniMali) : 0; }
    get boniMaliPctLabel() {
        if (!this.p) return '';
        const v = this.p.boniMaliPct;
        return `${v > 0 ? '+' : ''}${v}%`;
    }
    get boniMaliIcon() {
        if (this.isBoni) return 'utility:trending';
        if (this.isMali) return 'utility:trending';
        return 'utility:dash';
    }

    // ---- Avancement ----
    get avancement() { return this.p ? Math.round(this.p.avancement) : 0; }
    get avancementLabel() { return this.isForfait ? 'des jalons' : 'des jours'; }

    // ---- Jauges donut (style inline avec variables CSS) ----
    donut(pct, color) {
        const v = Math.max(0, Math.min(100, Math.round(pct || 0)));
        return `--p:${v};--c:${color}`;
    }
    get gaugeAvancement() { return this.donut(this.avancement, '#1b96ff'); }
    get gaugeFacturation() { return this.donut(this.p && this.p.tauxFacturation, '#2e844a'); }
    get gaugeMarge() { return this.donut(this.p && this.p.tauxMargeReelle, '#9050e9'); }
    get pctFacturation() { return this.p ? Math.round(this.p.tauxFacturation) : 0; }
    get pctMarge() { return this.p ? Math.round(this.p.tauxMargeReelle) : 0; }

    // ---- Barres Pilotage 360° (largeur relative au CA vendu) ----
    pctOf(v) {
        if (!this.p || !this.p.caVendu) return 0;
        return Math.max(0, Math.min(100, Math.round((v / this.p.caVendu) * 100)));
    }
    get barRealiseStyle() { return `width:${this.pctOf(this.p && this.p.produitRealise)}%`; }
    get barFactureStyle() { return `width:${this.pctOf(this.p && this.p.facture)}%`; }

    // ---- Coût saisi (forfait) ----
    get coutReelSaisi() { return this.p && this.p.coutReelSaisi; }
    // Coût réel manquant : forfait sans temps réel ni saisie -> rentabilité non calculable
    get coutReelManquant() {
        return this.isForfait && this.p && this.p.joursReelsEstimes && !this.p.coutReelSaisi;
    }
    get showCostInput() { return this.editingCost || this.coutReelManquant; }
    get canEditCost() { return this.isForfait && !this.showCostInput; }

    handleEditCost() {
        this.costInput = this.p ? this.p.coutReel : 0;
        this.editingCost = true;
    }
    handleCancelCost() { this.editingCost = false; }
    handleCostChange(e) { this.costInput = e.detail.value; }
    async saveCost() {
        if (this.costInput === undefined || this.costInput === null || this.costInput === '') return;
        this.loading = true;
        try {
            await setCoutReel({ orderId: this.recordId, montant: Number(this.costInput) });
            this.editingCost = false;
            this.toast('Coût réel enregistré', 'La rentabilité a été recalculée.', 'success');
            await refreshApex(this.wiredResult);
        } catch (err) {
            this.toast('Erreur', this.msg(err), 'error');
        } finally {
            this.loading = false;
        }
    }

    // ---- FAE ----
    get hasFae() { return this.p && this.p.fae > 0; }
    get faeMaterialisee() { return this.p && this.p.faeDraft > 0; }

    // ---- Actions ----
    async handleGenererFae() {
        const ok = await LightningConfirm.open({
            label: 'Générer la FAE',
            theme: 'info',
            message: `Générer la Facture À Établir (Draft) pour ${this.fmt(this.p.fae)} de réalisé non facturé ? ` +
                'Aucune facture n\'est postée : la Draft reste modifiable jusqu\'à validation.'
        });
        if (!ok) return;
        this.loading = true;
        try {
            const res = await genererFAE({ orderId: this.recordId });
            await this.pollLink();
            this.toast('FAE générée', res, 'success');
            await refreshApex(this.wiredResult);
            this.dispatchEvent(new RefreshEvent());
        } catch (err) {
            this.toast('Erreur', this.msg(err), 'error');
        } finally {
            this.loading = false;
        }
    }

    async pollLink() {
        for (let i = 0; i < 5; i++) {
            // eslint-disable-next-line no-await-in-loop
            await new Promise((r) => setTimeout(r, 2500));
            // eslint-disable-next-line no-await-in-loop
            const n = await linkFAE({ orderId: this.recordId });
            if (n > 0) return;
        }
    }

    refresh() { return refreshApex(this.wiredResult); }

    // ---- Utils ----
    fmt(v) {
        return new Intl.NumberFormat('fr-FR', {
            style: 'currency', currency: 'EUR', maximumFractionDigits: 0
        }).format(v || 0);
    }
    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }
    msg(e) {
        return e && e.body && e.body.message ? e.body.message : e && e.message ? e.message : 'Erreur inconnue';
    }
}
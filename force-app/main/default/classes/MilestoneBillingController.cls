/**
 * Cockpit Facturation Forfait / Jalons.
 * Lit les BillingMilestonePlanItem de la commande (générés à l'activation depuis le
 * treatment Jalon), les agrège par étape, ordonne via ProcessingOrder du treatment, et
 * permet de "réaliser" un jalon (IsMilestoneAccomplished = true) → l'échéance devient
 * facturable. Enchaînement SÉQUENTIEL : un jalon n'est réalisable que si le précédent
 * est réalisé ET facturé.
 */
public with sharing class MilestoneBillingController {

    public class MilestoneRow implements Comparable {
        @AuraEnabled public String name;            // étape
        @AuraEnabled public Decimal percentage;     // %
        @AuraEnabled public Decimal montant;        // montant total (toutes lignes) de l'étape
        @AuraEnabled public String statut;          // 'À réaliser' | 'Réalisé' | 'Facturé'
        @AuraEnabled public String statutVariant;
        @AuraEnabled public String badgeClass;
        @AuraEnabled public Boolean canAccomplish;  // réalisable maintenant
        @AuraEnabled public Boolean canInvoice;     // réalisé, à facturer
        @AuraEnabled public Boolean invoiced;       // réalisé ET facturé
        @AuraEnabled public Boolean accomplished;   // déjà réalisé
        @AuraEnabled public Boolean locked;         // bloqué (jalon précédent pas encore facturé)
        @AuraEnabled public String lockReason;
        @AuraEnabled public Integer nbLignes;
        @AuraEnabled public Date accomplishmentDate;
        public Integer sortOrder;

        public Integer compareTo(Object o) {
            Integer p = ((MilestoneRow) o).sortOrder;
            return sortOrder < p ? -1 : (sortOrder > p ? 1 : 0);
        }
    }
    public class Overview {
        @AuraEnabled public String orderName;
        @AuraEnabled public Decimal total;
        @AuraEnabled public Decimal totalRealise;
        @AuraEnabled public Decimal totalReste;
        @AuraEnabled public Integer avancement;
        @AuraEnabled public Integer nbJalons;
        @AuraEnabled public Integer nbRealises;
        @AuraEnabled public List<MilestoneRow> jalons;
    }

    @AuraEnabled(cacheable=true)
    public static Overview getMilestones(Id orderId) {
        Overview ov = new Overview();
        ov.total = 0; ov.totalRealise = 0; ov.totalReste = 0;
        ov.avancement = 0; ov.nbJalons = 0; ov.nbRealises = 0;
        ov.jalons = new List<MilestoneRow>();
        for (Order o : [SELECT Name FROM Order WHERE Id = :orderId]) ov.orderName = o.Name;

        // Ordre des étapes depuis le treatment (ProcessingOrder)
        Id treatmentId;
        for (OrderItem oi : [SELECT BillingTreatmentId FROM OrderItem
                WHERE OrderId = :orderId AND BillingTreatmentId != null LIMIT 1])
            treatmentId = oi.BillingTreatmentId;
        Map<String, Integer> orderByName = new Map<String, Integer>();
        if (treatmentId != null)
            for (BillingTreatmentItem ti : [SELECT Name, ProcessingOrder
                    FROM BillingTreatmentItem WHERE BillingTreatmentId = :treatmentId])
                orderByName.put(ti.Name, ti.ProcessingOrder == null ? 9999 : ti.ProcessingOrder);

        Map<String, MilestoneRow> byName = new Map<String, MilestoneRow>();
        Map<String, Boolean> allInvoiced = new Map<String, Boolean>();
        Integer seen = 0;
        for (BillingMilestonePlanItem it : [
                SELECT Name, Percentage, MilestoneAmount, Status, IsMilestoneAccomplished, MilestoneAccomplishmentDate
                FROM BillingMilestonePlanItem
                WHERE BillingMilestonePlanId IN (
                    SELECT BillingMilestonePlanId FROM BillingSchedule WHERE ReferenceEntityId = :orderId)
                ORDER BY CreatedDate, Name]) {

            MilestoneRow r = byName.get(it.Name);
            if (r == null) {
                r = new MilestoneRow();
                r.name = it.Name; r.percentage = it.Percentage; r.montant = 0;
                r.accomplished = true; r.nbLignes = 0;
                r.sortOrder = orderByName.containsKey(it.Name) ? orderByName.get(it.Name) : (10000 + seen);
                seen++;
                byName.put(it.Name, r); allInvoiced.put(it.Name, true);
            }
            r.montant += (it.MilestoneAmount == null ? 0 : it.MilestoneAmount);
            r.nbLignes++;
            if (it.IsMilestoneAccomplished != true) r.accomplished = false;
            if (it.Status != 'Invoiced') allInvoiced.put(it.Name, false);
            if (it.MilestoneAccomplishmentDate != null && r.accomplishmentDate == null)
                r.accomplishmentDate = it.MilestoneAccomplishmentDate;
        }

        // Statut + totaux
        List<MilestoneRow> rows = byName.values();
        for (MilestoneRow r : rows) {
            r.canInvoice = false; r.invoiced = false;
            if (r.accomplished && allInvoiced.get(r.name)) {
                r.statut = 'Facturé'; r.statutVariant = 'success'; r.badgeClass = 'slds-badge slds-theme_success';
                r.invoiced = true;
            } else if (r.accomplished) {
                r.statut = 'Réalisé'; r.statutVariant = 'info'; r.badgeClass = 'slds-badge slds-badge_lightest slds-text-color_default';
                r.canInvoice = true;
            } else {
                r.statut = 'À réaliser'; r.statutVariant = 'warning'; r.badgeClass = 'slds-badge slds-badge_lightest slds-text-color_warning';
            }
            ov.total += r.montant;
            if (r.accomplished) { ov.totalRealise += r.montant; ov.nbRealises++; }
        }
        rows.sort();   // par ProcessingOrder : Lancement -> Validation -> Clôture

        // Séquentiel : réalisable seulement si le précédent est FACTURÉ
        for (Integer i = 0; i < rows.size(); i++) {
            MilestoneRow r = rows[i];
            r.locked = false;
            if (r.accomplished) {
                r.canAccomplish = false;
            } else if (i == 0) {
                r.canAccomplish = true;
            } else if (rows[i - 1].statut == 'Facturé') {
                r.canAccomplish = true;
            } else {
                r.canAccomplish = false;
                r.locked = true;
                r.lockReason = 'Réalisez et facturez d\'abord « ' + rows[i - 1].name + ' »';
            }
        }

        ov.jalons = rows;
        ov.nbJalons = rows.size();
        ov.totalReste = ov.total - ov.totalRealise;
        ov.avancement = ov.total > 0
            ? ((ov.totalRealise / ov.total) * 100).setScale(0, System.RoundingMode.HALF_UP).intValue() : 0;
        return ov;
    }

    /** Réalise un jalon (IsMilestoneAccomplished = true) — refuse si bloqué ou déjà réalisé. */
    @AuraEnabled
    public static String accomplishMilestone(Id orderId, String milestoneName) {
        // Contrôle séquentiel côté serveur
        Overview ov = getMilestones(orderId);
        for (MilestoneRow r : ov.jalons) {
            if (r.name == milestoneName) {
                if (r.accomplished) throw new AuraHandledException('« ' + milestoneName + ' » est déjà réalisé.');
                if (r.locked) throw new AuraHandledException(r.lockReason + ' avant « ' + milestoneName + ' ».');
            }
        }
        List<BillingMilestonePlanItem> items = [
            SELECT Id FROM BillingMilestonePlanItem
            WHERE Name = :milestoneName AND IsMilestoneAccomplished = false
            AND BillingMilestonePlanId IN (
                SELECT BillingMilestonePlanId FROM BillingSchedule WHERE ReferenceEntityId = :orderId)];
        if (items.isEmpty())
            throw new AuraHandledException('Aucun jalon à réaliser pour « ' + milestoneName + ' ».');
        for (BillingMilestonePlanItem it : items) it.IsMilestoneAccomplished = true;
        update items;
        return '« ' + milestoneName + ' » réalisé sur ' + items.size() + ' ligne(s) — montant facturable.';
    }

    /**
     * Facture le(s) jalon(s) réalisé(s) : génère + poste la facture des échéances ReadyForInvoicing
     * de la commande (le jalon courant). Utilisé par le bouton du LWC et la Quick Action globale.
     */
    @AuraEnabled
    public static String invoiceMilestone(Id orderId) {
        List<String> bsIds = new List<String>();
        for (BillingSchedule bs : [SELECT Id FROM BillingSchedule
                WHERE ReferenceEntityId = :orderId AND Status = 'ReadyForInvoicing'])
            bsIds.add(String.valueOf(bs.Id));
        if (bsIds.isEmpty())
            throw new AuraHandledException('Aucun jalon réalisé à facturer — réalise d\'abord un jalon.');

        Date t = Date.today();
        String tStr = DateTime.newInstance(t.year(), t.month(), t.day(), 0, 0, 0).format('yyyy-MM-dd');

        if (!Test.isRunningTest()) {
            ConnectApi.InvoiceInputRepresentation inp = new ConnectApi.InvoiceInputRepresentation();
            inp.billingScheduleIds = bsIds;
            inp.action = ConnectApi.InvoiceAction.Posted;
            inp.invoiceDate = tStr;
            inp.targetDate = tStr;
            ConnectApi.RevenueAsyncRepresentation res = ConnectApi.Billing.generateInvoices(inp);
            if (res == null || !res.success)
                throw new AuraHandledException('Échec facturation : ' + (res == null ? '' : String.valueOf(res.errors)));
        }
        return 'Jalon facturé et posté (' + bsIds.size() + ' échéance(s)).';
    }

    /** Rattache les factures du jalon à l'order (ReferenceEntityId) pour la related list. Appelée en polling (génération async). */
    @AuraEnabled
    public static Integer linkInvoices(Id orderId) {
        Set<Id> invIds = new Set<Id>();
        for (InvoiceLine il : [SELECT InvoiceId FROM InvoiceLine
                WHERE BillingSchedule.ReferenceEntityId = :orderId AND Invoice.ReferenceEntityId = null])
            if (il.InvoiceId != null) invIds.add(il.InvoiceId);
        List<Invoice> toUpd = new List<Invoice>();
        for (Id i : invIds) toUpd.add(new Invoice(Id = i, ReferenceEntityId = orderId));
        if (!toUpd.isEmpty()) update toUpd;
        return toUpd.size();
    }
}
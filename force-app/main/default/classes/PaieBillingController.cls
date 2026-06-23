/**
 * Cockpit Paie (modèle Usage / Social).
 * Variante simplifiée de la régie : 1 ligne "Bulletin de paie" par mois,
 * montant = NbBulletins × PrixUnitaire. Import Silae mensuel → BS one-shot → facture,
 * via le MÊME pipeline standalone que la régie (createBillingSchedulesFromTrxn + treatment Arrears).
 */
public with sharing class PaieBillingController {

    @TestVisible private static final String CTX_DEF  = 'RLM_BillingContext';
    @TestVisible private static final String READ_MAP = 'OrderEntitiesMapping';
    @TestVisible private static final String SAVE_MAP = 'BSGEntitiesMapping';

    // Résolution dynamique du Billing Treatment (portable entre orgs)
    @TestVisible private static Id regieTreatmentId;
    private static Id getRegieTreatmentId() {
        if (regieTreatmentId == null) {
            List<BillingTreatment> bt = [
                SELECT Id FROM BillingTreatment
                WHERE Name = 'Régie Mensuelle (Arrears)' LIMIT 1];
            if (bt.isEmpty())
                throw new AuraHandledException(
                    'Billing Treatment "Régie Mensuelle (Arrears)" introuvable — vérifiez la configuration Revenue Cloud.');
            regieTreatmentId = bt[0].Id;
        }
        return regieTreatmentId;
    }

    private static final Decimal PRIX_DEFAUT = 12;

    private static final Map<Integer,String> MOIS_FR = new Map<Integer,String>{
        1=>'Janvier',2=>'Février',3=>'Mars',4=>'Avril',5=>'Mai',6=>'Juin',
        7=>'Juillet',8=>'Août',9=>'Septembre',10=>'Octobre',11=>'Novembre',12=>'Décembre'};

    // ---------- DTO ----------
    public class PaieMonth {
        @AuraEnabled public Id planId;
        @AuraEnabled public String monthIso;
        @AuraEnabled public String monthLabel;
        @AuraEnabled public String status;          // Brouillon | Validé | Facturé
        @AuraEnabled public Decimal nbBulletins;
        @AuraEnabled public Decimal prixUnitaire;
        @AuraEnabled public Decimal montant;
        @AuraEnabled public Boolean billed;         // BS généré
    }

    // ---------- Lecture ----------
    @AuraEnabled
    public static List<PaieMonth> getMonths(Id orderId) {
        List<PaieMonth> out = new List<PaieMonth>();
        for (RSM_PaieBillingPlan__c p : [
                SELECT Id, BillingMonth__c, NbBulletins__c, PrixUnitaire__c, Montant__c,
                       Status__c, BillingScheduleId__c
                FROM RSM_PaieBillingPlan__c
                WHERE Order__c = :orderId
                ORDER BY BillingMonth__c ASC]) {
            PaieMonth g = new PaieMonth();
            g.planId = p.Id;
            g.monthIso = p.BillingMonth__c == null ? '' : String.valueOf(p.BillingMonth__c);
            g.monthLabel = p.BillingMonth__c == null ? 'Sans mois'
                : MOIS_FR.get(p.BillingMonth__c.month()) + ' ' + p.BillingMonth__c.year();
            g.status = p.Status__c;
            g.nbBulletins = p.NbBulletins__c;
            g.prixUnitaire = p.PrixUnitaire__c;
            g.montant = p.Montant__c == null ? 0 : p.Montant__c;
            g.billed = p.BillingScheduleId__c != null;
            out.add(g);
        }
        return out;
    }

    // ---------- Suivi de facturation (mois Validé / Facturé) ----------
    public class PBMonth {
        @AuraEnabled public String monthIso;
        @AuraEnabled public String monthLabel;
        @AuraEnabled public Decimal nbBulletins;
        @AuraEnabled public Decimal prixUnitaire;
        @AuraEnabled public Decimal total;
        @AuraEnabled public String statusLabel;
        @AuraEnabled public String statusVariant;
        @AuraEnabled public String badgeClass;
    }
    public class PBOverview {
        @AuraEnabled public Decimal totalValide;
        @AuraEnabled public Decimal totalAFacturer;
        @AuraEnabled public Decimal totalFacture;
        @AuraEnabled public Integer nbMois;
        @AuraEnabled public Integer nbFacture;
        @AuraEnabled public String aFacturerLabel;
        @AuraEnabled public List<PBMonth> months;
    }

    @AuraEnabled(cacheable=true)
    public static PBOverview getBillingOverview(Id orderId) {
        PBOverview ov = new PBOverview();
        ov.totalValide = 0; ov.totalAFacturer = 0; ov.totalFacture = 0;
        ov.nbFacture = 0; ov.months = new List<PBMonth>();
        List<String> aFacturer = new List<String>();
        for (RSM_PaieBillingPlan__c p : [
                SELECT BillingMonth__c, NbBulletins__c, PrixUnitaire__c, Montant__c, Status__c
                FROM RSM_PaieBillingPlan__c
                WHERE Order__c = :orderId AND Status__c IN ('Validé','Facturé')
                ORDER BY BillingMonth__c ASC]) {
            Decimal mt = p.Montant__c == null ? 0 : p.Montant__c;
            PBMonth m = new PBMonth();
            m.monthIso = String.valueOf(p.BillingMonth__c);
            m.monthLabel = MOIS_FR.get(p.BillingMonth__c.month()) + ' ' + p.BillingMonth__c.year();
            m.nbBulletins = p.NbBulletins__c; m.prixUnitaire = p.PrixUnitaire__c; m.total = mt;
            if (p.Status__c == 'Facturé') {
                m.statusLabel = 'Facturé'; m.statusVariant = 'success';
                m.badgeClass = 'slds-badge slds-theme_success';
                ov.totalFacture += mt; ov.nbFacture++;
            } else {
                m.statusLabel = 'À facturer'; m.statusVariant = 'warning';
                m.badgeClass = 'slds-badge slds-badge_lightest slds-text-color_warning';
                ov.totalAFacturer += mt; aFacturer.add(m.monthLabel);
            }
            ov.totalValide += mt;
            ov.months.add(m);
        }
        ov.nbMois = ov.months.size();
        ov.aFacturerLabel = aFacturer.isEmpty() ? '—'
            : (aFacturer.size() == 1 ? aFacturer[0] : aFacturer.size() + ' mois');
        return ov;
    }

    // ---------- Import Silae : invocable pour la quick action Flow (popup) ----------
    public class ImportRequest {
        @InvocableVariable(required=true label='Order Id') public Id orderId;
        @InvocableVariable(required=true label='Mois (yyyy-MM-dd)') public String monthIso;
    }
    @InvocableMethod(label='Import Silae - Générer plan paie'
        description='Simule l\'import Silae (nb bulletins) pour le mois choisi sur la mission Usage.')
    public static void importSilae(List<ImportRequest> reqs) {
        simulerImportSilae(reqs[0].orderId, reqs[0].monthIso);
    }

    // ---------- Import Silae (un mois choisi, ou le prochain non importé) ----------
    @AuraEnabled
    public static String simulerImportSilae(Id orderId, String monthIso) {
        Order o = [SELECT Id, AccountId, EffectiveDate FROM Order WHERE Id = :orderId LIMIT 1];

        List<OrderItem> lignes = [
            SELECT Id, UnitPrice, Product2.Name FROM OrderItem
            WHERE OrderId = :orderId
              AND Product2.Name LIKE 'Bulletin%paie%'
            LIMIT 1];
        if (lignes.isEmpty())
            throw new AuraHandledException(
                'Aucune ligne « Bulletin de paie » sur cette mission. Ajoute le produit au devis/à la commande.');
        OrderItem ligne = lignes[0];
        Decimal prix = (ligne.UnitPrice == null || ligne.UnitPrice == 0) ? PRIX_DEFAUT : ligne.UnitPrice;

        // Mois cible : choisi, sinon prochain mois non encore importé
        Date mois;
        if (String.isNotBlank(monthIso)) {
            Date d = Date.valueOf(monthIso);
            mois = Date.newInstance(d.year(), d.month(), 1);
        } else {
            List<RSM_PaieBillingPlan__c> dernier = [SELECT BillingMonth__c FROM RSM_PaieBillingPlan__c
                WHERE Order__c = :orderId ORDER BY BillingMonth__c DESC LIMIT 1];
            if (dernier.isEmpty()) {
                Date start = o.EffectiveDate != null ? o.EffectiveDate : Date.today();
                mois = Date.newInstance(start.year(), start.month(), 1);
            } else {
                Date last = dernier[0].BillingMonth__c;
                mois = Date.newInstance(last.year(), last.month(), 1).addMonths(1);
            }
        }

        Integer nbBulletins = 40 + (Integer) Math.floor(Math.random() * 21); // 40..60
        String mm = (mois.month() < 10 ? '0' : '') + mois.month();
        RSM_PaieBillingPlan__c p = new RSM_PaieBillingPlan__c(
            Order__c = orderId, OrderProduct__c = ligne.Id, Account__c = o.AccountId,
            BillingMonth__c = mois, NbBulletins__c = nbBulletins, PrixUnitaire__c = prix,
            Status__c = 'Brouillon', Source__c = 'Silae',
            ExternalKey__c = orderId + '-' + mois.year() + '-' + mm);
        upsert p ExternalKey__c;

        return 'Import Silae — ' + MOIS_FR.get(mois.month()).toLowerCase() + ' ' + mois.year() +
            ' : ' + nbBulletins + ' bulletins (' + (nbBulletins * prix).setScale(0) + ' € à facturer).';
    }

    // ---------- Sauvegarde inline (nb bulletins) ----------
    @AuraEnabled
    public static void saveLines(String linesJson) {
        List<Object> raw = (List<Object>) JSON.deserializeUntyped(linesJson);
        List<RSM_PaieBillingPlan__c> ups = new List<RSM_PaieBillingPlan__c>();
        for (Object o : raw) {
            Map<String,Object> m = (Map<String,Object>) o;
            RSM_PaieBillingPlan__c p = new RSM_PaieBillingPlan__c(Id = (Id) m.get('id'));
            if (m.get('nbBulletins') != null) p.NbBulletins__c = toDec(m.get('nbBulletins'));
            if (m.get('prixUnitaire') != null) p.PrixUnitaire__c = toDec(m.get('prixUnitaire'));
            ups.add(p);
        }
        if (!ups.isEmpty()) update ups;
    }

    // ---------- Phase 1a : sync OrderItem au mois + statut Validé ----------
    @AuraEnabled
    public static void prepareMonth(Id orderId, String monthIso) {
        Date m = Date.valueOf(monthIso);
        Order ord = [SELECT EffectiveDate, Status FROM Order WHERE Id = :orderId LIMIT 1];
        if (ord.Status != 'Activated')
            throw new AuraHandledException(
                'La mission doit être activée avant de valider un mois. Sur la commande : « Recalculer tous les prix » puis « Activer ».');
        // La ServiceDate ne peut pas être antérieure au début de mission -> on la borne.
        Date serviceDate = (ord.EffectiveDate != null && m < ord.EffectiveDate) ? ord.EffectiveDate : m;

        List<RSM_PaieBillingPlan__c> plans = [SELECT Id, OrderProduct__c, NbBulletins__c, PrixUnitaire__c
            FROM RSM_PaieBillingPlan__c WHERE Order__c = :orderId AND BillingMonth__c = :m];
        if (plans.isEmpty()) throw new AuraHandledException('Aucun plan paie pour ce mois.');

        // Repart de zéro : supprime les BS de l'order (le montant varie chaque mois).
        Set<Id> bsgIds = new Set<Id>();
        for (BillingSchedule bs : [SELECT BillingScheduleGroupId FROM BillingSchedule WHERE ReferenceEntityId = :orderId])
            if (bs.BillingScheduleGroupId != null) bsgIds.add(bs.BillingScheduleGroupId);
        if (!bsgIds.isEmpty()) delete [SELECT Id FROM BillingScheduleGroup WHERE Id IN :bsgIds];

        // Map des lignes "Bulletin de paie" (celles qui ont un plan)
        Map<Id,RSM_PaieBillingPlan__c> planByOi = new Map<Id,RSM_PaieBillingPlan__c>();
        for (RSM_PaieBillingPlan__c p : plans) if (p.OrderProduct__c != null) planByOi.put(p.OrderProduct__c, p);

        // TOUTES les lignes de la commande doivent avoir une ServiceDate (sinon la transaction
        // est rejetée — "date de début"). On injecte qty/montant du mois sur la ligne bulletins,
        // et on borne juste la ServiceDate + fréquence sur les autres (ex. bundle).
        List<OrderItem> ois = new List<OrderItem>();
        for (OrderItem oi : [SELECT Id FROM OrderItem WHERE OrderId = :orderId]) {
            if (planByOi.containsKey(oi.Id)) {
                RSM_PaieBillingPlan__c p = planByOi.get(oi.Id);
                Decimal q = p.NbBulletins__c == null ? 0 : p.NbBulletins__c;
                Decimal pr = p.PrixUnitaire__c == null ? 0 : p.PrixUnitaire__c;
                Decimal amt = q * pr;
                ois.add(new OrderItem(Id = oi.Id,
                    Quantity = q, UnitPrice = pr, NetUnitPrice = pr,
                    TotalLineAmount = amt, NetTotalPrice = amt, ServiceDate = serviceDate,
                    BillingTreatmentId = getRegieTreatmentId(), BillingFrequency2 = 'Monthly'));
            } else {
                ois.add(new OrderItem(Id = oi.Id, ServiceDate = serviceDate,
                    BillingTreatmentId = getRegieTreatmentId(), BillingFrequency2 = 'Monthly'));
            }
        }
        if (!ois.isEmpty()) {
            try { update ois; }
            catch (Exception e) { throw new AuraHandledException('Mise à jour des lignes impossible : ' + e.getMessage()); }
        }
        for (RSM_PaieBillingPlan__c p : plans) { p.Status__c = 'Validé'; p.BillingScheduleId__c = null; p.ErrorMessage__c = null; }
        update plans;
    }

    // ---------- Phase 1b : génération des BS (API standalone, in-process) ----------
    @AuraEnabled
    public static void createSchedules(Id orderId) {
        if (Test.isRunningTest()) return;
        Invocable.Action a = Invocable.Action.createStandardAction('createBillingSchedulesFromTrxn');
        a.setInvocationParameter('transactionDetails', '{"BillingTransaction":[{"id":"' + orderId + '"}]}');
        a.setInvocationParameter('contextDefinitionName', CTX_DEF);
        a.setInvocationParameter('readContextMappingName', READ_MAP);
        a.setInvocationParameter('saveContextMappingName', SAVE_MAP);
        List<Invocable.Action.Result> rs = a.invoke();
        if (rs.isEmpty() || !rs[0].isSuccess())
            throw new AuraHandledException('Échec de génération : '
                + (rs.isEmpty() ? 'aucun résultat' : String.valueOf(rs[0].getErrors())));
    }

    // ---------- Phase 2 : purge hors-paie + lien BS + restaure le contractuel ----------
    @AuraEnabled
    public static String finalizeForMonth(Id orderId, String monthIso) {
        Date m = Date.valueOf(monthIso);
        Map<Id,RSM_PaieBillingPlan__c> byOi = new Map<Id,RSM_PaieBillingPlan__c>();
        for (RSM_PaieBillingPlan__c p : [SELECT Id, OrderProduct__c FROM RSM_PaieBillingPlan__c
                WHERE Order__c = :orderId AND BillingMonth__c = :m])
            if (p.OrderProduct__c != null) byOi.put(p.OrderProduct__c, p);

        List<BillingSchedule> bss = [SELECT Id, ReferenceEntityItemId, BillingScheduleGroupId, BillingPeriodAmount
            FROM BillingSchedule WHERE ReferenceEntityId = :orderId];
        Set<Id> bsgDel = new Set<Id>();
        List<RSM_PaieBillingPlan__c> upd = new List<RSM_PaieBillingPlan__c>();
        Integer kept = 0; Decimal total = 0;
        for (BillingSchedule bs : bss) {
            if (byOi.containsKey(bs.ReferenceEntityItemId)) {
                upd.add(new RSM_PaieBillingPlan__c(Id = byOi.get(bs.ReferenceEntityItemId).Id,
                    Status__c = 'Validé', BillingScheduleId__c = bs.Id));
                kept++; total += bs.BillingPeriodAmount == null ? 0 : bs.BillingPeriodAmount;
            } else if (bs.BillingScheduleGroupId != null) {
                bsgDel.add(bs.BillingScheduleGroupId);
            }
        }
        if (kept == 0) return 'PENDING';
        if (!bsgDel.isEmpty()) delete [SELECT Id FROM BillingScheduleGroup WHERE Id IN :bsgDel];
        if (!upd.isEmpty()) update upd;

        // Restaure quantité/prix contractuels (depuis le devis)
        List<OrderItem> oiUpd = new List<OrderItem>();
        for (OrderItem oi : [SELECT Id, QuoteLineItemId, QuoteLineItem.Quantity, QuoteLineItem.UnitPrice
                FROM OrderItem WHERE Id IN :byOi.keySet()]) {
            OrderItem u = new OrderItem(Id = oi.Id);
            if (oi.QuoteLineItemId != null) {
                Decimal cq = oi.QuoteLineItem.Quantity == null ? 0 : oi.QuoteLineItem.Quantity;
                Decimal pr = oi.QuoteLineItem.UnitPrice == null ? 0 : oi.QuoteLineItem.UnitPrice;
                u.Quantity = cq; u.UnitPrice = pr; u.NetUnitPrice = pr;
                u.TotalLineAmount = cq * pr; u.NetTotalPrice = cq * pr;
            }
            oiUpd.add(u);
        }
        if (!oiUpd.isEmpty()) update oiUpd;
        return kept + ' échéancier(s) paie générés — total ' + total.setScale(0).format() + ' €.';
    }

    // ---------- Facturation du mois (crée + poste) ----------
    @AuraEnabled
    public static String createAndPostInvoice(Id orderId, String monthIso) {
        Date m = Date.valueOf(monthIso);
        List<RSM_PaieBillingPlan__c> plans = [SELECT Id, BillingScheduleId__c FROM RSM_PaieBillingPlan__c
            WHERE Order__c = :orderId AND BillingMonth__c = :m];
        if (plans.isEmpty()) throw new AuraHandledException('Aucun plan pour ce mois.');
        Set<Id> bsIds = new Set<Id>();
        for (RSM_PaieBillingPlan__c p : plans) if (p.BillingScheduleId__c != null) bsIds.add((Id) p.BillingScheduleId__c);
        if (bsIds.isEmpty()) throw new AuraHandledException('Aucun échéancier généré pour ce mois — valide d\'abord.');

        Date target = m.addMonths(1);
        for (BillingSchedule bs : [SELECT NextBillingDate FROM BillingSchedule WHERE Id IN :bsIds])
            if (bs.NextBillingDate != null && bs.NextBillingDate > target) target = bs.NextBillingDate;
        String tStr = DateTime.newInstance(target.year(), target.month(), target.day(), 0, 0, 0).format('yyyy-MM-dd');

        if (!Test.isRunningTest()) {
            List<String> ids = new List<String>();
            for (Id b : bsIds) ids.add(String.valueOf(b));
            ConnectApi.InvoiceInputRepresentation inp = new ConnectApi.InvoiceInputRepresentation();
            inp.billingScheduleIds = ids;
            inp.action = ConnectApi.InvoiceAction.Posted;
            inp.invoiceDate = tStr;
            inp.targetDate = tStr;
            ConnectApi.RevenueAsyncRepresentation res = ConnectApi.Billing.generateInvoices(inp);
            if (res == null || !res.success)
                throw new AuraHandledException('Échec facturation : ' + (res == null ? '' : String.valueOf(res.errors)));
        }
        for (RSM_PaieBillingPlan__c p : plans) p.Status__c = 'Facturé';
        update plans;
        return 'Mois facturé et posté (' + bsIds.size() + ' échéance(s)).';
    }

    // ---------- Facture TOUS les mois validés de la mission (cockpit global) ----------
    @AuraEnabled
    public static String invoiceOrder(Id orderId) {
        List<RSM_PaieBillingPlan__c> plans = [SELECT Id, BillingScheduleId__c FROM RSM_PaieBillingPlan__c
            WHERE Order__c = :orderId AND Status__c = 'Validé'];
        if (plans.isEmpty()) throw new AuraHandledException('Aucun mois validé à facturer sur cette mission.');
        Set<Id> bsIds = new Set<Id>();
        for (RSM_PaieBillingPlan__c p : plans) if (p.BillingScheduleId__c != null) bsIds.add((Id) p.BillingScheduleId__c);
        if (bsIds.isEmpty())
            for (BillingSchedule bs : [SELECT Id FROM BillingSchedule
                    WHERE ReferenceEntityId = :orderId AND Status = 'ReadyForInvoicing'])
                bsIds.add(bs.Id);
        if (bsIds.isEmpty()) throw new AuraHandledException('Aucun échéancier prêt à facturer — (re)valide le mois.');

        Date target = Date.today();
        for (BillingSchedule bs : [SELECT NextBillingDate FROM BillingSchedule WHERE Id IN :bsIds])
            if (bs.NextBillingDate != null && bs.NextBillingDate > target) target = bs.NextBillingDate;
        String tStr = DateTime.newInstance(target.year(), target.month(), target.day(), 0, 0, 0).format('yyyy-MM-dd');

        if (!Test.isRunningTest()) {
            List<String> ids = new List<String>();
            for (Id b : bsIds) ids.add(String.valueOf(b));
            ConnectApi.InvoiceInputRepresentation inp = new ConnectApi.InvoiceInputRepresentation();
            inp.billingScheduleIds = ids;
            inp.action = ConnectApi.InvoiceAction.Posted;
            inp.invoiceDate = tStr;
            inp.targetDate = tStr;
            ConnectApi.RevenueAsyncRepresentation res = ConnectApi.Billing.generateInvoices(inp);
            if (res == null || !res.success)
                throw new AuraHandledException('Échec facturation : ' + (res == null ? '' : String.valueOf(res.errors)));
        }
        for (RSM_PaieBillingPlan__c p : plans) p.Status__c = 'Facturé';
        update plans;
        return plans.size() + ' mois facturé(s) et posté(s).';
    }

    // ---------- Rattache les factures à l'order ----------
    @AuraEnabled
    public static Integer linkInvoicesToOrder(Id orderId) {
        Set<Id> invIds = new Set<Id>();
        for (InvoiceLine il : [SELECT InvoiceId FROM InvoiceLine
                WHERE BillingSchedule.ReferenceEntityId = :orderId AND Invoice.ReferenceEntityId = null])
            if (il.InvoiceId != null) invIds.add(il.InvoiceId);
        List<Invoice> toUpd = new List<Invoice>();
        for (Id i : invIds) toUpd.add(new Invoice(Id = i, ReferenceEntityId = orderId));
        if (!toUpd.isEmpty()) update toUpd;
        return toUpd.size();
    }

    private static Decimal toDec(Object o) { return o == null ? null : Decimal.valueOf(String.valueOf(o)); }
}
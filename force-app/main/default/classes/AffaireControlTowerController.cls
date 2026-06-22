/**
 * Cockpit de pilotage de l'AFFAIRE (= Order = Mission).
 * Tour de contrôle qui agrège, en lecture seule et 100% calculé à la volée :
 *   - Pilotage 360° : Vendu / Réalisé / Facturé (en € et en jours) + écarts
 *   - Rentabilité   : Boni / Mali (coût vendu vs coût réel)
 *   - FAE           : produit réalisé non facturé ; matérialisable en facture Draft
 *
 * Branche selon le modèle (Order.RSM_BillingModel__c) :
 *   - RÉGIE   : réalisé piloté par le TEMPS (RegieBillingPlan__c / Napta)
 *   - FORFAIT : réalisé piloté par les JALONS (BillingMilestonePlanItem)
 * Dans les deux cas le COÛT réel se mesure sur le temps réel consommé
 * (RegieBillingPlan__c × coût du grade RSM_RankCost__c), avec repli au prorata
 * de l'avancement pour le forfait quand aucun temps n'est saisi.
 *
 * Aucune métadonnée créée : tout vient de Order, OrderItem, RegieBillingPlan__c,
 * BillingMilestonePlanItem, Invoice et RSM_RankCost__c (existants).
 */
public with sharing class AffaireControlTowerController {

    public class Pilotage {
        // Identité
        @AuraEnabled public Id orderId;
        @AuraEnabled public String orderNumber;
        @AuraEnabled public String orderName;
        @AuraEnabled public String account;
        @AuraEnabled public String statut;
        @AuraEnabled public String model;        // 'Regie' | 'Forfait'
        @AuraEnabled public String modelLabel;   // 'Régie' | 'Forfait'

        // Vendu
        @AuraEnabled public Decimal caVendu;
        @AuraEnabled public Decimal joursVendus;
        @AuraEnabled public Decimal coutVendu;
        @AuraEnabled public Decimal margeVendue;

        // Réalisé
        @AuraEnabled public Decimal produitRealise;
        @AuraEnabled public Decimal joursRealises;
        @AuraEnabled public Decimal coutReel;
        @AuraEnabled public Decimal fraisReels;
        @AuraEnabled public Decimal avancement;        // 0..100 (%)
        @AuraEnabled public Boolean joursReelsEstimes;  // true = repli prorata (forfait sans temps)

        // Facturé
        @AuraEnabled public Decimal facture;
        @AuraEnabled public Decimal joursFactures;

        // Écarts
        @AuraEnabled public Decimal resteAProduire;
        @AuraEnabled public Decimal resteAFacturer;
        @AuraEnabled public Decimal resteAConsommer;

        // Rentabilité (Boni / Mali), base "à date" (au prorata de l'avancement)
        @AuraEnabled public Decimal margeReelle;        // produit réalisé - coût réel
        @AuraEnabled public Decimal margeAttendue;      // marge vendue × avancement
        @AuraEnabled public Decimal boniMali;           // marge réelle - marge attendue
        @AuraEnabled public Decimal boniMaliPct;        // écart % sur la marge attendue
        @AuraEnabled public String  boniMaliStatut;     // 'Boni' | 'Mali' | 'Neutre'
        @AuraEnabled public Boolean coutReelSaisi;      // true = coût réel saisi (forfait)

        // FAE
        @AuraEnabled public Decimal fae;        // produit réalisé non facturé (à matérialiser)
        @AuraEnabled public Decimal faeDraft;   // déjà matérialisé en factures Draft

        // KPIs analytiques
        @AuraEnabled public Decimal tauxMargeVendue;   // marge vendue / CA vendu (%)
        @AuraEnabled public Decimal tauxMargeReelle;   // marge réelle / produit réalisé (%)
        @AuraEnabled public Decimal tauxFacturation;   // facturé / produit réalisé (%)
        @AuraEnabled public Decimal tauxConsommation;  // jours réalisés / jours vendus (%)
        @AuraEnabled public Decimal tjmVendu;          // CA vendu / jours vendus (€/j)
        @AuraEnabled public Decimal tjmRealise;        // produit réalisé / jours réalisés (€/j)
        @AuraEnabled public Decimal coutJourReel;      // coût réel / jours réalisés (€/j)
    }

    @AuraEnabled(cacheable=true)
    public static Pilotage getPilotage(Id orderId) {
        Pilotage p = new Pilotage();
        p.orderId = orderId;

        Order o = [
            SELECT Id, OrderNumber, Name, Status, TotalAmount, RSM_CoutReelSaisiHT__c,
                   RSM_BillingModel__c, RecordType.DeveloperName, Account.Name
            FROM Order WHERE Id = :orderId LIMIT 1];
        p.orderNumber = o.OrderNumber;
        p.orderName   = o.Name;
        p.account     = o.Account == null ? '' : o.Account.Name;
        p.statut      = o.Status;

        String rt = o.RecordType == null ? null : o.RecordType.DeveloperName;
        Boolean isForfait = (o.RSM_BillingModel__c == 'Forfait') || (rt == 'Forfait');
        p.model      = isForfait ? 'Forfait' : 'Regie';
        p.modelLabel = isForfait ? 'Forfait' : 'Régie';

        // ----- Coût/jour par produit-grade (RSM_RankCost__c) -----
        Map<Id, Decimal> coutJourByProduct = new Map<Id, Decimal>();
        for (RSM_RankCost__c rc : [
                SELECT RSM_Product__c, RSM_Cost__c
                FROM RSM_RankCost__c WHERE RSM_Product__c != null])
            coutJourByProduct.put(rc.RSM_Product__c, rc.RSM_Cost__c == null ? 0 : rc.RSM_Cost__c);

        // ----- VENDU (lignes "temps" = produits ayant un coût grade) -----
        p.caVendu = o.TotalAmount == null ? 0 : o.TotalAmount;
        Decimal joursVendus = 0, coutVendu = 0;
        for (OrderItem oi : [
                SELECT Quantity, Product2Id, RSM_JoursFactures__c
                FROM OrderItem WHERE OrderId = :orderId]) {
            Decimal q = oi.Quantity == null ? 0 : oi.Quantity;
            if (coutJourByProduct.containsKey(oi.Product2Id)) {
                joursVendus += q;
                coutVendu   += q * coutJourByProduct.get(oi.Product2Id);
            }
        }
        p.joursVendus  = joursVendus;
        p.coutVendu    = coutVendu;
        p.margeVendue  = p.caVendu - coutVendu;

        // ----- RÉALISÉ : temps réel (RegieBillingPlan__c) commun aux 2 modèles -----
        Decimal joursReels = 0, coutTemps = 0, frais = 0, produitTemps = 0;
        for (RegieBillingPlan__c r : [
                SELECT JoursReels__c, Montant__c, FraisMontant__c, OrderProduct__r.Product2Id
                FROM RegieBillingPlan__c WHERE Order__c = :orderId]) {
            Decimal j = r.JoursReels__c == null ? 0 : r.JoursReels__c;
            joursReels   += j;
            produitTemps += (r.Montant__c == null ? 0 : r.Montant__c);
            frais        += (r.FraisMontant__c == null ? 0 : r.FraisMontant__c);
            Id pid = r.OrderProduct__r == null ? null : r.OrderProduct__r.Product2Id;
            if (pid != null && coutJourByProduct.containsKey(pid))
                coutTemps += j * coutJourByProduct.get(pid);
        }
        p.fraisReels = frais;
        Boolean hasTemps = joursReels > 0;

        p.coutReelSaisi = false;
        if (!isForfait) {
            // RÉGIE : produit réalisé = temps valorisé ; avancement = jours réels / vendus
            p.produitRealise    = produitTemps;
            p.joursRealises     = joursReels;
            p.coutReel          = coutTemps + frais;
            p.joursReelsEstimes = false;
            p.avancement = joursVendus > 0 ? (joursReels / joursVendus) * 100 : 0;
        } else {
            // FORFAIT : produit réalisé = jalons accomplis ; avancement = % du contrat reconnu
            Decimal totalMs = 0, realiseMs = 0;
            for (BillingMilestonePlanItem it : [
                    SELECT MilestoneAmount, IsMilestoneAccomplished
                    FROM BillingMilestonePlanItem
                    WHERE BillingMilestonePlanId IN (
                        SELECT BillingMilestonePlanId FROM BillingSchedule
                        WHERE ReferenceEntityId = :orderId AND BillingMilestonePlanId != null)]) {
                Decimal amt = it.MilestoneAmount == null ? 0 : it.MilestoneAmount;
                totalMs += amt;
                if (it.IsMilestoneAccomplished == true) realiseMs += amt;
            }
            p.produitRealise = realiseMs;
            p.avancement = totalMs > 0 ? (realiseMs / totalMs) * 100 : 0;
            Decimal av = p.avancement / 100;
            // Jours réalisés : temps réel si saisi, sinon estimation au prorata
            if (hasTemps) {
                p.joursRealises = joursReels;
                p.joursReelsEstimes = false;
            } else {
                p.joursRealises = (joursVendus * av).setScale(1);
                p.joursReelsEstimes = true;
            }
            // Coût réel : 1) coût saisi (manager/Napta) prioritaire, 2) temps réel, 3) repli prorata
            if (o.RSM_CoutReelSaisiHT__c != null) {
                p.coutReel = o.RSM_CoutReelSaisiHT__c + frais;
                p.coutReelSaisi = true;
            } else if (hasTemps) {
                p.coutReel = coutTemps + frais;
            } else {
                p.coutReel = (coutVendu * av) + frais;
            }
        }

        // ----- FACTURÉ + FAE déjà matérialisée (factures de l'order) -----
        Decimal facture = 0, faeDraft = 0;
        for (Invoice inv : [
                SELECT TotalAmount, Status FROM Invoice WHERE ReferenceEntityId = :orderId]) {
            Decimal amt = inv.TotalAmount == null ? 0 : inv.TotalAmount;
            if (inv.Status == 'Posted') facture += amt;
            else if (inv.Status == 'Draft') faeDraft += amt;
        }
        p.facture = facture;
        p.faeDraft = faeDraft;
        Decimal jf = 0;
        for (OrderItem oi : [SELECT RSM_JoursFactures__c FROM OrderItem WHERE OrderId = :orderId])
            jf += (oi.RSM_JoursFactures__c == null ? 0 : oi.RSM_JoursFactures__c);
        p.joursFactures = jf;

        // ----- ÉCARTS -----
        p.resteAProduire  = p.caVendu - p.produitRealise;
        p.resteAFacturer  = p.produitRealise - p.facture;
        p.resteAConsommer = p.joursVendus - p.joursRealises;

        // ----- BONI / MALI (base "à date") -----
        // On proratise sur la VALEUR produite (€), pas les jours : en régie le mix de grades
        // fait diverger l'avancement-jours de l'avancement-CA. Équivaut à :
        //   Boni/Mali = (coût budgété pour ce niveau de production) − (coût réel engagé)
        Decimal avValeur = p.caVendu > 0 ? (p.produitRealise / p.caVendu) : 0;
        p.margeReelle   = p.produitRealise - p.coutReel;
        p.margeAttendue = p.margeVendue * avValeur;
        p.boniMali      = p.margeReelle - p.margeAttendue;
        p.boniMaliPct   = p.margeAttendue != 0
            ? (p.boniMali / Math.abs(p.margeAttendue) * 100).setScale(1)
            : 0;
        p.boniMaliStatut = p.boniMali > 1 ? 'Boni' : (p.boniMali < -1 ? 'Mali' : 'Neutre');

        // ----- FAE (produit réalisé non facturé, plancher 0) -----
        p.fae = p.resteAFacturer > 0 ? p.resteAFacturer : 0;

        // ----- KPIs analytiques -----
        p.tauxMargeVendue  = p.caVendu != 0 ? (p.margeVendue / p.caVendu * 100).setScale(1) : 0;
        p.tauxMargeReelle  = p.produitRealise != 0 ? (p.margeReelle / p.produitRealise * 100).setScale(1) : 0;
        p.tauxFacturation  = p.produitRealise != 0 ? (p.facture / p.produitRealise * 100).setScale(1) : 0;
        p.tauxConsommation = p.joursVendus != 0 ? (p.joursRealises / p.joursVendus * 100).setScale(1) : 0;
        p.tjmVendu     = p.joursVendus != 0 ? round2(p.caVendu / p.joursVendus) : 0;
        p.tjmRealise   = p.joursRealises != 0 ? round2(p.produitRealise / p.joursRealises) : 0;
        p.coutJourReel = p.joursRealises != 0 ? round2(p.coutReel / p.joursRealises) : 0;

        // ----- Arrondis propres pour l'affichage -----
        p.caVendu = round2(p.caVendu); p.coutVendu = round2(p.coutVendu); p.margeVendue = round2(p.margeVendue);
        p.produitRealise = round2(p.produitRealise); p.coutReel = round2(p.coutReel); p.fraisReels = round2(p.fraisReels);
        p.facture = round2(p.facture); p.faeDraft = round2(p.faeDraft);
        p.resteAProduire = round2(p.resteAProduire); p.resteAFacturer = round2(p.resteAFacturer);
        p.margeReelle = round2(p.margeReelle); p.margeAttendue = round2(p.margeAttendue); p.boniMali = round2(p.boniMali);
        p.fae = round2(p.fae); p.avancement = p.avancement.setScale(1);

        return p;
    }

    private static Decimal round2(Decimal d) {
        return d == null ? 0 : d.setScale(2, System.RoundingMode.HALF_UP);
    }

    /** Saisie / ajustement du coût réel engagé (garde-fou manager, forfait). */
    @AuraEnabled
    public static void setCoutReel(Id orderId, Decimal montant) {
        update new Order(Id = orderId, RSM_CoutReelSaisiHT__c = montant);
    }

    /**
     * Matérialise la FAE : génère des factures en DRAFT (= factures à établir)
     * sur les échéances prêtes à facturer (ReadyForInvoicing) de l'order.
     * Ne poste rien — la Draft EST la FAE jusqu'à sa validation.
     */
    @AuraEnabled
    public static String genererFAE(Id orderId) {
        List<String> bsIds = new List<String>();
        for (BillingSchedule bs : [SELECT Id FROM BillingSchedule
                WHERE ReferenceEntityId = :orderId AND Status = 'ReadyForInvoicing'])
            bsIds.add(String.valueOf(bs.Id));
        if (bsIds.isEmpty())
            throw new AuraHandledException(
                'Aucune échéance prête à facturer — valide d\'abord un mois (régie) ou réalise un jalon (forfait).');

        Date t = Date.today();
        String tStr = DateTime.newInstance(t.year(), t.month(), t.day(), 0, 0, 0).format('yyyy-MM-dd');

        if (!Test.isRunningTest()) {
            ConnectApi.InvoiceInputRepresentation inp = new ConnectApi.InvoiceInputRepresentation();
            inp.billingScheduleIds = bsIds;
            inp.action = ConnectApi.InvoiceAction.Draft;
            inp.invoiceDate = tStr;
            inp.targetDate = tStr;
            ConnectApi.RevenueAsyncRepresentation res = ConnectApi.Billing.generateInvoices(inp);
            if (res == null || !res.success)
                throw new AuraHandledException('Échec génération FAE : ' + (res == null ? '' : String.valueOf(res.errors)));
        }
        return 'FAE générée en Draft (' + bsIds.size() + ' échéance(s)).';
    }

    /** Rattache les factures Draft (FAE) à l'order pour la related list (génération async). */
    @AuraEnabled
    public static Integer linkFAE(Id orderId) {
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
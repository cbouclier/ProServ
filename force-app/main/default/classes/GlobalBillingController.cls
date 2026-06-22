/**
 * Cockpit de Facturation GLOBAL : vue multi-missions (tous modèles).
 * Phase 1 — la régie est pleinement opérationnelle (réutilise RegieBillingController) ;
 * les missions Forfait/Usage apparaissent en lecture seule (drill-in livré en Phase 2/3).
 *
 * Détection du modèle :
 *   - Régie  : RecordType Order = 'Regie' OU présence de RegieBillingPlan__c.
 *   - Forfait: RecordType Order = 'Forfait'.
 *   - Usage  : hook detectUsage() (Phase 3) — false pour l'instant (pas de données usage).
 */
public with sharing class GlobalBillingController {

    private static final Map<Integer,String> MOIS_FR = new Map<Integer,String>{
        1=>'Janvier',2=>'Février',3=>'Mars',4=>'Avril',5=>'Mai',6=>'Juin',
        7=>'Juillet',8=>'Août',9=>'Septembre',10=>'Octobre',11=>'Novembre',12=>'Décembre'};

    public class Mission {
        @AuraEnabled public Id orderId;
        @AuraEnabled public String orderNumber;
        @AuraEnabled public String orderName;
        @AuraEnabled public String account;
        @AuraEnabled public String model;          // 'Regie' | 'Forfait' | 'Usage'
        @AuraEnabled public String modelLabel;
        @AuraEnabled public String periodRef;      // ex. "Juin 2026"
        @AuraEnabled public Decimal montant;       // à facturer ce mois (régie) ou null
        @AuraEnabled public String statut;         // 'À valider' | 'Validé' | 'Facturé' | 'Rien ce mois' | 'À venir'
        @AuraEnabled public String statutVariant;  // warning | info | success | neutral
        @AuraEnabled public Boolean actionnable;   // true = drill-in/actions dispo (régie en Phase 1)
        @AuraEnabled public Boolean nonActionnable; // pour disabled côté datatable
        // Staffing Napta importé mais NON validé (Brouillon), TOUS mois confondus
        @AuraEnabled public Boolean hasAValider;
        @AuraEnabled public Integer aValiderCount;  // nb de mois à valider
        @AuraEnabled public String aValiderLabel;   // ex. "Juin, Juillet 2026"
    }
    public class Summary {
        @AuraEnabled public String monthLabel;
        @AuraEnabled public Decimal totalAFacturer;
        @AuraEnabled public Decimal totalFacture;
        @AuraEnabled public Integer nbATraiter;
        @AuraEnabled public Integer nbValide;
        @AuraEnabled public Integer nbFacture;
        @AuraEnabled public Integer nbAValiderNapta;   // missions avec staffing Napta à valider
        @AuraEnabled public List<Mission> missions;
    }

    @AuraEnabled(cacheable=true)
    public static Summary getMissions(String monthIso) {
        Date m = Date.valueOf(monthIso);
        String monthLabel = MOIS_FR.get(m.month()) + ' ' + m.year();

        Summary s = new Summary();
        s.monthLabel = monthLabel;
        s.totalAFacturer = 0; s.totalFacture = 0;
        s.nbATraiter = 0; s.nbValide = 0; s.nbFacture = 0; s.nbAValiderNapta = 0;
        s.missions = new List<Mission>();

        // Staffing Napta importé mais NON validé (Brouillon), tous mois confondus, par order
        Map<Id, Set<Date>> aValiderByOrder = new Map<Id, Set<Date>>();
        for (RegieBillingPlan__c p : [
                SELECT Order__c, BillingMonth__c FROM RegieBillingPlan__c WHERE Status__c = 'Brouillon']) {
            if (!aValiderByOrder.containsKey(p.Order__c)) aValiderByOrder.put(p.Order__c, new Set<Date>());
            if (p.BillingMonth__c != null) aValiderByOrder.get(p.Order__c).add(p.BillingMonth__c);
        }

        // RBP du mois sélectionné, groupés par order
        Map<Id, List<RegieBillingPlan__c>> rbpByOrder = new Map<Id, List<RegieBillingPlan__c>>();
        for (RegieBillingPlan__c p : [
                SELECT Order__c, Montant__c, Status__c, Grade__c, BillingMonth__c
                FROM RegieBillingPlan__c WHERE BillingMonth__c = :m]) {
            if (!rbpByOrder.containsKey(p.Order__c)) rbpByOrder.put(p.Order__c, new List<RegieBillingPlan__c>());
            rbpByOrder.get(p.Order__c).add(p);
        }
        // Orders ayant des RBP (n'importe quel mois) => classés régie
        Set<Id> ordersWithRbp = new Set<Id>();
        for (AggregateResult ar : [SELECT Order__c oid FROM RegieBillingPlan__c GROUP BY Order__c])
            ordersWithRbp.add((Id) ar.get('oid'));

        // On liste les orders activés + ceux qui ont un plan régie.
        List<Order> orders = [
            SELECT Id, OrderNumber, Name, Status, RecordType.DeveloperName, Account.Name, TotalAmount
            FROM Order
            WHERE Status = 'Activated' OR Id IN :ordersWithRbp
            ORDER BY CreatedDate DESC];

        // Agrégation des jalons (Forfait) par order, pour statut + facturable
        Set<Id> forfaitIds = new Set<Id>();
        for (Order o : orders)
            if (o.RecordType != null && o.RecordType.DeveloperName == 'Forfait') forfaitIds.add(o.Id);
        Map<Id, MStone> msByOrder = milestoneAgg(forfaitIds);

        for (Order o : orders) {

            String rt = o.RecordType == null ? null : o.RecordType.DeveloperName;
            Boolean isRegie = rt == 'Regie' || ordersWithRbp.contains(o.Id);
            Boolean isForfait = rt == 'Forfait';
            // Phase 1 : on n'affiche que les missions billing-pertinentes (régie ou forfait).
            if (!isRegie && !isForfait) continue;

            Mission mi = new Mission();
            mi.orderId = o.Id;
            mi.orderNumber = o.OrderNumber;
            mi.orderName = o.Name;
            mi.account = o.Account == null ? '' : o.Account.Name;
            mi.periodRef = monthLabel;

            // Staffing Napta à valider (tous mois) — indépendant du mois sélectionné
            Set<Date> av = aValiderByOrder.get(o.Id);
            if (av != null && !av.isEmpty()) {
                mi.hasAValider = true; mi.aValiderCount = av.size();
                List<Date> ds = new List<Date>(av); ds.sort();
                List<String> labs = new List<String>();
                for (Date d : ds) labs.add(MOIS_FR.get(d.month()) + ' ' + d.year());
                mi.aValiderLabel = String.join(labs, ', ');
                s.nbAValiderNapta++;
            } else {
                mi.hasAValider = false; mi.aValiderCount = 0; mi.aValiderLabel = '';
            }

            if (isRegie) {
                mi.model = 'Regie'; mi.modelLabel = 'Régie';
                mi.actionnable = true; mi.nonActionnable = false;
                List<RegieBillingPlan__c> ps = rbpByOrder.get(o.Id);
                if (ps == null || ps.isEmpty()) {
                    mi.montant = 0; mi.statut = 'Rien ce mois'; mi.statutVariant = 'neutral';
                } else {
                    Decimal tot = 0; Boolean anyBrouillon = false; Boolean allFacture = true;
                    for (RegieBillingPlan__c p : ps) {
                        tot += (p.Montant__c == null ? 0 : p.Montant__c);
                        if (p.Status__c == 'Brouillon') anyBrouillon = true;
                        if (p.Status__c != 'Facturé') allFacture = false;
                    }
                    mi.montant = tot;
                    if (allFacture)        { mi.statut = 'Facturé';   mi.statutVariant = 'success'; }
                    else if (anyBrouillon) { mi.statut = 'À valider'; mi.statutVariant = 'warning'; }
                    else                   { mi.statut = 'Validé';    mi.statutVariant = 'info'; }
                }
            } else {
                // Forfait : actionnable, statut dérivé des jalons (réaliser/facturer dans la modale)
                mi.model = 'Forfait'; mi.modelLabel = 'Forfait';
                mi.actionnable = true; mi.nonActionnable = false;
                mi.montant = o.TotalAmount == null ? 0 : o.TotalAmount;
                MStone a = msByOrder.get(o.Id);
                if (a == null || a.total == 0) {
                    mi.statut = 'À activer'; mi.statutVariant = 'neutral';
                } else if (a.facture >= a.total) {
                    mi.statut = 'Facturé'; mi.statutVariant = 'success';
                } else if (a.aFacturer > 0) {
                    mi.statut = 'À facturer'; mi.statutVariant = 'warning';
                } else {
                    mi.statut = 'À réaliser'; mi.statutVariant = 'info';
                }
            }

            if (isRegie) {
                if (mi.statut == 'À valider')   { s.nbATraiter++; s.totalAFacturer += mi.montant; }
                else if (mi.statut == 'Validé') { s.nbValide++;   s.totalAFacturer += mi.montant; }
                else if (mi.statut == 'Facturé'){ s.nbFacture++;  s.totalFacture += (mi.montant == null ? 0 : mi.montant); }
            } else {
                // Forfait : KPIs basés sur les montants de jalons
                MStone a = msByOrder.get(o.Id);
                if (mi.statut == 'À facturer') { s.nbValide++; s.totalAFacturer += (a == null ? 0 : a.aFacturer); }
                if (a != null && a.facture > 0) { s.totalFacture += a.facture; }
                if (mi.statut == 'Facturé') { s.nbFacture++; }
            }

            s.missions.add(mi);
        }
        return s;
    }

    // Agrégat jalons par order : total, déjà facturé, à facturer (réalisé non facturé).
    private class MStone {
        Decimal total = 0; Decimal facture = 0; Decimal aFacturer = 0;
    }
    private static Map<Id, MStone> milestoneAgg(Set<Id> orderIds) {
        Map<Id, MStone> out = new Map<Id, MStone>();
        if (orderIds == null || orderIds.isEmpty()) return out;
        Map<Id, Id> planToOrder = new Map<Id, Id>();
        for (BillingSchedule bs : [SELECT BillingMilestonePlanId, ReferenceEntityId
                FROM BillingSchedule WHERE ReferenceEntityId IN :orderIds AND BillingMilestonePlanId != null])
            planToOrder.put(bs.BillingMilestonePlanId, bs.ReferenceEntityId);
        if (planToOrder.isEmpty()) return out;
        for (BillingMilestonePlanItem it : [
                SELECT BillingMilestonePlanId, MilestoneAmount, Status, IsMilestoneAccomplished
                FROM BillingMilestonePlanItem WHERE BillingMilestonePlanId IN :planToOrder.keySet()]) {
            Id oid = planToOrder.get(it.BillingMilestonePlanId);
            MStone a = out.get(oid);
            if (a == null) { a = new MStone(); out.put(oid, a); }
            Decimal amt = it.MilestoneAmount == null ? 0 : it.MilestoneAmount;
            a.total += amt;
            if (it.Status == 'Invoiced') a.facture += amt;
            else if (it.IsMilestoneAccomplished == true) a.aFacturer += amt;
        }
        return out;
    }

    /**
     * Facture & poste les missions sélectionnées (Phase 1 : régie uniquement).
     * Boucle sur invoiceOrder + linkInvoicesToOrder (RegieBillingController).
     */
    @AuraEnabled
    public static String facturerSelection(List<Id> orderIds) {
        Integer ok = 0;
        List<String> errs = new List<String>();
        for (Id oid : orderIds) {
            try {
                RegieBillingController.invoiceOrder(oid);
                RegieBillingController.linkInvoicesToOrder(oid);
                ok++;
            } catch (Exception e) {
                errs.add(oid + ' : ' + e.getMessage());
            }
        }
        String msg = ok + ' mission(s) facturée(s) et postée(s).';
        if (!errs.isEmpty()) msg += ' — Ignorées : ' + String.join(errs, ' | ');
        return msg;
    }

    /** Hook Phase 3 — détection des missions à l'usage. False tant qu'il n'y a pas de données usage. */
    private static Boolean detectUsage(Id orderId) {
        return false;
    }
}
/**
 * Cockpit régie : édition des RegieBillingPlan__c (jours/TJM/frais) par mois et
 * génération des BillingSchedule via l'API standalone (Context Service RLM_BillingContext),
 * UNIQUEMENT pour les lignes qui ont un RBP, avec quantité + montant = valeurs du RBP.
 *
 * Flux en 2 phases (l'API est asynchrone) :
 *   generateForMonth() -> sync OrderItems = valeurs RBP, callout, statut Validé
 *   finalizeForMonth() -> purge des BS hors-RBP, lien BillingScheduleId, statut Facturé
 */
public with sharing class RegieBillingController {

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

    // ---------- DTOs ----------
    public class Line {
        @AuraEnabled public Id id;
        @AuraEnabled public String name;
        @AuraEnabled public String grade;
        @AuraEnabled public String consultant;
        @AuraEnabled public Decimal jours;
        @AuraEnabled public Decimal tjm;
        @AuraEnabled public Decimal frais;
        @AuraEnabled public Decimal montant;
        @AuraEnabled public String status;
        @AuraEnabled public Boolean billed;
    }
    public class MonthGroup {
        @AuraEnabled public String monthIso;
        @AuraEnabled public String monthLabel;
        @AuraEnabled public String status;
        @AuraEnabled public Decimal total;
        @AuraEnabled public List<Line> lines;       // grades
        @AuraEnabled public List<Line> fraisLines;  // frais de déplacement
    }

    private static final Map<Integer,String> MOIS_FR = new Map<Integer,String>{
        1=>'Janvier',2=>'Février',3=>'Mars',4=>'Avril',5=>'Mai',6=>'Juin',
        7=>'Juillet',8=>'Août',9=>'Septembre',10=>'Octobre',11=>'Novembre',12=>'Décembre'};

    // ---------- Import Napta : seed des RBP (grades + frais) pour un mois ----------
    private static final List<String> CONSULTANTS = new List<String>{
        'Marie Lefèvre','Julien Moreau','Sophie Garnier','Thomas Bernard','Camille Rousseau',
        'Lucas Petit','Emma Fontaine','Hugo Mercier','Léa Chevalier','Nathan Girard',
        'Chloé Dumas','Maxime Robin','Inès Lambert','Antoine Faure','Manon Vidal'};
    private static final String FRAIS_CODE = 'FRAIS-DEPL';

    public class ImportRequest {
        @InvocableVariable(required=true label='Order Id') public Id orderId;
        @InvocableVariable(required=true label='Mois (yyyy-MM-dd)') public String monthIso;
    }

    @InvocableMethod(label='Import Napta - Générer plans régie'
        description='Crée un RegieBillingPlan par grade (+ ligne Frais si présente) pour le mois choisi, avec données fictives.')
    public static void importNapta(List<ImportRequest> reqs) {
        ImportRequest r = reqs[0];
        Date m = Date.valueOf(r.monthIso);
        String mm = (m.month() < 10 ? '0' : '') + String.valueOf(m.month());
        String monthKey = m.year() + '-' + mm;

        Set<String> existing = new Set<String>();
        for (RegieBillingPlan__c p : [SELECT ExternalKey__c FROM RegieBillingPlan__c
                WHERE Order__c = :r.orderId AND BillingMonth__c = :m])
            if (p.ExternalKey__c != null) existing.add(p.ExternalKey__c);

        List<RegieBillingPlan__c> toIns = new List<RegieBillingPlan__c>();
        Integer i = 0;
        for (OrderItem oi : [
                SELECT Id, OrderId, Order.AccountId, UnitPrice, Product2.Name, Product2.ProductCode
                FROM OrderItem WHERE OrderId = :r.orderId ORDER BY UnitPrice DESC]) {

            Boolean isFrais = oi.Product2.ProductCode == FRAIS_CODE
                || (oi.Product2.Name != null && oi.Product2.Name.startsWithIgnoreCase('Frais'));
            Boolean isGrade = oi.UnitPrice > 0;
            if (!isGrade && !isFrais) continue;          // exclut le bundle (prix 0, non-frais)

            String key = oi.Id + '|' + monthKey;
            if (existing.contains(key)) continue;

            i++;
            Decimal jours, tjm;
            String consultant;
            if (isFrais) {                               // ligne Frais : 1 x montant fictif (250..1000)
                jours = 1; tjm = 250 * Math.mod(i * 3, 4) + 250; consultant = null;
            } else {                                     // grade : jours fictifs 8..20, TJM = prix ligne
                jours = 8 + Math.mod(i * 5, 13); tjm = oi.UnitPrice;
                consultant = CONSULTANTS[Math.mod(i * 7, CONSULTANTS.size())];
            }
            toIns.add(new RegieBillingPlan__c(
                Order__c = oi.OrderId, OrderProduct__c = oi.Id, Account__c = oi.Order.AccountId,
                Grade__c = oi.Product2.Name, Consultant__c = consultant,
                BillingMonth__c = m, JoursReels__c = jours, TJM__c = tjm,
                FraisMontant__c = 0, Status__c = 'Brouillon', ExternalKey__c = key));
        }
        if (!toIns.isEmpty()) insert toIns;
    }

    // ---------- Lecture ----------
    @AuraEnabled
    public static List<MonthGroup> getMonths(Id orderId) {
        Map<Date,MonthGroup> byMonth = new Map<Date,MonthGroup>();
        for (RegieBillingPlan__c p : [
                SELECT Id, Name, Grade__c, Consultant__c, JoursReels__c, TJM__c, FraisMontant__c,
                       Montant__c, Status__c, BillingMonth__c, BillingScheduleId__c
                FROM RegieBillingPlan__c
                WHERE Order__c = :orderId
                ORDER BY BillingMonth__c ASC, TJM__c DESC NULLS LAST]) {

            MonthGroup g = byMonth.get(p.BillingMonth__c);
            if (g == null) {
                g = new MonthGroup();
                g.monthIso = p.BillingMonth__c == null ? '' : String.valueOf(p.BillingMonth__c);
                g.monthLabel = p.BillingMonth__c == null ? 'Sans mois'
                    : MOIS_FR.get(p.BillingMonth__c.month()) + ' ' + p.BillingMonth__c.year();
                g.total = 0; g.lines = new List<Line>(); g.fraisLines = new List<Line>();
                byMonth.put(p.BillingMonth__c, g);
            }
            Line l = new Line();
            l.id = p.Id; l.name = p.Name; l.grade = p.Grade__c; l.consultant = p.Consultant__c;
            l.jours = p.JoursReels__c; l.tjm = p.TJM__c; l.frais = p.FraisMontant__c;
            l.montant = p.Montant__c == null ? 0 : p.Montant__c;
            l.status = p.Status__c;
            l.billed = p.BillingScheduleId__c != null;
            if (p.Grade__c != null && p.Grade__c.startsWithIgnoreCase('Frais')) g.fraisLines.add(l);
            else g.lines.add(l);
            g.total += l.montant;
        }
        List<MonthGroup> out = byMonth.values();
        for (MonthGroup g : out) {
            List<Line> all = new List<Line>(g.lines);
            all.addAll(g.fraisLines);
            Boolean allBilled = !all.isEmpty(), anyBrouillon = false;
            for (Line l : all) {
                if (l.status != 'Facturé') allBilled = false;
                if (l.status == 'Brouillon') anyBrouillon = true;
            }
            g.status = allBilled ? 'Facturé' : (anyBrouillon ? 'Brouillon' : 'Validé');
        }
        return out;
    }

    // ---------- Suivi facturation : lifecycle des BillingSchedule ----------
    public class BLine {
        @AuraEnabled public String produit;
        @AuraEnabled public String consultant;
        @AuraEnabled public Decimal jours;
        @AuraEnabled public Decimal tjm;
        @AuraEnabled public Decimal total;
    }
    public class BMonth {
        @AuraEnabled public String monthIso;
        @AuraEnabled public String monthLabel;
        @AuraEnabled public Decimal total;
        @AuraEnabled public String statusLabel;
        @AuraEnabled public String statusVariant;
        @AuraEnabled public List<BLine> lines;       // grades
        @AuraEnabled public List<BLine> fraisLines;  // frais (affichés en bas)
    }
    public class BOverview {
        @AuraEnabled public Decimal totalValide;     // total régie (validé + facturé)
        @AuraEnabled public Decimal totalAFacturer;   // mois Validé (pas encore facturés)
        @AuraEnabled public Decimal totalFacture;     // mois Facturé
        @AuraEnabled public Integer nbSchedules;      // nb total de mois
        @AuraEnabled public Integer nbFacture;        // nb mois facturés
        @AuraEnabled public String aFacturerLabel;    // libellé du/des mois à facturer
        @AuraEnabled public List<BMonth> months;
    }

    // Basé sur les RBP (la vérité du cockpit) : Validé = à facturer, Facturé = déjà facturé.
    // Évite la confusion des BS récurrents (qui avancent + BilledAmount cumulatif).
    @AuraEnabled(cacheable=true)
    public static BOverview getBillingOverview(Id orderId) {
        BOverview ov = new BOverview();
        ov.totalValide = 0; ov.totalAFacturer = 0; ov.totalFacture = 0;
        Map<Date,BMonth> byMonth = new Map<Date,BMonth>();

        for (RegieBillingPlan__c p : [
                SELECT Grade__c, Consultant__c, JoursReels__c, TJM__c, Montant__c, Status__c, BillingMonth__c
                FROM RegieBillingPlan__c
                WHERE Order__c = :orderId AND Status__c IN ('Validé','Facturé')
                ORDER BY BillingMonth__c, TJM__c DESC NULLS LAST]) {

            Decimal mt = p.Montant__c == null ? 0 : p.Montant__c;
            BMonth bm = byMonth.get(p.BillingMonth__c);
            if (bm == null) {
                bm = new BMonth();
                bm.monthIso = String.valueOf(p.BillingMonth__c);
                bm.monthLabel = MOIS_FR.get(p.BillingMonth__c.month()) + ' ' + p.BillingMonth__c.year();
                bm.total = 0; bm.lines = new List<BLine>(); bm.fraisLines = new List<BLine>();
                bm.statusLabel = 'Facturé'; bm.statusVariant = 'success';
                byMonth.put(p.BillingMonth__c, bm);
            }
            BLine l = new BLine();
            l.produit = p.Grade__c; l.consultant = p.Consultant__c;
            l.jours = p.JoursReels__c; l.tjm = p.TJM__c; l.total = mt;
            if (p.Grade__c != null && p.Grade__c.startsWithIgnoreCase('Frais')) bm.fraisLines.add(l);
            else bm.lines.add(l);
            bm.total += mt;
            if (p.Status__c == 'Facturé') { ov.totalFacture += mt; }
            else { ov.totalAFacturer += mt; bm.statusLabel = 'À facturer'; bm.statusVariant = 'warning'; }
            ov.totalValide += mt;
        }

        List<Date> keys = new List<Date>(byMonth.keySet());
        keys.sort();
        ov.months = new List<BMonth>();
        ov.nbFacture = 0;
        List<String> aFacturer = new List<String>();
        for (Date k : keys) {
            BMonth bm = byMonth.get(k);
            ov.months.add(bm);
            if (bm.statusLabel == 'Facturé') ov.nbFacture++;
            else aFacturer.add(bm.monthLabel);
        }
        ov.nbSchedules = ov.months.size();
        ov.aFacturerLabel = aFacturer.isEmpty() ? '—'
            : (aFacturer.size() == 1 ? aFacturer[0] : aFacturer.size() + ' mois');
        return ov;
    }

    // ---------- Récap order : avancement de facturation par produit (grades) ----------
    public class RecapLine {
        @AuraEnabled public String produit;
        @AuraEnabled public Decimal joursVendus;
        @AuraEnabled public Decimal joursFactures;
        @AuraEnabled public Decimal joursRestants;
        @AuraEnabled public Decimal tjm;
        @AuraEnabled public Decimal montantRestant;
        @AuraEnabled public Integer avancement;   // % de jours facturés
    }
    public class Recap {
        @AuraEnabled public String orderName;
        @AuraEnabled public String orderNumber;
        @AuraEnabled public String account;
        @AuraEnabled public Date dateDebut;
        @AuraEnabled public Date dateFin;
        @AuraEnabled public Decimal montantCommande;     // TotalAmount de la commande
        @AuraEnabled public List<RecapLine> lines = new List<RecapLine>();
        @AuraEnabled public Decimal totalJoursVendus = 0;
        @AuraEnabled public Decimal totalJoursFactures = 0;
        @AuraEnabled public Decimal totalJoursRestants = 0;
        @AuraEnabled public Decimal totalMontantVendu = 0;
        @AuraEnabled public Decimal totalMontantRestant = 0;
        @AuraEnabled public Integer avancement = 0;
    }

    // Récap contractuel de la mission : par grade, jours vendus / facturés / restants + reste à facturer.
    // Exclut le bundle (prix 0) et les frais (pas d'enveloppe de jours, facturés au mois).
    @AuraEnabled(cacheable=true)
    public static Recap getOrderRecap(Id orderId) {
        Recap r = new Recap();
        for (Order o : [SELECT Name, OrderNumber, Account.Name, EffectiveDate, EndDate, TotalAmount
                        FROM Order WHERE Id = :orderId LIMIT 1]) {
            r.orderName = o.Name; r.orderNumber = o.OrderNumber;
            r.account = o.Account == null ? null : o.Account.Name;
            r.dateDebut = o.EffectiveDate; r.dateFin = o.EndDate;
            r.montantCommande = o.TotalAmount;
        }
        for (OrderItem oi : [
                SELECT Product2.Name, Product2.ProductCode, Quantity, UnitPrice, RSM_JoursFactures__c
                FROM OrderItem WHERE OrderId = :orderId ORDER BY UnitPrice DESC]) {

            Boolean isFrais = oi.Product2.ProductCode == FRAIS_CODE
                || (oi.Product2.Name != null && oi.Product2.Name.startsWithIgnoreCase('Frais'));
            if (isFrais) continue;
            if (oi.UnitPrice == null || oi.UnitPrice == 0) continue;   // bundle

            Decimal vendu   = oi.Quantity == null ? 0 : oi.Quantity;
            Decimal facture = oi.RSM_JoursFactures__c == null ? 0 : oi.RSM_JoursFactures__c;
            Decimal restant = vendu - facture; if (restant < 0) restant = 0;
            Decimal tjm = oi.UnitPrice;

            RecapLine rl = new RecapLine();
            rl.produit = oi.Product2.Name;
            rl.joursVendus = vendu; rl.joursFactures = facture; rl.joursRestants = restant;
            rl.tjm = tjm; rl.montantRestant = restant * tjm;
            rl.avancement = vendu > 0
                ? ((facture / vendu) * 100).setScale(0, System.RoundingMode.HALF_UP).intValue() : 0;
            r.lines.add(rl);

            r.totalJoursVendus += vendu;
            r.totalJoursFactures += facture;
            r.totalJoursRestants += restant;
            r.totalMontantVendu += vendu * tjm;
            r.totalMontantRestant += rl.montantRestant;
        }
        r.avancement = r.totalJoursVendus > 0
            ? ((r.totalJoursFactures / r.totalJoursVendus) * 100).setScale(0, System.RoundingMode.HALF_UP).intValue() : 0;
        return r;
    }

    // ---------- Sauvegarde des éditions inline ----------
    @AuraEnabled
    public static void saveLines(String linesJson) {
        List<Object> raw = (List<Object>) JSON.deserializeUntyped(linesJson);
        List<RegieBillingPlan__c> ups = new List<RegieBillingPlan__c>();
        for (Object o : raw) {
            Map<String,Object> m = (Map<String,Object>) o;
            RegieBillingPlan__c p = new RegieBillingPlan__c(Id = (Id) m.get('id'));
            if (m.get('jours') != null) p.JoursReels__c   = toDec(m.get('jours'));
            if (m.get('tjm')   != null) p.TJM__c          = toDec(m.get('tjm'));
            if (m.get('frais') != null) p.FraisMontant__c = toDec(m.get('frais'));
            ups.add(p);
        }
        if (!ups.isEmpty()) update ups;
    }

    // ---------- Phase 1a : sync OrderItems + statut Validé (DML uniquement) ----------
    @AuraEnabled
    public static void prepareMonth(Id orderId, String monthIso) {
        Date m = Date.valueOf(monthIso);
        List<RegieBillingPlan__c> plans = [
            SELECT Id, OrderProduct__c, JoursReels__c, TJM__c, BillingScheduleId__c
            FROM RegieBillingPlan__c
            WHERE Order__c = :orderId AND BillingMonth__c = :m];
        if (plans.isEmpty()) throw new AuraHandledException('Aucun plan régie pour ce mois.');

        // RÉGIE = facturation au mois, montant VARIABLE chaque mois. Les BS Evergreen sont récurrents
        // (montant fixe qui "avance"), donc on repart à zéro : on SUPPRIME tous les BS de l'order avant
        // de regénérer ceux du mois. Les mois déjà facturés restent tracés par leur INVOICE (permanente).
        Set<Id> bsgIds = new Set<Id>();
        for (BillingSchedule bs : [SELECT BillingScheduleGroupId FROM BillingSchedule WHERE ReferenceEntityId = :orderId])
            if (bs.BillingScheduleGroupId != null) bsgIds.add(bs.BillingScheduleGroupId);
        if (!bsgIds.isEmpty()) delete [SELECT Id FROM BillingScheduleGroup WHERE Id IN :bsgIds];

        // Sync OrderItems = valeurs validées du RBP.
        // Le billing lit le MONTANT figé (TotalLineAmount/NetTotalPrice), pas Quantity x UnitPrice
        // recalculé -> on injecte directement le montant = jours x TJM (pas de repricing nécessaire).
        // On normalise aussi le Billing Treatment sur "Régie Mensuelle (Arrears)" (recurring/mensuel) :
        // sinon une ligne avec un treatment Milestone rejette l'update (BillingFrequency2 != Milestone Plan).
        // On met TEMPORAIREMENT la qty/montant du MOIS sur l'OrderItem -> le BillingSchedule capte
        // la bonne Quantity (jours du mois) ET un montant cohérent (Qty x UnitPrice = TotalAmount)
        // -> PendingAmount correct. La quantité contractuelle est restaurée en phase finalize.
        List<OrderItem> ois = new List<OrderItem>();
        for (RegieBillingPlan__c p : plans) if (p.OrderProduct__c != null) {
            Decimal q   = p.JoursReels__c == null ? 0 : p.JoursReels__c;
            Decimal tjm = p.TJM__c == null ? 0 : p.TJM__c;
            Decimal amt = q * tjm;
            ois.add(new OrderItem(Id = p.OrderProduct__c,
                Quantity = q, UnitPrice = tjm, NetUnitPrice = tjm,
                TotalLineAmount = amt, NetTotalPrice = amt,
                ServiceDate = m,   // période du BS = le mois courant (sinon il garde l'ancien mois)
                BillingTreatmentId = getRegieTreatmentId(), BillingFrequency2 = 'Monthly'));
        }
        if (!ois.isEmpty()) {
            try { update ois; }
            catch (Exception e) {
                throw new AuraHandledException('Mise à jour des lignes impossible : ' + e.getMessage());
            }
        }

        for (RegieBillingPlan__c p : plans) { p.Status__c = 'Validé'; p.BillingScheduleId__c = null; p.ErrorMessage__c = null; }
        update plans;
    }

    // ---------- Phase 1b : callout API standalone (AUCUN DML avant) ----------
    @AuraEnabled
    public static void createSchedules(Id orderId) {
        callCreateSchedules(orderId);
    }

    // ---------- Facturation : crée + poste la facture du mois (ConnectApi in-process) ----------
    @AuraEnabled
    public static String createAndPostInvoice(Id orderId, String monthIso) {
        Date m = Date.valueOf(monthIso);
        List<RegieBillingPlan__c> plans = [SELECT Id, BillingScheduleId__c FROM RegieBillingPlan__c
            WHERE Order__c = :orderId AND BillingMonth__c = :m];
        if (plans.isEmpty()) throw new AuraHandledException('Aucun plan pour ce mois.');

        Set<Id> bsIds = new Set<Id>();
        for (RegieBillingPlan__c p : plans) if (p.BillingScheduleId__c != null) bsIds.add((Id) p.BillingScheduleId__c);
        if (bsIds.isEmpty()) throw new AuraHandledException('Aucun échéancier généré pour ce mois — valide d\'abord.');

        // targetDate = date de facturation (Arrears -> 1er du mois suivant), >= NextBillingDate des BS
        Date target = m.addMonths(1);
        for (BillingSchedule bs : [SELECT NextBillingDate FROM BillingSchedule WHERE Id IN :bsIds])
            if (bs.NextBillingDate != null && bs.NextBillingDate > target) target = bs.NextBillingDate;
        String tStr = DateTime.newInstance(target.year(), target.month(), target.day(), 0, 0, 0).format('yyyy-MM-dd');

        if (!Test.isRunningTest()) {
            List<String> ids = new List<String>();
            for (Id b : bsIds) ids.add(String.valueOf(b));
            ConnectApi.InvoiceInputRepresentation inp = new ConnectApi.InvoiceInputRepresentation();
            inp.billingScheduleIds = ids;
            inp.action = ConnectApi.InvoiceAction.Posted;   // crée ET poste
            inp.invoiceDate = tStr;
            inp.targetDate = tStr;
            ConnectApi.RevenueAsyncRepresentation res = ConnectApi.Billing.generateInvoices(inp);
            if (res == null || !res.success)
                throw new AuraHandledException('Échec facturation : ' + (res == null ? '' : String.valueOf(res.errors)));
        }

        for (RegieBillingPlan__c p : plans) p.Status__c = 'Facturé';
        update plans;
        return plans.size() + ' ligne(s) facturée(s) — facture créée et postée.';
    }

    // ---------- Facture TOUT l'order (mois validés) — pour la Quick Action ----------
    @AuraEnabled
    public static String invoiceOrder(Id orderId) {
        List<RegieBillingPlan__c> plans = [SELECT Id, BillingScheduleId__c FROM RegieBillingPlan__c
            WHERE Order__c = :orderId AND Status__c = 'Validé'];
        if (plans.isEmpty()) throw new AuraHandledException('Aucun mois validé à facturer sur cette mission.');

        // BS à facturer : on cible explicitement les échéanciers (les standalone BS ne se facturent
        // PAS via billingTransactionId — il faut passer leurs Ids, comme la facturation mensuelle).
        Set<Id> bsIds = new Set<Id>();
        for (RegieBillingPlan__c p : plans) if (p.BillingScheduleId__c != null) bsIds.add((Id) p.BillingScheduleId__c);
        // Filet de sécurité : si les RBP n'ont pas le lien, on prend les BS prêts de l'order.
        if (bsIds.isEmpty()) {
            for (BillingSchedule bs : [SELECT Id FROM BillingSchedule
                    WHERE ReferenceEntityId = :orderId AND Status = 'ReadyForInvoicing'])
                bsIds.add(bs.Id);
        }
        if (bsIds.isEmpty())
            throw new AuraHandledException('Aucun échéancier prêt à facturer — (re)valide le mois.');

        Date target = Date.today();
        for (BillingSchedule bs : [SELECT NextBillingDate FROM BillingSchedule WHERE Id IN :bsIds])
            if (bs.NextBillingDate != null && bs.NextBillingDate > target) target = bs.NextBillingDate;
        String tStr = DateTime.newInstance(target.year(), target.month(), target.day(), 0, 0, 0).format('yyyy-MM-dd');

        if (!Test.isRunningTest()) {
            List<String> ids = new List<String>();
            for (Id b : bsIds) ids.add(String.valueOf(b));
            ConnectApi.InvoiceInputRepresentation inp = new ConnectApi.InvoiceInputRepresentation();
            inp.billingScheduleIds = ids;             // <- facture réellement ces échéanciers
            inp.action = ConnectApi.InvoiceAction.Posted;
            inp.invoiceDate = tStr;
            inp.targetDate = tStr;
            ConnectApi.RevenueAsyncRepresentation res = ConnectApi.Billing.generateInvoices(inp);
            if (res == null || !res.success)
                throw new AuraHandledException('Échec facturation : ' + (res == null ? '' : String.valueOf(res.errors)));
        }

        for (RegieBillingPlan__c p : plans) p.Status__c = 'Facturé';
        update plans;
        return plans.size() + ' ligne(s) facturée(s) — facture créée et postée.';
    }

    // ---------- Rattache les invoices de l'order (ReferenceEntityId) pour la related list ----------
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

    // ---------- Phase 2 : purge hors-RBP + lien + Facturé ----------
    @AuraEnabled
    public static String finalizeForMonth(Id orderId, String monthIso) {
        Date m = Date.valueOf(monthIso);
        Map<Id,RegieBillingPlan__c> byOi = new Map<Id,RegieBillingPlan__c>();
        for (RegieBillingPlan__c p : [
                SELECT Id, OrderProduct__c FROM RegieBillingPlan__c
                WHERE Order__c = :orderId AND BillingMonth__c = :m])
            if (p.OrderProduct__c != null) byOi.put(p.OrderProduct__c, p);

        List<BillingSchedule> bss = [
            SELECT Id, ReferenceEntityItemId, BillingScheduleGroupId, BillingPeriodAmount
            FROM BillingSchedule WHERE ReferenceEntityId = :orderId];

        Set<Id> bsgToDelete = new Set<Id>();
        List<RegieBillingPlan__c> toUpdate = new List<RegieBillingPlan__c>();
        Integer kept = 0; Decimal total = 0;
        for (BillingSchedule bs : bss) {
            if (byOi.containsKey(bs.ReferenceEntityItemId)) {
                toUpdate.add(new RegieBillingPlan__c(Id = byOi.get(bs.ReferenceEntityItemId).Id,
                    Status__c = 'Validé', BillingScheduleId__c = bs.Id));
                kept++; total += bs.BillingPeriodAmount == null ? 0 : bs.BillingPeriodAmount;
            } else if (bs.BillingScheduleGroupId != null) {
                bsgToDelete.add(bs.BillingScheduleGroupId);   // ligne hors-RBP -> purge
            }
        }
        if (kept == 0) return 'PENDING';                       // BS pas encore matérialisés (async) -> le LWC réessaie
        if (!bsgToDelete.isEmpty()) delete [SELECT Id FROM BillingScheduleGroup WHERE Id IN :bsgToDelete];
        if (!toUpdate.isEmpty()) update toUpdate;

        // Décompte "jours facturés" par ligne = somme des RBP Facturé.
        // EXCLUT les frais (récurrent mensuel, pas d'enveloppe de jours).
        Map<Id,Decimal> billedByOi = new Map<Id,Decimal>();
        for (RegieBillingPlan__c p : [SELECT OrderProduct__c, JoursReels__c, Grade__c
                FROM RegieBillingPlan__c
                WHERE Order__c = :orderId AND Status__c IN ('Validé','Facturé') AND OrderProduct__c != null]) {
            if (p.Grade__c != null && p.Grade__c.startsWithIgnoreCase('Frais')) continue;
            Decimal c = billedByOi.containsKey(p.OrderProduct__c) ? billedByOi.get(p.OrderProduct__c) : 0;
            billedByOi.put(p.OrderProduct__c, c + (p.JoursReels__c == null ? 0 : p.JoursReels__c));
        }

        // Restaurer les valeurs CONTRACTUELLES depuis le devis (quantité ET prix) + poser le décompte.
        // -> les grades reviennent à leur quantité/TJM annuels, et les FRAIS reviennent à prix 0
        //    (le BillingSchedule a déjà figé la quantité/montant du mois).
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
            if (billedByOi.containsKey(oi.Id)) u.RSM_JoursFactures__c = billedByOi.get(oi.Id);
            oiUpd.add(u);
        }
        if (!oiUpd.isEmpty()) update oiUpd;
        return kept + ' échéancier(s) régie générés — total ' + total.setScale(0).format() + ' €.';
    }

    // ---------- Helpers ----------
    // Appel de l'action standard "Create Standalone Billing Schedules" EN PROCESS (Invocable.Action) :
    // pas de callout HTTP -> pas de session/Unauthorized, pas de Remote Site Setting.
    private static void callCreateSchedules(Id orderId) {
        if (Test.isRunningTest()) return;
        Invocable.Action a = Invocable.Action.createStandardAction('createBillingSchedulesFromTrxn');
        a.setInvocationParameter('transactionDetails', '{"BillingTransaction":[{"id":"' + orderId + '"}]}');
        a.setInvocationParameter('contextDefinitionName', CTX_DEF);
        a.setInvocationParameter('readContextMappingName', READ_MAP);
        a.setInvocationParameter('saveContextMappingName', SAVE_MAP);
        List<Invocable.Action.Result> rs = a.invoke();
        if (rs.isEmpty() || !rs[0].isSuccess()) {
            throw new AuraHandledException('Échec de génération : '
                + (rs.isEmpty() ? 'aucun résultat' : String.valueOf(rs[0].getErrors())));
        }
    }

    private static Decimal toDec(Object o) { return o == null ? null : Decimal.valueOf(String.valueOf(o)); }
}
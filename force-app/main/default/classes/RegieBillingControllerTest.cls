@isTest
private class RegieBillingControllerTest {

    private static Order makeOrder() {
        Account a = new Account(Name = 'Test Régie');
        insert a;
        Order o = new Order(AccountId = a.Id, EffectiveDate = Date.today(),
            Status = 'Draft', Pricebook2Id = Test.getStandardPricebookId());
        insert o;
        return o;
    }
    private static RegieBillingPlan__c makePlan(Order o, Date m) {
        RegieBillingPlan__c p = new RegieBillingPlan__c(
            Order__c = o.Id, Account__c = o.AccountId, Grade__c = 'Associé',
            BillingMonth__c = m, JoursReels__c = 5, TJM__c = 4200, FraisMontant__c = 100,
            Status__c = 'Brouillon', ExternalKey__c = 'k' + m);
        insert p;
        return p;
    }

    @isTest static void testReadAndSave() {
        Order o = makeOrder();
        Date m = Date.newInstance(2026, 6, 1);
        RegieBillingPlan__c p = makePlan(o, m);

        Test.startTest();
        List<RegieBillingController.MonthGroup> months = RegieBillingController.getMonths(o.Id);
        RegieBillingController.saveLines(JSON.serialize(new List<Object>{
            new Map<String,Object>{ 'id' => p.Id, 'jours' => 8, 'tjm' => 4200, 'frais' => 250 }
        }));
        Test.stopTest();

        System.assertEquals(1, months.size());
        RegieBillingPlan__c after = [SELECT JoursReels__c, FraisMontant__c FROM RegieBillingPlan__c WHERE Id = :p.Id];
        System.assertEquals(8, after.JoursReels__c);
        System.assertEquals(250, after.FraisMontant__c);
    }

    @isTest static void testGenerateAndFinalize() {
        Order o = makeOrder();
        Date m = Date.newInstance(2026, 6, 1);
        makePlan(o, m);

        Test.startTest();
        RegieBillingController.prepareMonth(o.Id, String.valueOf(m));
        RegieBillingController.createSchedules(o.Id);                 // no-op en test (Test.isRunningTest)
        String res = RegieBillingController.finalizeForMonth(o.Id, String.valueOf(m)); // pas de BS -> PENDING
        Test.stopTest();

        System.assertEquals('PENDING', res);
        System.assertEquals('Validé',
            [SELECT Status__c FROM RegieBillingPlan__c WHERE Order__c = :o.Id LIMIT 1].Status__c);
    }

    @isTest static void testImportNapta() {
        Account a = new Account(Name = 'Test Import');
        insert a;
        Product2 prod = new Product2(Name = 'Associé', ProductCode = 'PROD-ASSOC-REG', IsActive = true);
        insert prod;
        Id pb = Test.getStandardPricebookId();
        PricebookEntry pbe = new PricebookEntry(Pricebook2Id = pb, Product2Id = prod.Id,
            UnitPrice = 4200, IsActive = true);
        insert pbe;
        Order o = new Order(AccountId = a.Id, EffectiveDate = Date.today(),
            Status = 'Draft', Pricebook2Id = pb);
        insert o;
        OrderItem oi = new OrderItem(OrderId = o.Id, PricebookEntryId = pbe.Id,
            Product2Id = prod.Id, Quantity = 1, UnitPrice = 4200);
        insert oi;

        RegieBillingController.ImportRequest r = new RegieBillingController.ImportRequest();
        r.orderId = o.Id;
        r.monthIso = '2026-06-01';

        Test.startTest();
        RegieBillingController.importNapta(new List<RegieBillingController.ImportRequest>{ r });
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM RegieBillingPlan__c WHERE Order__c = :o.Id]);
    }

    @isTest static void testCreateAndPostInvoice() {
        Order o = makeOrder();
        Date m = Date.newInstance(2026, 6, 1);
        RegieBillingPlan__c p = makePlan(o, m);
        p.BillingScheduleId__c = '44bWs000002dh7BIAQ';   // BS factice (l'appel ConnectApi est sauté en test)
        p.Status__c = 'Validé';
        update p;

        Test.startTest();
        RegieBillingController.createAndPostInvoice(o.Id, String.valueOf(m));
        Test.stopTest();

        System.assertEquals('Facturé',
            [SELECT Status__c FROM RegieBillingPlan__c WHERE Id = :p.Id].Status__c);
    }

    @isTest static void testInvoiceOrderAndLink() {
        Order o = makeOrder();
        Date m = Date.newInstance(2026, 6, 1);
        RegieBillingPlan__c p = makePlan(o, m);
        p.BillingScheduleId__c = '44bWs000002dh7BIAQ';
        p.Status__c = 'Validé';
        update p;

        Test.startTest();
        RegieBillingController.invoiceOrder(o.Id);
        Integer n = RegieBillingController.linkInvoicesToOrder(o.Id);
        Test.stopTest();

        System.assertEquals('Facturé',
            [SELECT Status__c FROM RegieBillingPlan__c WHERE Id = :p.Id].Status__c);
        System.assertEquals(0, n);
    }

    @isTest static void testOrderRecap() {
        Order o = makeOrder();
        Test.startTest();
        RegieBillingController.Recap r = RegieBillingController.getOrderRecap(o.Id);
        Test.stopTest();
        System.assertNotEquals(null, r);
        System.assertEquals(0, r.lines.size());
        System.assertEquals(0, r.avancement);
    }

    @isTest static void testNoPlan() {
        Order o = makeOrder();
        Boolean threw = false;
        try { RegieBillingController.prepareMonth(o.Id, '2026-06-01'); }
        catch (Exception e) { threw = true; }
        System.assertEquals(true, threw);
    }
}
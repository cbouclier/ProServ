@isTest
private class GlobalBillingControllerTest {

    private static Order makeOrder() {
        Account a = new Account(Name = 'Test Global');
        insert a;
        Order o = new Order(AccountId = a.Id, EffectiveDate = Date.today(),
            Status = 'Draft', Pricebook2Id = Test.getStandardPricebookId());
        insert o;
        return o;
    }

    @isTest static void testGetMissions() {
        Order o = makeOrder();   // Draft : getMissions le retient via la présence de RBP
        Date m = Date.newInstance(2026, 6, 1);
        insert new RegieBillingPlan__c(
            Order__c = o.Id, Account__c = o.AccountId, Grade__c = 'Associé',
            BillingMonth__c = m, JoursReels__c = 5, TJM__c = 4200, FraisMontant__c = 0,
            Status__c = 'Brouillon', ExternalKey__c = 'g1');

        Test.startTest();
        GlobalBillingController.Summary s = GlobalBillingController.getMissions(String.valueOf(m));
        Test.stopTest();

        System.assertEquals(1, s.missions.size(), 'La mission régie doit apparaître');
        GlobalBillingController.Mission mi = s.missions[0];
        System.assertEquals('Regie', mi.model);
        System.assertEquals('À valider', mi.statut);
        System.assertEquals(1, s.nbATraiter);
    }

    @isTest static void testFacturerSelection() {
        Order o = makeOrder();
        Date m = Date.newInstance(2026, 6, 1);
        RegieBillingPlan__c p = new RegieBillingPlan__c(
            Order__c = o.Id, Account__c = o.AccountId, Grade__c = 'Associé',
            BillingMonth__c = m, JoursReels__c = 5, TJM__c = 4200, FraisMontant__c = 0,
            Status__c = 'Validé', BillingScheduleId__c = '44bWs000002dh7BIAQ', ExternalKey__c = 'g2');
        insert p;

        Test.startTest();
        String msg = GlobalBillingController.facturerSelection(new List<Id>{ o.Id });
        Test.stopTest();

        System.assert(msg.contains('1 mission'), 'Une mission doit être facturée');
        System.assertEquals('Facturé',
            [SELECT Status__c FROM RegieBillingPlan__c WHERE Id = :p.Id].Status__c);
    }

    @isTest static void testFacturerSelectionError() {
        Order o = makeOrder();   // aucun mois validé -> invoiceOrder lève, l'erreur est capturée
        Test.startTest();
        String msg = GlobalBillingController.facturerSelection(new List<Id>{ o.Id });
        Test.stopTest();
        System.assert(msg.contains('Ignorées'), 'L\'erreur doit être listée, pas propagée');
    }
}
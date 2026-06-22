@isTest
private class MilestoneBillingControllerTest {

    private static Order makeOrder() {
        Account a = new Account(Name = 'Test Milestone');
        insert a;
        Order o = new Order(AccountId = a.Id, EffectiveDate = Date.today(),
            Status = 'Draft', Pricebook2Id = Test.getStandardPricebookId());
        insert o;
        return o;
    }

    @isTest static void testGetMilestonesEmpty() {
        Order o = makeOrder();
        Test.startTest();
        MilestoneBillingController.Overview ov = MilestoneBillingController.getMilestones(o.Id);
        Test.stopTest();
        System.assertNotEquals(null, ov);
        System.assertEquals(0, ov.nbJalons);
        System.assertEquals(0, ov.avancement);
    }

    @isTest static void testAccomplishNone() {
        Order o = makeOrder();
        Boolean threw = false;
        Test.startTest();
        try { MilestoneBillingController.accomplishMilestone(o.Id, 'Lancement de la mission'); }
        catch (Exception e) { threw = true; }
        Test.stopTest();
        System.assertEquals(true, threw, 'Doit lever quand aucun jalon');
    }
}
public class PlaceSalesTransaction {

    // Input wrapper for Flow
    public class RefreshInput {
        @InvocableVariable(required=true)
        public Id quoteId;
    }

    // Output wrapper (optional - you can ignore it in Flow if not needed)
    public class RefreshOutput {
        @InvocableVariable
        public String message;
    }

    @InvocableMethod(label='Refresh Quote Pricing' description='Triggers a pricing refresh on the provided Quote via RevOps PlaceSalesTransaction API.')
    public static List<RefreshOutput> refreshPricingFromFlow(List<RefreshInput> inputs) {
        List<RefreshOutput> results = new List<RefreshOutput>();

        for (RefreshInput input : inputs) {
            try {
                // Required enums
                RevSalesTrxn.PricingPreferenceEnum pricingPrefEnum = RevSalesTrxn.PricingPreferenceEnum.FORCE;
                RevSalesTrxn.ConfigurationExecutionEnum configurationExecutionEnum = RevSalesTrxn.ConfigurationExecutionEnum.SKIP;

                // Quote record, PATCH with ID only
                RevSalesTrxn.RecordResource quoteRecord = new RevSalesTrxn.RecordResource(
                    Quote.SObjectType, 'PATCH', input.quoteId
                );

                RevSalesTrxn.RecordWithReferenceRequest refQuote =
                    new RevSalesTrxn.RecordWithReferenceRequest('refQuote', quoteRecord);

                List<RevSalesTrxn.RecordWithReferenceRequest> records = new List<RevSalesTrxn.RecordWithReferenceRequest>{ refQuote };
                RevSalesTrxn.GraphRequest graph = new RevSalesTrxn.GraphRequest('refreshPricingGraph', records);

                // Configuration options: skip rules & validation
                RevSalesTrxn.ConfigurationOptionsInput configOptions = new RevSalesTrxn.ConfigurationOptionsInput();
                configOptions.validateProductCatalog = false;
                configOptions.validateAmendRenewCancel = false;
                configOptions.executeConfigurationRules = false;
                configOptions.addDefaultConfiguration = false;

                // Execute transaction
                RevSalesTrxn.PlaceSalesTransactionResponse resp =
                    RevSalesTrxn.PlaceSalesTransactionExecutor.execute(
                        graph,
                        pricingPrefEnum,
                        configurationExecutionEnum,
                        configOptions,
                        null
                    );

                // Optionally return message for debug or display
                RefreshOutput output = new RefreshOutput();
                output.message = 'Pricing refresh triggered successfully for Quote: ' + input.quoteId;
                results.add(output);

            } catch (Exception e) {
                RefreshOutput failed = new RefreshOutput();
                failed.message = 'Error refreshing pricing for Quote ' + input.quoteId + ': ' + e.getMessage();
                results.add(failed);
            }
        }

        return results;
    }
}
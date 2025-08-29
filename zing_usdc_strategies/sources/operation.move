module zusdc::operations {
    use protocol::{market::Market, version::Version};
    use sui::clock::Clock;
    use zing_bank::patronage::{Self, Patronage};
    use zing_vault::vault::Vault;
    use zusdc::{config::StrategyConfig, scallop::ScallopStrategy};

    public fun recall_from_vault<T, P, YT>(
        config: &StrategyConfig,
        patronage: &mut Patronage<T>,
        vault: &mut Vault<T, YT>,
        amount_to_recall: u64,
        // scallop
        scallop_strategy: &mut ScallopStrategy<T>,
        version: &Version,
        market: &mut Market,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        config.assert_version();

        patronage::recall_from_vault!<T, P, YT>(
            patronage,
            vault,
            amount_to_recall,
            clock,
            |ticket| {
                // scallop
                scallop_strategy.withdraw(config, ticket, version, market, clock, ctx);
            },
        );
    }
}

module zusdc::scallop {
    use protocol::{market::Market, mint, redeem, reserve::MarketCoin, version::Version};
    use std::type_name::{Self, TypeName};
    use sui::{balance::{Self, Balance}, clock::Clock, coin};
    use zing_framework::token::PlatformCap;
    use zing_vault::vault::{
        Self,
        VaultAccess,
        Vault,
        StrategyRemovalTicket,
        RebalanceAmounts,
        WithdrawTicket
    };
    use zusdc::config::StrategyConfig;

    // === Errors ===

    // === Constants ===

    public struct ScallopStrategy<phantom T> has key, store {
        id: UID,
        vault_access: Option<VaultAccess>,
        underlying_nominal_value: u64,
        collected_profit: Balance<T>,
        market_coin: Balance<MarketCoin<T>>,
    }

    // === Events ===

    // === Method Aliases ===

    // === Public Functions ===

    // === Admin Functions ===
    public fun new<T>(_cap: &PlatformCap, ctx: &mut TxContext) {
        let strategy = ScallopStrategy<T> {
            id: object::new(ctx),
            vault_access: option::none(),
            underlying_nominal_value: 0,
            collected_profit: balance::zero(),
            market_coin: balance::zero(),
        };
        transfer::share_object(strategy);
    }

    public fun join_to_vault<T, YT>(
        self: &mut ScallopStrategy<T>,
        config: &StrategyConfig,
        cap: &PlatformCap,
        vault: &mut Vault<T, YT>,
        ctx: &mut TxContext,
    ) {
        config.assert_version();

        let access = vault::add_strategy(cap, vault, ctx);
        self.vault_access.fill(access);
    }

    public fun remove_from_vault<T, YT>(
        self: &mut ScallopStrategy<T>,
        version: &Version,
        market: &mut Market,
        config: &StrategyConfig,
        _cap: &PlatformCap,
        clock: &Clock,
        ctx: &mut TxContext,
    ): StrategyRemovalTicket<T, YT> {
        config.assert_version();

        let total_balance = redeem::redeem(
            version,
            market,
            coin::from_balance(self.market_coin.withdraw_all(), ctx),
            clock,
            ctx,
        );

        self.vault_access.extract().new_strategy_removal_ticket(total_balance.into_balance())
    }

    // === Public Functions ===
    public fun rebalance<T, YT>(
        self: &mut ScallopStrategy<T>,
        config: &StrategyConfig,
        _cap: &PlatformCap,
        vault: &mut Vault<T, YT>,
        amounts: &RebalanceAmounts,
        // scallop params
        version: &Version,
        market: &mut Market,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        config.assert_version();

        let vault_access = self.vault_access.borrow();
        let (can_borrow, to_repay) = amounts.rebalance_amounts_get(vault_access);

        // bad debt; it shouldn't happen
        if (to_repay > 0) {
            let required_scoin = to_scoin(
                version,
                market,
                type_name::get<T>(),
                clock,
                to_repay,
            );
            let mut redeemed_balance = redeem::redeem(
                version,
                market,
                coin::from_balance(self.market_coin.split(required_scoin), ctx),
                clock,
                ctx,
            ).into_balance();

            if (redeemed_balance.value() > to_repay) {
                let extra_amt = redeemed_balance.value() - to_repay;
                self.collected_profit.join(redeemed_balance.split(extra_amt));
            };

            let repaid = redeemed_balance.value();
            vault.strategy_repay(vault_access, redeemed_balance);

            self.underlying_nominal_value = self.underlying_nominal_value - repaid;
        } else if (can_borrow > 0) {
            // borrow available balance
            let borrow_amt = can_borrow.min(vault.free_balance());
            // borrow balance from vault
            let borrowed_balance = vault.strategy_borrow(vault_access, borrow_amt);

            let scoin = mint::mint(
                version,
                market,
                coin::from_balance(borrowed_balance, ctx),
                clock,
                ctx,
            );
            self.market_coin.join(scoin.into_balance());

            self.underlying_nominal_value = self.underlying_nominal_value + borrow_amt;
        };
    }

    public fun withdraw<T, YT>(
        self: &mut ScallopStrategy<T>,
        config: &StrategyConfig,
        ticket: &mut WithdrawTicket<T, YT>,
        version: &Version,
        market: &mut Market,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        config.assert_version();

        let vault_access = self.vault_access.borrow();
        let to_withdraw = ticket.withdraw_ticket_to_withdraw(vault_access);

        if (to_withdraw == 0) {
            return
        };

        let required_scoin = to_scoin(
            version,
            market,
            type_name::get<T>(),
            clock,
            to_withdraw,
        );
        let mut redeemed_balance = redeem::redeem(
            version,
            market,
            coin::from_balance(self.market_coin.split(required_scoin), ctx),
            clock,
            ctx,
        ).into_balance();

        if (redeemed_balance.value() > to_withdraw) {
            let extra_amt = redeemed_balance.value() - to_withdraw;
            self.collected_profit.join(redeemed_balance.split(extra_amt));
        };

        ticket.strategy_withdraw_to_ticket(vault_access, redeemed_balance);
        self.underlying_nominal_value = self.underlying_nominal_value - to_withdraw;
    }

    // === View Functions ===
    public fun to_scoin(
        version: &Version,
        market: &mut Market,
        coin_type: TypeName,
        clock: &Clock,
        coin_amount: u64,
    ): u64 {
        let (cash, debt, revenue, market_coin_supply) = get_reserve_stats(
            version,
            market,
            coin_type,
            clock,
        );

        let scoin_amount = if (market_coin_supply > 0) {
            math::u64::mul_div(
                coin_amount,
                market_coin_supply,
                cash + debt - revenue,
            )
        } else {
            coin_amount
        };

        // if the coin is too less, just throw error
        assert!(scoin_amount > 0, 1);

        scoin_amount
    }

    public fun from_scoin(
        version: &Version,
        market: &mut Market,
        coin_type: TypeName,
        clock: &Clock,
        scoin_amount: u64,
    ): u64 {
        let (cash, debt, revenue, market_coin_supply) = get_reserve_stats(
            version,
            market,
            coin_type,
            clock,
        );

        let coin_amount = math::u64::mul_div(
            scoin_amount,
            cash + debt - revenue,
            market_coin_supply,
        );

        coin_amount
    }

    public fun get_reserve_stats(
        version: &Version,
        market: &mut Market,
        coin_type: TypeName,
        clock: &Clock,
    ): (u64, u64, u64, u64) {
        // update to the latest reserve stats
        protocol::accrue_interest::accrue_interest_for_market(
            version,
            market,
            clock,
        );

        let vault = protocol::market::vault(market);
        let balance_sheets = protocol::reserve::balance_sheets(vault);

        let balance_sheet = x::wit_table::borrow(balance_sheets, coin_type);
        let (cash, debt, revenue, market_coin_supply) = protocol::reserve::balance_sheet(
            balance_sheet,
        );
        (cash, debt, revenue, market_coin_supply)
    }

    public fun total_collateral<T>(
        self: &ScallopStrategy<T>,
        version: &Version,
        market: &mut Market,
        clock: &Clock,
    ): u64 {
        from_scoin(version, market, type_name::get<T>(), clock, self.market_coin.value())
    }
}

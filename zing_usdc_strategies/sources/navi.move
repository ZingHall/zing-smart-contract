module zusdc::navi {
    use lending_core::{
        account::AccountCap,
        incentive_v2::Incentive as IncentiveV2,
        incentive_v3::{Self, Incentive as IncentiveV3},
        lending,
        logic,
        pool::Pool,
        storage::Storage
    };
    use oracle::oracle::PriceOracle;
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
    public struct NaviStrategy<phantom T> has key, store {
        id: UID,
        vault_access: Option<VaultAccess>,
        underlying_nominal_value: u64,
        collected_profit: Balance<T>,
        // This can not be exposed
        account: AccountCap,
    }
    // === Structs ===

    // === Events ===

    // === Method Aliases ===

    // === Admin Functions ===
    public fun new<T>(_cap: &PlatformCap, ctx: &mut TxContext) {
        let strategy = NaviStrategy<T> {
            id: object::new(ctx),
            vault_access: option::none(),
            underlying_nominal_value: 0,
            collected_profit: balance::zero(),
            account: lending::create_account(ctx),
        };
        transfer::share_object(strategy);
    }

    public fun join_to_vault<T, YT>(
        self: &mut NaviStrategy<T>,
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
        self: &mut NaviStrategy<T>,
        oracle: &PriceOracle,
        storage: &mut Storage,
        pool: &mut Pool<T>,
        asset: u8,
        incentive_v2: &mut IncentiveV2,
        incentive_v3: &mut IncentiveV3,
        config: &StrategyConfig,
        _cap: &PlatformCap,
        clock: &Clock,
    ): StrategyRemovalTicket<T, YT> {
        config.assert_version();

        // recall every assets
        let amount = self.total_collateral(storage, asset);
        let total_balance = incentive_v3::withdraw_with_account_cap<T>(
            clock,
            oracle,
            storage,
            pool,
            asset,
            amount,
            incentive_v2,
            incentive_v3,
            &self.account,
        );

        self.vault_access.extract().new_strategy_removal_ticket(total_balance)
    }

    // === Public Functions ===
    public fun rebalance<T, YT>(
        self: &mut NaviStrategy<T>,
        config: &StrategyConfig,
        _cap: &PlatformCap,
        vault: &mut Vault<T, YT>,
        amounts: &RebalanceAmounts,
        // navi params
        oracle: &PriceOracle,
        storage: &mut Storage,
        pool: &mut Pool<T>,
        asset: u8,
        incentive_v2: &mut IncentiveV2,
        incentive_v3: &mut IncentiveV3,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        config.assert_version();

        let vault_access = self.vault_access.borrow();
        let (can_borrow, to_repay) = amounts.rebalance_amounts_get(vault_access);

        if (to_repay > 0) {
            let mut repaid_balance = incentive_v3::withdraw_with_account_cap<T>(
                clock,
                oracle,
                storage,
                pool,
                asset,
                to_repay,
                incentive_v2,
                incentive_v3,
                &self.account,
            );

            if (repaid_balance.value() > to_repay) {
                let extra_amt = repaid_balance.value() - to_repay;
                self.collected_profit.join(repaid_balance.split(extra_amt));
            };

            let repaid = repaid_balance.value();
            vault.strategy_repay(vault_access, repaid_balance);

            self.underlying_nominal_value = self.underlying_nominal_value - repaid;
        } else {
            let borrow_amt = can_borrow.min(vault.free_balance());
            // borrow balance from vault
            let borrowed_balance = vault.strategy_borrow(vault_access, borrow_amt);

            incentive_v3::deposit_with_account_cap(
                clock,
                storage,
                pool,
                asset,
                coin::from_balance(borrowed_balance, ctx),
                incentive_v2,
                incentive_v3,
                &self.account,
            );
        };
    }

    public fun withdraw<T, YT>(
        self: &mut NaviStrategy<T>,
        config: &StrategyConfig,
        ticket: &mut WithdrawTicket<T, YT>,
        _cap: &PlatformCap,
        // navi params
        oracle: &PriceOracle,
        storage: &mut Storage,
        pool: &mut Pool<T>,
        asset: u8,
        incentive_v2: &mut IncentiveV2,
        incentive_v3: &mut IncentiveV3,
        clock: &Clock,
    ) {
        config.assert_version();

        let vault_access = self.vault_access.borrow();
        let to_withdraw = ticket.withdraw_ticket_to_withdraw(vault_access);

        if (to_withdraw == 0) {
            return
        };

        let mut withdrawal = incentive_v3::withdraw_with_account_cap<T>(
            clock,
            oracle,
            storage,
            pool,
            asset,
            to_withdraw,
            incentive_v2,
            incentive_v3,
            &self.account,
        );

        if (withdrawal.value() > to_withdraw) {
            let extra_amt = withdrawal.value() - to_withdraw;
            self.collected_profit.join(withdrawal.split(extra_amt));
        };

        ticket.strategy_withdraw_to_ticket(vault_access, withdrawal);
        self.underlying_nominal_value = self.underlying_nominal_value - to_withdraw;
    }

    // === View Functions ===
    public fun total_collateral<T>(self: &NaviStrategy<T>, storage: &mut Storage, asset: u8): u64 {
        logic::user_collateral_balance(
            storage,
            asset,
            object::id(&self.account).to_address(),
        ) as u64
    }

    // === Package Functions ===

    // === Private Functions ===
}

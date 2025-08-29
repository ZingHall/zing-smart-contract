module zusdc::navi {
    use lending_core::account::AccountCap;
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
        account: AccountCap,
    }
    // === Structs ===

    // === Events ===

    // === Method Aliases ===

    // === Public Functions ===

    // === View Functions ===

    // === Admin Functions ===

    // === Package Functions ===

    // === Private Functions ===
}

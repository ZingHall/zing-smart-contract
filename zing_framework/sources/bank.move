module zing_framework::bank {
    use std::type_name::{Self, TypeName};
    use sui::{balance::{Self, Balance}, vec_set::{Self, VecSet}};
    use zing_framework::token::{TokenCap, PlatformCap, Token};

    // === Imports ===

    // === Errors ===
    const ENotAllowedAssetToken: u64 = 101;
    // === Constants ===

    // === Structs ===
    public struct BankConfig has key {
        id: UID,
        // allowed type
        allowlist: VecSet<TypeName>,
    }
    public struct Bank<phantom P, phantom T> has key {
        id: UID,
        ptoken_cap: TokenCap<P>,
        funds_available: Balance<T>,
        // track the deposited asset token
        deposited_token: u64,
    }

    // === Events ===

    // === Method Aliases ===

    // === Admin Functions ===
    fun init(ctx: &mut TxContext) {
        transfer::share_object(BankConfig { id: object::new(ctx), allowlist: vec_set::empty() })
    }

    public fun add_allowlist<T>(config: &mut BankConfig, _cap: &PlatformCap) {
        config.allowlist.insert(type_name::get<T>())
    }

    public fun remove_allowlist<T>(config: &mut BankConfig, _cap: &PlatformCap) {
        config.allowlist.remove(&type_name::get<T>())
    }

    public fun new<P, T>(config: &BankConfig, ptoken_cap: TokenCap<P>, ctx: &mut TxContext) {
        assert!(config.allowlist.contains(&type_name::get<T>()), ENotAllowedAssetToken);

        transfer::share_object(Bank<P, T> {
            id: object::new(ctx),
            ptoken_cap,
            funds_available: balance::zero(),
            deposited_token: 0,
        });
    }

    // === Public Functions ===
    public fun deposit<P, T>(
        bank: &mut Bank<P, T>,
        deposit: Balance<T>,
        ctx: &mut TxContext,
    ): Token<P> {
        let amount = deposit.value();
        bank.funds_available.join(deposit);

        bank.ptoken_cap.mint(amount, ctx)
    }

    public fun burn<P, T>(
        bank: &mut Bank<P, T>,
        ptoken: Token<T>,
        ctx: &mut TxContext,
    ): Balance<T> {
        let amount = ptoken.value();
        // TODO: withdraw from vault
        bank.ptoken_cap.burn(ptoken);
        bank.funds_available.split(amount)
    }

    // === View Functions ===

    // === Package Functions ===

    // === Private Functions ===

    // === Test Functions ===
}

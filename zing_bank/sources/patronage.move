module zing_bank::patronage {
    use std::type_name::{Self, TypeName};
    use sui::{
        balance::{Self, Balance},
        clock::Clock,
        coin::{Self, Coin},
        dynamic_field as df,
        dynamic_object_field as dof,
        vec_set::{Self, VecSet}
    };
    use zing_framework::{profile::Profile, token::{TokenCap, PlatformCap, Token}};
    use zing_vault::vault::{Vault, WithdrawTicket};

    // === Imports ===

    // === Errors ===
    const EPositiveDeposit: u64 = 101;
    const ERemainingAsset: u64 = 102;
    const EZeroAsset: u64 = 103;
    const EInsufficientRecallWithdrawal: u64 = 104;

    // === Constants ===

    // === Structs ===
    public struct Patronage<phantom T> has key, store {
        id: UID,
    }

    public struct BalanceKey<phantom P> has copy, drop, store {}

    public struct PositionKey<phantom P> has copy, drop, store {}
    public struct Position<phantom T, phantom P> has key, store {
        id: UID,
        ptoken_cap: TokenCap<P>,
        funds_available: Balance<T>,
        /// track the deposited asset token
        deposited_token: u64,
        asset: VecSet<TypeName>,
    }

    // === View Functions ===
    // >>> Patronage
    public fun position<T, P>(self: &Patronage<T>): &Position<T, P> {
        dof::borrow(&self.id, PositionKey<T> {})
    }

    fun position_mut<T, P>(self: &mut Patronage<T>): &mut Position<T, P> {
        dof::borrow_mut(&mut self.id, PositionKey<T> {})
    }

    // >>> Position
    public fun funds_available<T, P>(position: &Position<T, P>): u64 {
        position.funds_available.value()
    }

    public fun deposited_token<T, P>(position: &Position<T, P>): u64 {
        position.deposited_token
    }

    public fun position_balance_of<T, P, Asset>(position: &Position<T, P>): &Balance<Asset> {
        df::borrow(&position.id, BalanceKey<Asset> {})
    }

    fun position_balance_of_mut<T, P, Asset>(position: &mut Position<T, P>): &mut Balance<Asset> {
        df::borrow_mut(&mut position.id, BalanceKey<Asset> {})
    }

    public fun is_position_balance_exists<T, P, Asset>(position: &Position<T, P>): bool {
        df::exists_(&position.id, BalanceKey<Asset> {})
    }

    public fun position_value<T, P, YT>(
        position: &Position<T, P>,
        vault: &Vault<T, YT>,
        clock: &Clock,
    ): u64 {
        vault.from_underlying_amount(position.position_balance_of<T, P, YT>().value(), clock)
    }

    // === Events ===

    // === Method Aliases ===

    // === Admin Functions ===
    public fun new<T>(_cap: &PlatformCap, ctx: &mut TxContext): Patronage<T> {
        Patronage<T> {
            id: object::new(ctx),
        }
    }

    public fun default<T>(_cap: &PlatformCap, ctx: &mut TxContext) {
        let patronage = Patronage<T> {
            id: object::new(ctx),
        };

        transfer::public_share_object(patronage);
    }

    public fun open_position<T, P>(
        self: &mut Patronage<T>,
        ptoken_cap: TokenCap<P>,
        ctx: &mut TxContext,
    ) {
        let position = Position<T, P> {
            id: object::new(ctx),
            ptoken_cap,
            funds_available: balance::zero(),
            deposited_token: 0,
            asset: vec_set::empty(),
        };

        dof::add(&mut self.id, PositionKey<P> {}, position);
    }

    public fun close_position<T, P>(self: &mut Patronage<T>, profile: &Profile<P>) {
        let reserve = dof::remove<PositionKey<P>, Position<T, P>>(&mut self.id, PositionKey<P> {});

        let Position<T, P> {
            id,
            ptoken_cap,
            funds_available,
            deposited_token,
            asset,
        } = reserve;

        object::delete(id);
        assert!(asset.is_empty(), ERemainingAsset);
        funds_available.destroy_zero();
        assert!(deposited_token == 0, EPositiveDeposit);

        // transfer back to owner
        transfer::public_transfer(ptoken_cap, profile.owner());
    }

    // === Public Functions ===

    // Follower deposit the funds
    public fun deposit<T, P>(
        self: &mut Patronage<T>,
        deposit: Balance<T>,
        ctx: &mut TxContext,
    ): Token<P> {
        let amount = deposit.value();

        let position = self.position_mut<T, P>();

        position.funds_available.join(deposit);
        position.deposited_token = position.deposited_token + amount;
        position.ptoken_cap.mint(amount, ctx)
    }

    // Follower withdraw the funds
    public fun burn<T, P>(self: &mut Patronage<T>, ptoken: Token<P>, ctx: &TxContext): Balance<T> {
        let amount = ptoken.value();

        let position_mut = self.position_mut<T, P>();

        position_mut.ptoken_cap.burn(ptoken, ctx);
        position_mut.deposited_token = position_mut.deposited_token - amount;
        position_mut.funds_available.split(amount)
    }

    public fun deploy_to_vault<T, P, YT>(
        self: &mut Patronage<T>,
        vault: &mut Vault<T, YT>,
        amount_to_deploy: u64,
        clock: &Clock,
    ) {
        let position_mut = self.position_mut<T, P>();

        let deposit = position_mut.funds_available.split(amount_to_deploy);
        let lp_balance = vault.deposit(deposit, clock);

        // initialize zero balance if non-exists
        if (!position_mut.is_position_balance_exists<T, P, YT>()) {
            df::add(&mut position_mut.id, BalanceKey<YT> {}, balance::zero<YT>());
            position_mut.asset.insert(type_name::get<YT>());
        };

        position_mut.position_balance_of_mut<T, P, YT>().join(lp_balance);
    }

    public struct RecallReceipt<phantom T, phantom P, phantom YT> {
        withdrawal: u64,
    }

    public fun start_recall<T, P, YT>(
        self: &mut Patronage<T>,
        vault: &mut Vault<T, YT>,
        amount_to_recall: u64,
        clock: &Clock,
    ):(WithdrawTicket<T, YT>, RecallReceipt<T, P, YT>){
        let position = self.position<T, P>();
        assert!(position.position_balance_of<T, P, YT>().value() > 0, EZeroAsset);

        let withdraw_ticket = vault.withdraw_t_amt(
            amount_to_recall,
            self.position_mut<T, P>().position_balance_of_mut<T, P, YT>(),
            clock,
        );

        let receipt = RecallReceipt{ withdrawal: amount_to_recall };

        (withdraw_ticket, receipt)
    }

    public fun settle_recall<T, P, YT>(
        self: &mut Patronage<T>,
        receipt: RecallReceipt<T, P, YT>,
        withdrawal_bal: Balance<T>,
    ) {
        let RecallReceipt{
            withdrawal
        } = receipt;

        assert!(withdrawal_bal.value() >= withdrawal, EInsufficientRecallWithdrawal);

        self.position_mut<T, P>().funds_available.join(withdrawal_bal);
    }

    public fun collect_reward<T, P, YT>(
        self: &mut Patronage<T>,
        _profile: &Profile<P>,
        vault: &mut Vault<T, YT>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): Coin<T> {
        let position_mut = self.position_mut<T, P>();
        let surplus = position_mut.position_value(vault, clock) - position_mut.deposited_token;

        coin::from_balance(position_mut.funds_available.split(surplus), ctx)
    }
}

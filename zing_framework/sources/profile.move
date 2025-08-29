module zing_framework::profile {
    use sui::{balance::{Self, Supply}, coin::TreasuryCap, package, table::{Self, Table}};
    use zing_framework::token::{Self, PlatFormPolicy};

    // === Errors ===
    const EBadWitness: u64 = 1;
    const EAlreadyRegistered: u64 = 8;
    // === Constants ===

    // === Structs ===
    public struct PROFILE has drop {}

    public struct MemberReg has key {
        id: UID,
        registry: Table<address, ID>,
    }

    public struct ProfileEligibility<phantom P> has key {
        id: UID,
        supply: Supply<P>,
    }

    public struct Profile<phantom P> has key {
        id: UID,
        owner: address,
    }

    public fun owner<P>(self: &Profile<P>): address {
        self.owner
    }

    // === Events ===

    // === Method Aliases ===

    // === Admin Functions ===
    fun init(otw: PROFILE, ctx: &mut TxContext) {
        // MemberReg
        let reg = MemberReg {
            id: object::new(ctx),
            registry: table::new(ctx),
        };
        transfer::share_object(reg);
        // package
        package::claim_and_keep(otw, ctx);
    }

    // === Public Functions ===
    // called from init function to create otw
    public fun apply_eligibility<P: drop>(witness: P, ctx: &mut TxContext) {
        assert!(sui::types::is_one_time_witness(&witness), EBadWitness);

        let eligibility = ProfileEligibility<P> {
            id: object::new(ctx),
            supply: balance::create_supply(witness),
        };

        sui::transfer::transfer(eligibility, ctx.sender());
    }

    #[allow(lint(self_transfer))]
    public fun register<P>(
        member_reg: &mut MemberReg,
        platform_policy: &mut PlatFormPolicy,
        eligibility: ProfileEligibility<P>,
        ctx: &mut TxContext,
    ) {
        let sender = ctx.sender();
        // check eligibility
        assert!(!member_reg.registry.contains(sender), EAlreadyRegistered);
        // create profile
        let profile = Profile<P> { id: object::new(ctx), owner: sender };
        // create tokenCap
        let ProfileEligibility<P> {
            id,
            supply,
        } = eligibility;
        object::delete(id);

        let token_cap = token::new(platform_policy, supply, ctx);

        transfer::transfer(profile, ctx.sender());
        transfer::public_transfer(token_cap, ctx.sender());
    }
    // === View Functions ===

    // === Package Functions ===

    // === Private Functions ===

    // === Test Functions ===
}

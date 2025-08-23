module zing_framework::profile {
    use std::ascii::String;
    use sui::{package, table::{Self, Table}, types::is_one_time_witness};

    // === Errors ===
    const EBadWitness: u64 = 8;
    // === Constants ===

    // === Structs ===
    public struct PROFILE has drop {}

    public struct AdminCap has key, store {
        id: UID,
    }

    public struct MemberReg has key {
        id: UID,
        registry: Table<address, ID>,
    }

    public struct Profile<phantom T> has key {
        id: UID,
        img_url: String,
        name: String,
    }

    // === Events ===

    // === Method Aliases ===

    // === Admin Functions ===
    fun init(otw: PROFILE, ctx: &mut TxContext) {
        // AdminCap
        let cap = AdminCap {
            id: object::new(ctx),
        };
        transfer::transfer(cap, ctx.sender());
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
    public fun register<T: drop>(witness: T, name: String, ctx: &mut TxContext) {
        assert!(is_one_time_witness(&witness), EBadWitness);

        let profile = Profile<T> { id: object::new(ctx), name };

        transfer::transfer(profile, ctx.sender());
    }
    // === View Functions ===

    // === Package Functions ===

    // === Private Functions ===

    // === Test Functions ===
}

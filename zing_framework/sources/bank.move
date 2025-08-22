module zing_framework::bank {
    use zing_framework::token::TokenCap;

    // === Imports ===

    // === Errors ===

    // === Constants ===

    // === Structs ===
    public struct Bank<phantom T> has key {
        id: UID,
        token_cap: TokenCap<T>,
        conversion_rate: u64,
    }

    // === Events ===

    // === Method Aliases ===

    // === Public Functions ===

    // === View Functions ===

    // === Admin Functions ===

    // === Package Functions ===

    // === Private Functions ===

    // === Test Functions ===
}

module zing::account {
    // Shared object
    use sui::vec_set::VecSet;

    public struct Account has key {
        id: UID,
        owners: VecSet<address>,
    }
}

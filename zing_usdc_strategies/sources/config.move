module zusdc::config {
    use sui::vec_set::{Self, VecSet};
    use zing_framework::token::PlatformCap;

    const PACKAGE_VERSION: u64 = 1;

    const EInvalidVersion: u64 = 100;

    public fun package_version(): u64 {
        PACKAGE_VERSION
    }

    public struct StrategyConfig has key {
        id: UID,
        versions: VecSet<u64>,
    }

    fun init(ctx: &mut TxContext) {
        let config = StrategyConfig {
            id: object::new(ctx),
            versions: vec_set::singleton(package_version()),
        };

        transfer::share_object(config);
    }

    public fun add_version(self: &mut StrategyConfig, _cap: &PlatformCap, version: u64) {
        self.versions.insert(version);
    }

    public fun remove_version(self: &mut StrategyConfig, _cap: &PlatformCap, version: u64) {
        self.versions.remove(&version);
    }

    public(package) fun assert_version(self: &StrategyConfig) {
        assert!(self.versions.contains(&package_version()), EInvalidVersion);
    }
}

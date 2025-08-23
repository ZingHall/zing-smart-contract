module zing_framework::token {
    use std::{ascii::String, type_name::{Self, TypeName}};
    use sui::{
        balance::{Self, Balance, Supply},
        coin::TreasuryCap,
        dynamic_field as df,
        package,
        vec_map::{Self, VecMap},
        vec_set::{Self, VecSet}
    };

    // === Errors ===
    const EUnknownAction: u64 = 0;
    const ENotApproved: u64 = 1;
    const ENonZeroSupply: u64 = 2;
    const EBalanceTooLow: u64 = 3;
    const ENotZero: u64 = 4;
    const ECantConsumeBalance: u64 = 5;
    const ENoConfig: u64 = 6;
    const EUseImmutableConfirm: u64 = 7;

    // === Constants ===

    // Actions
    /// A Tag for the `spend` action.
    const SPEND: vector<u8> = b"spend";

    public fun spend_action(): String {
        let spend_str = SPEND;
        spend_str.to_ascii_string()
    }

    /// A Tag for the `transfer` action.
    const TRANSFER: vector<u8> = b"transfer";

    public fun transfer_action(): String {
        let transfer_str = TRANSFER;
        transfer_str.to_ascii_string()
    }

    // === Structs ===
    public struct TOKEN has drop {}

    public struct PlatformCap has key, store {
        id: UID,
    }

    public struct PlatFormPolicy has key {
        id: UID,
        default_rules: VecMap<String, VecSet<TypeName>>,
    }

    public struct PolicyRulesKey<phantom T> has copy, drop, store {}

    public fun default_rules(platform_policy: &PlatFormPolicy): &VecMap<String, VecSet<TypeName>> {
        &platform_policy.default_rules
    }

    public fun policy_rules_of<T>(
        platform_policy: &PlatFormPolicy,
    ): &VecMap<String, VecSet<TypeName>> {
        let policy_key = PolicyRulesKey<T> {};
        if (df::exists_(&platform_policy.id, policy_key))
            df::borrow(&platform_policy.id, policy_key) else &platform_policy.default_rules
    }

    fun policy_rules_of_mut<T>(
        platform_policy: &mut PlatFormPolicy,
    ): &mut VecMap<String, VecSet<TypeName>> {
        let policy_key = PolicyRulesKey<T> {};
        if (df::exists_(&platform_policy.id, policy_key))
            df::borrow_mut(
            &mut platform_policy.id,
            policy_key,
        ) else &mut platform_policy.default_rules
    }

    public struct TokenCap<phantom T> has key {
        id: UID,
        /// The current circulating supply
        supply: Supply<T>,
        /// The total max supply allowed to exist at any time that was issued
        /// upon creation of Asset T
        total_supply: u64,
        /// TAs of type T can be burned by the admin
        burnable: bool,
    }

    // To comply ERC-1155 standard, we allow config additional fields
    public struct Token<phantom T> has key {
        id: UID,
        balance: Balance<T>,
    }

    public struct ActionRequest<phantom T> {
        name: String,
        /// Amount is present in all of the txs
        amount: u64,
        /// Sender is a permanent field always
        sender: address,
        /// Recipient is only available in `transfer` action.
        recipient: Option<address>,
        /// The balance to be "spent" in the `TokenPolicy`, only available
        /// in the `spend` action.
        spent_balance: Option<Balance<T>>,
        /// Collected approvals (stamps) from completed `Rules`. They're matched
        /// against `TokenPolicy.rules` to determine if the request can be
        /// confirmed.
        approvals: VecSet<TypeName>,
    }

    public struct RuleKey<phantom T> has copy, drop, store { is_protected: bool }

    // === Events ===

    // === Method Aliases ===

    // === Admin Functions ===
    fun init(otw: TOKEN, ctx: &mut TxContext) {
        package::claim_and_keep(otw, ctx);

        transfer::public_transfer(PlatformCap { id: object::new(ctx) }, ctx.sender());
    }

    // === Public Functions ===
    /// Called by publisher to acquire Supply object after their publish
    public fun new<T>(
        platform_policy: &mut PlatFormPolicy,
        treasury_cap: TreasuryCap<T>,
        ctx: &mut TxContext,
    ): TokenCap<T> {
        assert!(treasury_cap.total_supply() == 0, ENonZeroSupply);
        let token_cap = TokenCap {
            id: object::new(ctx),
            supply: treasury_cap.treasury_into_supply(),
            total_supply: 0,
            burnable: false,
        };

        // add policy
        df::add(
            &mut platform_policy.id,
            PolicyRulesKey<T> {},
            vec_map::empty<String, VecSet<TypeName>>(),
        );

        token_cap
    }

    /// Transfer a `Token` to a `recipient`. Creates an `ActionRequest` for the
    /// "transfer" action. The `ActionRequest` contains the `recipient` field
    /// to be used in verification.
    public fun transfer<T>(t: Token<T>, recipient: address, ctx: &mut TxContext): ActionRequest<T> {
        let amount = t.balance.value();
        transfer::transfer(t, recipient);

        new_request(
            transfer_action(),
            amount,
            option::some(recipient),
            option::none(),
            ctx,
        )
    }

    /// Spend a `Token` by unwrapping it and storing the `Balance` in the
    /// `ActionRequest` for the "spend" action. The `ActionRequest` contains
    /// the `spent_balance` field to be used in verification.
    ///
    /// Spend action requires `confirm_request_mut` to be called to confirm the
    /// request and join the spent balance with the `TokenPolicy.spent_balance`.
    public fun spend<T>(t: Token<T>, ctx: &mut TxContext): ActionRequest<T> {
        let Token { id, balance } = t;
        id.delete();

        new_request(
            spend_action(),
            balance.value(),
            option::none(),
            option::some(balance),
            ctx,
        )
    }

    /// Join two `Token`s into one, always available.
    public fun join<T>(token: &mut Token<T>, another: Token<T>) {
        let Token { id, balance } = another;
        token.balance.join(balance);
        id.delete();
    }

    /// Split a `Token` with `amount`.
    /// Aborts if the `Token.balance` is lower than `amount`.
    public fun split<T>(token: &mut Token<T>, amount: u64, ctx: &mut TxContext): Token<T> {
        assert!(token.balance.value() >= amount, EBalanceTooLow);
        Token {
            id: object::new(ctx),
            balance: token.balance.split(amount),
        }
    }

    /// Create a zero `Token`.
    public fun zero<T>(ctx: &mut TxContext): Token<T> {
        Token {
            id: object::new(ctx),
            balance: balance::zero(),
        }
    }

    /// Destroy an empty `Token`, fails if the balance is non-zero.
    /// Aborts if the `Token.balance` is not zero.
    public fun destroy_zero<T>(token: Token<T>) {
        let Token { id, balance } = token;
        assert!(balance.value() == 0, ENotZero);
        balance.destroy_zero();
        id.delete();
    }

    #[allow(lint(self_transfer))]
    /// Transfer the `Token` to the transaction sender.
    public fun keep<T>(token: Token<T>, ctx: &mut TxContext) {
        transfer::transfer(token, ctx.sender())
    }

    // === Request Handling ===

    /// Create a new `ActionRequest`.
    /// Publicly available method to allow for custom actions.
    public fun new_request<T>(
        name: String,
        amount: u64,
        recipient: Option<address>,
        spent_balance: Option<Balance<T>>,
        ctx: &TxContext,
    ): ActionRequest<T> {
        ActionRequest {
            name,
            amount,
            recipient,
            spent_balance,
            sender: ctx.sender(),
            approvals: vec_set::empty(),
        }
    }

    /// Confirm the request against the `TokenPolicy` and return the parameters
    /// of the request: (Name, Amount, Sender, Recipient).
    ///
    /// Cannot be used for `spend` and similar actions that deliver `spent_balance`
    /// to the `TokenPolicy`. For those actions use `confirm_request_mut`.
    ///
    /// Aborts if:
    /// - the action is not allowed (missing record in `rules`)
    /// - action contains `spent_balance` (use `confirm_request_mut`)
    /// - the `ActionRequest` does not meet the `TokenPolicy` rules for the action
    public fun confirm_request<T>(
        platform_policy: &PlatFormPolicy,
        request: ActionRequest<T>,
        _ctx: &mut TxContext,
    ): (String, u64, address, Option<address>) {
        assert!(request.spent_balance.is_none(), ECantConsumeBalance);
        let policy_rules = platform_policy.policy_rules_of<T>();
        assert!(policy_rules.contains(&request.name), EUnknownAction);

        let ActionRequest {
            name,
            approvals,
            spent_balance,
            amount,
            sender,
            recipient,
        } = request;

        spent_balance.destroy_none();

        let rules = policy_rules[&name].into_keys();
        let rules_len = rules.length();
        let mut i = 0;

        while (i < rules_len) {
            let rule = &rules[i];
            assert!(approvals.contains(rule), ENotApproved);
            i = i + 1;
        };

        (name, amount, sender, recipient)
    }

    public fun confirm_request_mut<T>(
        platform_policy: &mut PlatFormPolicy,
        request: ActionRequest<T>,
        ctx: &mut TxContext,
    ): (String, u64, address, Option<address>) {
        let policy_rules = platform_policy.policy_rules_of<T>();
        assert!(policy_rules.contains(&request.name), EUnknownAction);
        assert!(request.spent_balance.is_some(), EUseImmutableConfirm);

        // TODO: do we need to add spent balance, and extract
        // policy.spent_balance.join(request.spent_balance.extract());

        confirm_request(platform_policy, request, ctx)
    }

    // === Rules API ===

    public fun add_approval<T, W: drop>(
        _t: W,
        request: &mut ActionRequest<T>,
        _ctx: &mut TxContext,
    ) {
        request.approvals.insert(type_name::get<W>())
    }

    public fun add_rule_config<Rule: drop, Config: store>(
        _rule: Rule,
        self: &mut PlatFormPolicy,
        _cap: &PlatformCap,
        config: Config,
        _ctx: &mut TxContext,
    ) {
        df::add(&mut self.id, key<Rule>(), config)
    }

    public fun rule_config<Rule: drop, Config: store>(_rule: Rule, self: &PlatFormPolicy): &Config {
        assert!(has_rule_config_with_type<Rule, Config>(self), ENoConfig);
        df::borrow(&self.id, key<Rule>())
    }

    public fun rule_config_mut<Rule: drop, Config: store>(
        _rule: Rule,
        self: &mut PlatFormPolicy,
        _cap: &PlatformCap,
    ): &mut Config {
        assert!(has_rule_config_with_type<Rule, Config>(self), ENoConfig);
        df::borrow_mut(&mut self.id, key<Rule>())
    }

    public fun remove_rule_config<Rule, Config: store>(
        self: &mut PlatFormPolicy,
        _cap: &PlatformCap,
        _ctx: &mut TxContext,
    ): Config {
        assert!(has_rule_config_with_type<Rule, Config>(self), ENoConfig);
        df::remove(&mut self.id, key<Rule>())
    }

    /// Check if a config for a `Rule` is set in the `TokenPolicy` without
    /// checking the type of the `Config`.
    public fun has_rule_config<Rule>(self: &PlatFormPolicy): bool {
        df::exists_<RuleKey<Rule>>(&self.id, key<Rule>())
    }

    /// Check if a `Config` for a `Rule` is set in the `TokenPolicy` and that
    /// it matches the type provided.
    public fun has_rule_config_with_type<Rule, Config: store>(self: &PlatFormPolicy): bool {
        df::exists_with_type<RuleKey<Rule>, Config>(&self.id, key<Rule>())
    }

    // === Protected: Setting Rules ===

    public fun allow_default_actipn(
        platform_policy: &mut PlatFormPolicy,
        _cap: &PlatformCap,
        action: String,
        _ctx: &mut TxContext,
    ) {
        platform_policy.default_rules.insert(action, vec_set::empty());
    }

    public fun allow_action<T>(
        platform_policy: &mut PlatFormPolicy,
        _cap: &PlatformCap,
        action: String,
        _ctx: &mut TxContext,
    ) {
        let policy_rules = platform_policy.policy_rules_of_mut<T>();
        policy_rules.insert(action, vec_set::empty());
    }

    public fun disallow_default_actipn(
        platform_policy: &mut PlatFormPolicy,
        _cap: &PlatformCap,
        action: String,
        _ctx: &mut TxContext,
    ) {
        platform_policy.default_rules.remove(&action);
    }

    public fun disallow_action<T>(
        platform_policy: &mut PlatFormPolicy,
        _cap: &PlatformCap,
        action: String,
        _ctx: &mut TxContext,
    ) {
        let policy_rules = platform_policy.policy_rules_of_mut<T>();
        policy_rules.remove(&action);
    }

    public fun add_default_rule_for_action<Rule: drop>(
        platform_policy: &mut PlatFormPolicy,
        _cap: &PlatformCap,
        action: String,
    ) {
        if (!platform_policy.default_rules.contains(&action))
            platform_policy.default_rules.insert(action, vec_set::empty());

        platform_policy.default_rules.get_mut(&action).insert(type_name::get<Rule>())
    }

    public fun add_rule_for_action<T, Rule: drop>(
        platform_policy: &mut PlatFormPolicy,
        _cap: &PlatformCap,
        action: String,
    ) {
        let policy_rules = platform_policy.policy_rules_of_mut<T>();
        if (!policy_rules.contains(&action)) policy_rules.insert(action, vec_set::empty());

        policy_rules.get_mut(&action).insert(type_name::get<Rule>())
    }

    public fun remove_default_rule_for_action<Rule: drop>(
        platform_policy: &mut PlatFormPolicy,
        _cap: &PlatformCap,
        action: String,
    ) {
        platform_policy.default_rules.get_mut(&action).remove(&type_name::get<Rule>())
    }

    public fun remove_rule_for_action<T, Rule: drop>(
        platform_policy: &mut PlatFormPolicy,
        _cap: &PlatformCap,
        action: String,
    ) {
        platform_policy.policy_rules_of_mut<T>().get_mut(&action).insert(type_name::get<Rule>())
    }

    // === Protected: Treasury Management ===

    /// Mint a `Token` with a given `amount` using the `TreasuryCap`.
    public fun mint<T>(cap: &mut TreasuryCap<T>, amount: u64, ctx: &mut TxContext): Token<T> {
        let balance = cap.supply_mut().increase_supply(amount);
        Token { id: object::new(ctx), balance }
    }

    /// Burn a `Token` using the `TreasuryCap`.
    public fun burn<T>(cap: &mut TreasuryCap<T>, token: Token<T>) {
        let Token { id, balance } = token;
        cap.supply_mut().decrease_supply(balance);
        id.delete();
    }

    // === View Functions ===

    public fun value<T>(t: &Token<T>): u64 {
        t.balance.value()
    }

    // === Action Request Fields ==

    /// The Action in the `ActionRequest`.
    public fun action<T>(self: &ActionRequest<T>): String { self.name }

    /// Amount of the `ActionRequest`.
    public fun amount<T>(self: &ActionRequest<T>): u64 { self.amount }

    /// Sender of the `ActionRequest`.
    public fun sender<T>(self: &ActionRequest<T>): address { self.sender }

    /// Recipient of the `ActionRequest`.
    public fun recipient<T>(self: &ActionRequest<T>): Option<address> {
        self.recipient
    }

    /// Approvals of the `ActionRequest`.
    public fun approvals<T>(self: &ActionRequest<T>): VecSet<TypeName> {
        self.approvals
    }

    /// Burned balance of the `ActionRequest`.
    public fun spent<T>(self: &ActionRequest<T>): Option<u64> {
        if (self.spent_balance.is_some()) {
            option::some(self.spent_balance.borrow().value())
        } else {
            option::none()
        }
    }

    // === Package Functions ===

    // === Private Functions ===
    /// Create a new `RuleKey` for a `Rule`. The `is_protected` field is kept
    /// for potential future use, if Rules were to have a freely modifiable
    /// storage as addition / replacement for the `Config` system.
    ///
    /// The goal of `is_protected` is to potentially allow Rules store a mutable
    /// version of their configuration and mutate state on user action.
    fun key<Rule>(): RuleKey<Rule> { RuleKey { is_protected: true } }

    // === Test Functions ===
}

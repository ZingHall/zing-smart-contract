module zusdc::zusdc {
    public struct ZUSDC has drop {}

    #[allow(lint(share_owned))]
    fun init(otw: ZUSDC, ctx: &mut TxContext) {
        let (cap, metadata) = sui::coin::create_currency(
            otw,
            6,
            b"ZUSDC",
            b"Zing version USDC",
            b"Zing USDC is the yield bearing token to collect the rewards from different strategies created by Zing Protocol",
            option::some(
                sui::url::new_unsafe_from_bytes(
                    b"https://i.postimg.cc/yYckWz3N/zusd.png",
                ),
            ),
            ctx,
        );
        sui::transfer::public_transfer(cap, ctx.sender());
        sui::transfer::public_transfer(metadata, ctx.sender());
    }
}

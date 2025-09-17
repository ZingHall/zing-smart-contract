#[test_only]
module zing::zing_test_utils {
    use sui::{bcs, hash};
    use zing::reclaim::{ClaimInfo, SignedClaim};

    public fun generate_test_nonce(user: address, identifier: vector<u8>): vector<u8> {
        let mut nonce = vector::empty<u8>();

        // Add some randomness (simulated)
        let random_data = x"e179712a22851afef6096c5b84efe5223b0d6af6dfba19e221cea9ffbacde52a";
        vector::append(&mut nonce, random_data);

        // Add user address
        let user_bytes = bcs::to_bytes(&user);
        vector::append(&mut nonce, user_bytes);

        // Add identifier
        vector::append(&mut nonce, identifier);

        nonce
    }

    public fun compute_test_commitment_hash(
        claim_info: &ClaimInfo,
        signed_claim: &SignedClaim,
        nonce: &vector<u8>,
    ): vector<u8> {
        // Serialize claim_info
        let claim_info_bytes = bcs::to_bytes(claim_info);
        // Serialize signed_claim
        let signed_claim_bytes = bcs::to_bytes(signed_claim);
        std::debug::print(&hash::keccak256(&signed_claim_bytes));

        // Combine all data
        let mut combined_data = vector::empty<u8>();
        vector::append(&mut combined_data, claim_info_bytes);
        vector::append(&mut combined_data, signed_claim_bytes);
        vector::append(&mut combined_data, *nonce);

        // std::debug::print(&combined_data);

        hash::keccak256(&combined_data)
    }
}

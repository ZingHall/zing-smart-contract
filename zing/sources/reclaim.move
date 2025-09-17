module zing::reclaim {
    use std::ascii::{Self, String};
    use sui::{
        bcs,
        clock::Clock,
        hash,
        object_table::{Self, ObjectTable},
        table::{Self, Table},
        vec_map
    };
    use zing::ecdsa;

    // === Errors ===
    const E_DUPLICATE_COMMITMENT: u64 = 101;
    const E_UNAUTHORIZED_REVEALER: u64 = 102;
    const E_REVEAL_TOO_LATE: u64 = 103;
    const E_INVALID_NONCE: u64 = 104;
    const E_INVALID_COMMITMENT: u64 = 105;
    const E_NOT_EXPIRED_COMMITMENT: u64 = 106;

    // === Constants ===
    const ONE_MIINUTE_MILLISECOND: u64 = { 60 * 1000 };

    // === Structs ===

    public struct AdminCap has key, store {
        id: UID,
    }

    public struct ReclaimManager has key, store {
        id: UID,
        witnesses: vector<vector<u8>>,
        // num of witnesses required to create claim
        witnesses_num_threshold: u8,
        commitments: ObjectTable<ID, ProofCommitment>, // Track all commitments
        identifier_to_commitment: Table<vector<u8>, ID>, // Prevent duplicate commits for same identifier
        max_reveal_window: u64,
    }

    public struct ClaimInfo has copy, drop, store {
        provider: String,
        parameters: String,
        context: String,
    }

    public fun new_claim_info(provider: String, parameters: String, context: String): ClaimInfo {
        ClaimInfo {
            provider,
            parameters,
            context,
        }
    }

    public fun provider(claim_info: &ClaimInfo): String {
        claim_info.provider
    }

    public fun parameters(claim_info: &ClaimInfo): String {
        claim_info.parameters
    }

    public fun context(claim_info: &ClaimInfo): String {
        claim_info.context
    }

    public struct ClaimData has copy, drop, store {
        identifier: String,
        owner: String,
        epoch: String,
        timestamp_s: String,
    }

    public fun identifier(claim_data: &ClaimData): String {
        claim_data.identifier
    }

    public fun owner(claim_data: &ClaimData): String {
        claim_data.owner
    }

    public fun epoch(claim_data: &ClaimData): String {
        claim_data.epoch
    }

    public fun timestamp_s(claim_data: &ClaimData): String {
        claim_data.timestamp_s
    }

    public fun new_claim_data(
        identifier: String,
        owner: String,
        epoch: String,
        timestamp_s: String,
    ): ClaimData {
        ClaimData {
            identifier,
            owner,
            epoch,
            timestamp_s,
        }
    }

    public struct SignedClaim has copy, drop, store {
        claim: ClaimData,
        signatures: vector<vector<u8>>,
    }

    public fun claim_data(signed_claim: &SignedClaim): &ClaimData {
        &signed_claim.claim
    }

    public fun signatures(signed_claim: &SignedClaim): vector<vector<u8>> {
        signed_claim.signatures
    }

    public fun new_signed_claim(claim: ClaimData, signatures: vector<vector<u8>>): SignedClaim {
        SignedClaim {
            claim,
            signatures,
        }
    }

    public struct Proof has key {
        id: UID,
        claimed_at: u64,
        claim_info: ClaimInfo,
        signed_claim: SignedClaim,
    }

    public fun proof_claimed_at(proof: &Proof): u64 {
        proof.claimed_at
    }

    public fun proof_claim_info(proof: &Proof): &ClaimInfo {
        &proof.claim_info
    }

    public fun proof_signed_claim(proof: &Proof): &SignedClaim {
        &proof.signed_claim
    }

    public struct ProofCommitment has key, store {
        id: UID,
        commitment_hash: vector<u8>,
        committer: address,
        commit_timestamp: u64,
        identifier_hash: vector<u8>, // Hash of claim identifier to prevent duplicate commits
    }

    // === Events ===

    // === Method Aliases ===

    // === Admin Functions ===
    fun init(ctx: &mut TxContext) {
        let admin_cap = AdminCap { id: object::new(ctx) };

        transfer::public_transfer(admin_cap, ctx.sender());
    }

    #[test_only]
    public fun init_for_testing(ctx: &mut TxContext) {
        init(ctx);
    }

    public fun new(_cap: &AdminCap, ctx: &mut TxContext): ReclaimManager {
        ReclaimManager {
            id: object::new(ctx),
            witnesses: vector[],
            witnesses_num_threshold: 1,
            commitments: object_table::new(ctx),
            identifier_to_commitment: table::new(ctx),
            max_reveal_window: ONE_MIINUTE_MILLISECOND/2,
        }
    }

    #[allow(lint(share_owned))]
    public fun default(_cap: &AdminCap, ctx: &mut TxContext) {
        let manager = new(_cap, ctx);

        transfer::public_share_object(manager);
    }

    public fun update_witnesses(
        self: &mut ReclaimManager,
        _cap: &AdminCap,
        witnesses: vector<vector<u8>>,
    ) {
        self.witnesses = witnesses;
    }

    public fun update_witnesses_num_threshold(
        self: &mut ReclaimManager,
        _cap: &AdminCap,
        witnesses_num_threshold: u8,
    ) {
        self.witnesses_num_threshold = witnesses_num_threshold;
    }

    public fun cleanup_expired_commitments(
        self: &mut ReclaimManager,
        _cap: &AdminCap,
        commitment_ids: vector<ID>,
        clock: &Clock,
    ) {
        commitment_ids.do!(|commitment_id| {
            let commitment = self.commitments.remove(commitment_id);
            let ProofCommitment {
                id,
                commitment_hash: _,
                committer: _,
                commit_timestamp,
                identifier_hash,
            } = commitment;
            object::delete(id);

            let time_since_commit = clock.timestamp_ms() - commit_timestamp;
            assert!(time_since_commit > self.max_reveal_window, E_NOT_EXPIRED_COMMITMENT);

            self.identifier_to_commitment.remove(identifier_hash);
        });
    }

    // === Public Functions ===
    // COMMIT PHASE: Submit commitment hash
    entry fun commit_proof(
        self: &mut ReclaimManager,
        commitment_hash: vector<u8>,
        identifier_hash: vector<u8>, // Hash of claim identifier to prevent duplicates
        clock: &Clock,
        ctx: &mut TxContext,
    ): ID {
        let current_time = clock.timestamp_ms();
        let committer = ctx.sender();

        // Check for duplicate commitment on same identifier
        assert!(!self.identifier_to_commitment.contains(identifier_hash), E_DUPLICATE_COMMITMENT);

        let id = object::new(ctx);
        let commitment_id = id.to_inner();

        let commitment = ProofCommitment {
            id,
            commitment_hash,
            committer,
            commit_timestamp: current_time,
            identifier_hash,
        };

        // TODO: record timestamp to allow admin delete expired commitment
        // Store commitment
        self.commitments.add(commitment_id, commitment);
        self.identifier_to_commitment.add(identifier_hash, commitment_id);

        commitment_id
    }

    entry fun reveal_and_verify_proof(
        self: &mut ReclaimManager,
        commitment_id: ID,
        // claim_info
        provider: String,
        parameters: String,
        context: String,
        // claim data
        identifier: String,
        owner: String,
        epoch: String,
        timestamp_s: String,
        signatures: vector<vector<u8>>,
        // nonce
        nonce: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): vector<vector<u8>> {
        let claim_info = new_claim_info(provider, parameters, context);
        let claim_data = new_claim_data(identifier, owner, epoch, timestamp_s);
        let signed_claim = new_signed_claim(claim_data, signatures);
        // First, read commitment data without mutable borrow
        let commitment = self.commitments.remove(commitment_id);
        let ProofCommitment {
            id,
            commitment_hash,
            committer,
            commit_timestamp,
            identifier_hash,
        } = commitment;
        object::delete(id);

        // Verify revealer is the original committer
        assert!(committer == ctx.sender(), E_UNAUTHORIZED_REVEALER);

        // Check timing constraints
        let time_since_commit = clock.timestamp_ms() - commit_timestamp;
        assert!(time_since_commit <= self.max_reveal_window, E_REVEAL_TOO_LATE);

        // Verify nonce and reconstruct commitment hash
        let reconstructed_hash = compute_commitment_hash(&claim_info, &signed_claim, &nonce);
        assert!(reconstructed_hash == commitment_hash, E_INVALID_NONCE);

        // Verify identifier hash matches
        let claim_identifier_hash = hash::keccak256(
            ascii::as_bytes(&signed_claim.claim.identifier),
        );
        assert!(claim_identifier_hash == identifier_hash, E_INVALID_COMMITMENT);

        // Perform original proof verification
        let signers = self.verify_proof_internal(&claim_info, &signed_claim, ctx);

        // Create and share the proof object
        let proof = Proof {
            id: object::new(ctx),
            claimed_at: clock.timestamp_ms(),
            claim_info,
            signed_claim,
        };
        transfer::transfer(proof, committer);

        // Clean up - remove from identifier mapping (allow new commits for this identifier)
        let _ = self.identifier_to_commitment.remove(identifier_hash);

        signers
    }

    public fun bytes_to_hex(bytes: &vector<u8>): String {
        let mut hex_string = vector::empty<u8>();
        bytes.do_ref!(|byte_ref| {
            let byte = *byte_ref;
            let high_nibble = (byte >> 4) & 0x0F;
            let low_nibble = byte & 0x0F;
            hex_string.push_back(byte_to_hex_char(high_nibble));
            hex_string.push_back(byte_to_hex_char(low_nibble));
        });
        ascii::string(hex_string)
    }

    // === View Functions ===

    // === Package Functions ===

    // === Private Functions ===
    // Helper function to compute commitment hash
    fun compute_commitment_hash(
        claim_info: &ClaimInfo,
        signed_claim: &SignedClaim,
        nonce: &vector<u8>,
    ): vector<u8> {
        // Serialize claim_info
        let claim_info_bytes = bcs::to_bytes(claim_info);

        // Serialize signed_claim
        let signed_claim_bytes = bcs::to_bytes(signed_claim);

        // Combine all data: claim_info + signed_claim + nonce
        let mut combined_data = vector::empty<u8>();
        vector::append(&mut combined_data, claim_info_bytes);
        vector::append(&mut combined_data, signed_claim_bytes);
        vector::append(&mut combined_data, *nonce);

        hash::keccak256(&combined_data)
    }

    // Internal proof verification (your existing logic)
    fun verify_proof_internal(
        manager: &ReclaimManager,
        claim_info: &ClaimInfo,
        signed_claim: &SignedClaim,
        ctx: &mut TxContext,
    ): vector<vector<u8>> {
        // Your existing verification logic
        assert!(vector::length(&signed_claim.signatures) > 0, 0);

        let identifier = ascii::substring(
            &signed_claim.claim.identifier,
            2,
            signed_claim.claim.identifier.length(),
        );
        let hashed = hash_claim_info(claim_info);
        assert!(hashed == identifier, 1);

        let expected_witnesses = fetch_witnesses_for_claim(manager, signed_claim.claim.identifier);
        let signed_witnesses = recover_signers_of_signed_claim(*signed_claim);

        assert!(!contains_duplicates(&signed_witnesses, ctx), 0);
        assert!(vector::length(&signed_witnesses) == vector::length(&expected_witnesses), 0);

        // Verify witnesses
        let mut expected_witnesses_map = vec_map::empty<vector<u8>, bool>();
        expected_witnesses.do!(|witnesses| {
            expected_witnesses_map.insert(witnesses, true);
        });

        signed_witnesses.do!(|signed_witness| {
            expected_witnesses_map.remove(&signed_witness);
        });

        expected_witnesses_map.destroy_empty();

        signed_witnesses
    }

    // Helper functions
    fun fetch_witnesses_for_claim(self: &ReclaimManager, identifier: String): vector<vector<u8>> {
        let complete_hash = hash::keccak256(ascii::as_bytes(&identifier));

        let mut witnesses_left_list = self.witnesses;
        let mut selected_witnesses = vector[];
        let minimum_witnesses = self.witnesses_num_threshold;

        let mut witnesses_left = witnesses_left_list.length();

        let mut byte_offset = 0;
        let mut i = 0;
        let complete_hash_len = complete_hash.length();
        while (i < minimum_witnesses) {
            // Extract four bytes at byte_offset from complete_hash
            let mut random_seed = 0;
            let mut j = 0;
            while (j < 4) {
                let byte_index = (byte_offset + j) % complete_hash_len;
                let byte_value = *&complete_hash[byte_index] as u64;
                random_seed = (byte_value << ((8 * j as u8)));
                j = j + 1;
            };

            let witness_index = random_seed % witnesses_left;
            let witness = *vector::borrow(&witnesses_left_list, witness_index);

            // Swap the last element with the one to be removed and then remove the last element
            let last_index = witnesses_left - 1;
            if (witness_index != last_index) {
                vector::swap(&mut witnesses_left_list, witness_index, last_index);
            };
            let _ = vector::pop_back(&mut witnesses_left_list);

            vector::push_back(&mut selected_witnesses, witness);

            byte_offset = (byte_offset + 4) % complete_hash_len;
            witnesses_left = witnesses_left - 1;
            i = i + 1;
        };

        selected_witnesses
    }

    fun recover_signers_of_signed_claim(signed_claim: SignedClaim): vector<vector<u8>> {
        let mut expected = vector<vector<u8>>[];
        let endl = b"\n".to_ascii_string();
        let mut message = b"".to_ascii_string();

        let mut complete_claim_data_padding = signed_claim.claim.timestamp_s;
        complete_claim_data_padding.append(endl);
        complete_claim_data_padding.append(signed_claim.claim.epoch);

        message.append(signed_claim.claim.identifier);
        message.append(endl);
        message.append(signed_claim.claim.owner);
        message.append(endl);
        message.append(complete_claim_data_padding);

        let mut eth_msg = b"\x19Ethereum Signed Message:\n".to_ascii_string();

        eth_msg.append(b"122".to_ascii_string());
        eth_msg.append(message);
        let msg = ascii::as_bytes(&eth_msg);

        let mut i = 0;
        while (i < vector::length(&signed_claim.signatures)) {
            let signature = signed_claim.signatures[i];
            let addr = ecdsa::ecrecover_to_eth_address(signature, *msg);
            vector::push_back(&mut expected, addr);
            i = i + 1
        };

        expected
    }

    // Helper function to check for duplicates in a vector
    fun contains_duplicates(vec: &vector<vector<u8>>, ctx: &mut TxContext): bool {
        let mut seen = table::new<vector<u8>, bool>(ctx);
        let mut i = 0;
        let mut has_duplicate = false;

        while (i < vec.length()) {
            let item = &vec[i];
            if (seen.contains(*item)) {
                has_duplicate = true;
                break
            };
            table::add(&mut seen, *item, true);
            i = i + 1;
        };

        let mut j = 0;
        while (j < vector::length(vec)) {
            let entry = vector::borrow(vec, j);
            if (table::contains(&seen, *entry)) {
                table::remove(&mut seen, *entry);
            };
            j = j + 1;
        };

        table::destroy_empty(seen);
        has_duplicate
    }

    fun hash_claim_info(claim_info: &ClaimInfo): String {
        let mut claim_info_data = claim_info.provider;
        claim_info_data.append(b"\n".to_ascii_string());
        claim_info_data.append(claim_info.parameters);
        claim_info_data.append(b"\n".to_ascii_string());
        claim_info_data.append(claim_info.context);

        let hash_bytes = hash::keccak256(ascii::as_bytes(&claim_info_data));
        bytes_to_hex(&hash_bytes)
    }

    fun byte_to_hex_char(byte: u8): u8 {
        if (byte < 10) {
            byte + 48 // '0' is 48 in ASCII
        } else {
            byte + 87 // 'a' is 97 in ASCII, 97 - 10 = 87
        }
    }
    // === Test Functions ===
}

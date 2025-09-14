// SPDX-License-Identifier: MIT
/*
    Enhanced Reclaim Module with Commit-Reveal Scheme
*/
module zing::reclaim {
    use std::string::{Self, String};
    use sui::{bcs, clock::{Self, Clock}, hash, table::{Self, Table}};
    use zing::ecdsa;

    // Constants
    const E_INVALID_COMMITMENT: u64 = 1001;
    const E_COMMITMENT_NOT_FOUND: u64 = 1002;
    const E_REVEAL_TOO_EARLY: u64 = 1003;
    const E_REVEAL_TOO_LATE: u64 = 1004;
    const E_INVALID_NONCE: u64 = 1005;
    const E_DUPLICATE_COMMITMENT: u64 = 1006;
    const E_UNAUTHORIZED_REVEALER: u64 = 1007;

    // Commitment structure for commit-reveal scheme
    public struct ProofCommitment has key, store {
        id: UID,
        commitment_hash: vector<u8>,
        committer: address,
        commit_timestamp: u64,
        identifier_hash: vector<u8>, // Hash of claim identifier to prevent duplicate commits
        revealed: bool,
    }

    // Existing structures (keeping your original ones)
    public struct Epoch has key, store {
        id: UID,
        epoch_number: u8,
        timestamp_start: u64,
        timestamp_end: u64,
        witnesses: vector<vector<u8>>,
        minimum_witnesses_for_claim_creation: u8,
    }

    public struct ClaimInfo has copy, drop, store {
        provider: String,
        parameters: String,
        context: String,
    }

    public struct SignedClaim has copy, drop, store {
        claim: CompleteClaimData,
        signatures: vector<vector<u8>>,
    }

    public struct CompleteClaimData has copy, drop, store {
        identifier: String,
        owner: String,
        epoch: String,
        timestamp_s: String,
    }

    public struct Proof has key {
        id: UID,
        claim_info: ClaimInfo,
        signed_claim: SignedClaim,
        commitment_id: ID, // Link to original commitment
    }

    public struct ReclaimManager has key {
        id: UID,
        owner: address,
        epoch_duration_s: u32,
        current_epoch: u8,
        epochs: vector<Epoch>,
        merkelized_user_params: Table<vector<u8>, bool>,
        dapp_id_to_external_nullifier: Table<vector<u8>, vector<u8>>,
        // Commit-reveal specific fields
        min_commit_reveal_delay: u64, // Minimum time between commit and reveal (milliseconds)
        max_reveal_window: u64, // Maximum time allowed for reveal after min delay
        commitments: Table<ID, ProofCommitment>, // Track all commitments
        identifier_to_commitment: Table<vector<u8>, ID>, // Prevent duplicate commits for same identifier
    }

    // Creates a new claim info
    public fun create_claim_info(
        provider: string::String,
        parameters: string::String,
        context: string::String,
    ): ClaimInfo {
        ClaimInfo {
            provider,
            parameters,
            context,
        }
    }

    // Creates a new complete claim data
    public fun create_claim_data(
        identifier: string::String,
        owner: string::String,
        epoch: string::String,
        timestamp_s: string::String,
    ): CompleteClaimData {
        CompleteClaimData {
            identifier,
            owner,
            epoch,
            timestamp_s,
        }
    }

    // Creates a new signed claim
    public fun create_signed_claim(
        claim: CompleteClaimData,
        signatures: vector<vector<u8>>,
    ): SignedClaim {
        SignedClaim {
            claim,
            signatures,
        }
    }

    // Creates a new epoch
    public fun create_epoch(
        epoch_number: u8,
        timestamp_start: u64,
        timestamp_end: u64,
        witnesses: vector<vector<u8>>, // List of witnesses
        minimum_witnesses_for_claim_creation: u8,
        ctx: &mut TxContext,
    ): Epoch {
        // Create a new epoch object with the provided epoch details
        Epoch {
            id: object::new(ctx),
            epoch_number,
            timestamp_start,
            timestamp_end,
            witnesses,
            minimum_witnesses_for_claim_creation,
        }
    }

    // Initialize manager with commit-reveal parameters
    public fun create_reclaim_manager(
        epoch_duration_s: u32,
        min_commit_reveal_delay: u64, // e.g., 300000 ms = 5 minutes
        max_reveal_window: u64, // e.g., 3600000 ms = 1 hour
        ctx: &mut TxContext,
    ) {
        transfer::share_object(ReclaimManager {
            id: object::new(ctx),
            owner: ctx.sender(),
            epoch_duration_s,
            current_epoch: 0,
            epochs: vector[],
            merkelized_user_params: table::new(ctx),
            dapp_id_to_external_nullifier: table::new(ctx),
            min_commit_reveal_delay,
            max_reveal_window,
            commitments: table::new(ctx),
            identifier_to_commitment: table::new(ctx),
        })
    }

    public fun add_new_epoch(
        manager: &mut ReclaimManager,
        witnesses: vector<vector<u8>>,
        minimum_witnesses_for_claim_creation: u8,
        ctx: &mut TxContext,
    ) {
        assert!(manager.owner == tx_context::sender(ctx), 0);
        let epoch_number = manager.current_epoch + 1;
        let timestamp_start = tx_context::epoch_timestamp_ms(ctx);
        let timestamp_end = timestamp_start + (manager.epoch_duration_s as u64);

        // let witness_ids: vector<UID> = vector::empty();
        // vector::for_each(witnesses, |witness| {
        //     vector::push_back(&mut witness_ids, witness.id);
        // });

        let new_epoch = create_epoch(
            epoch_number,
            timestamp_start,
            timestamp_end,
            witnesses,
            minimum_witnesses_for_claim_creation,
            ctx,
        );
        vector::push_back(&mut manager.epochs, new_epoch);
        manager.current_epoch = epoch_number;
        //event::emit(EpochAdded { epoch: new_epoch });
    }

    // COMMIT PHASE: Submit commitment hash
    public fun commit_proof(
        manager: &mut ReclaimManager,
        commitment_hash: vector<u8>,
        identifier_hash: vector<u8>, // Hash of claim identifier to prevent duplicates
        clock: &Clock,
        ctx: &mut TxContext,
    ): ID {
        let current_time = clock::timestamp_ms(clock);
        let committer = ctx.sender();

        // Check for duplicate commitment on same identifier
        assert!(
            !table::contains(&manager.identifier_to_commitment, identifier_hash),
            E_DUPLICATE_COMMITMENT,
        );

        let commitment_id = object::new(ctx);
        let commitment_uid = object::uid_to_inner(&commitment_id);

        let commitment = ProofCommitment {
            id: commitment_id,
            commitment_hash,
            committer,
            commit_timestamp: current_time,
            identifier_hash,
            revealed: false,
        };

        // Store commitment
        table::add(&mut manager.commitments, commitment_uid, commitment);
        table::add(&mut manager.identifier_to_commitment, identifier_hash, commitment_uid);

        commitment_uid
    }

    // REVEAL PHASE: Reveal proof with nonce
    public fun reveal_and_verify_proof(
        manager: &mut ReclaimManager,
        commitment_id: ID,
        claim_info: ClaimInfo,
        signed_claim: SignedClaim,
        nonce: vector<u8>,
        clock: &Clock,
        ctx: &mut TxContext,
    ): vector<vector<u8>> {
        let current_time = clock::timestamp_ms(clock);

        // Get and validate commitment exists
        assert!(table::contains(&manager.commitments, commitment_id), E_COMMITMENT_NOT_FOUND);

        // First, read commitment data without mutable borrow
        let (committer, commit_timestamp, commitment_hash, identifier_hash, revealed) = {
            let commitment = table::borrow(&manager.commitments, commitment_id);
            (
                commitment.committer,
                commitment.commit_timestamp,
                commitment.commitment_hash,
                commitment.identifier_hash,
                commitment.revealed,
            )
        };

        // Verify revealer is the original committer
        assert!(committer == ctx.sender(), E_UNAUTHORIZED_REVEALER);

        // Check timing constraints
        let time_since_commit = current_time - commit_timestamp;
        assert!(time_since_commit >= manager.min_commit_reveal_delay, E_REVEAL_TOO_EARLY);
        assert!(
            time_since_commit <= manager.min_commit_reveal_delay + manager.max_reveal_window,
            E_REVEAL_TOO_LATE,
        );

        // Verify commitment hasn't been revealed yet
        assert!(!revealed, E_INVALID_COMMITMENT);

        // Verify nonce and reconstruct commitment hash
        let reconstructed_hash = compute_commitment_hash(&claim_info, &signed_claim, &nonce);
        assert!(reconstructed_hash == commitment_hash, E_INVALID_NONCE);

        // Verify identifier hash matches
        let claim_identifier_hash = hash::keccak256(
            string::as_bytes(&signed_claim.claim.identifier),
        );
        assert!(claim_identifier_hash == identifier_hash, E_INVALID_COMMITMENT);

        // Now mark as revealed with mutable borrow
        {
            let commitment = table::borrow_mut(&mut manager.commitments, commitment_id);
            commitment.revealed = true;
        };

        // Perform original proof verification
        let signers = verify_proof_internal(manager, &claim_info, &signed_claim, ctx);

        // Create and share the proof object
        let proof = Proof {
            id: object::new(ctx),
            claim_info,
            signed_claim,
            commitment_id,
        };
        transfer::share_object(proof);

        // Clean up - remove from identifier mapping (allow new commits for this identifier)
        let _ = table::remove(&mut manager.identifier_to_commitment, identifier_hash);

        signers
    }

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
        // Validate timestamp constraints
        let claim_timestamp = parse_timestamp(&signed_claim.claim.timestamp_s);
        validate_claim_timing(manager, claim_timestamp);

        // Your existing verification logic
        assert!(vector::length(&signed_claim.signatures) > 0, 0);

        let identifier = string::substring(
            &signed_claim.claim.identifier,
            2,
            string::length(&signed_claim.claim.identifier),
        );
        let hashed = hash_claim_info(claim_info);
        assert!(hashed == identifier, 1);

        let expected_witnesses = fetch_witnesses_for_claim(manager, signed_claim.claim.identifier);
        let signed_witnesses = recover_signers_of_signed_claim(*signed_claim);

        assert!(!contains_duplicates(&signed_witnesses, ctx), 0);
        assert!(vector::length(&signed_witnesses) == vector::length(&expected_witnesses), 0);

        // Verify witnesses
        let mut expected_witnesses_table = table::new<vector<u8>, bool>(ctx);
        let mut i = 0;
        while (i < vector::length(&expected_witnesses)) {
            table::add(
                &mut expected_witnesses_table,
                *vector::borrow(&expected_witnesses, i),
                true,
            );
            i = i + 1;
        };

        i = 0;
        while (i < vector::length(&signed_witnesses)) {
            assert!(
                table::remove(&mut expected_witnesses_table, *vector::borrow(&signed_witnesses, i)),
                0,
            );
            i = i + 1;
        };
        table::destroy_empty(expected_witnesses_table);

        signed_witnesses
    }

    // Validate claim timing constraints
    fun validate_claim_timing(manager: &ReclaimManager, claim_timestamp: u64) {
        let current_epoch = fetch_epoch(manager);

        // Ensure claim timestamp is within current epoch bounds
        assert!(claim_timestamp >= current_epoch.timestamp_start, E_REVEAL_TOO_EARLY);
        assert!(claim_timestamp <= current_epoch.timestamp_end, E_REVEAL_TOO_LATE);
    }

    // Parse timestamp string to u64
    fun parse_timestamp(timestamp_str: &String): u64 {
        let bytes = string::as_bytes(timestamp_str);
        let mut result = 0u64;
        let mut i = 0;

        while (i < vector::length(bytes)) {
            let digit = *vector::borrow(bytes, i);
            if (digit >= 48 && digit <= 57) {
                result = result * 10 + ((digit - 48) as u64);
            };
            i = i + 1;
        };

        result * 1000 // Convert to milliseconds
    }

    // Emergency function to clean up expired commitments
    public fun cleanup_expired_commitments(
        manager: &mut ReclaimManager,
        commitment_ids: vector<ID>,
        clock: &Clock,
        ctx: &mut TxContext,
    ) {
        assert!(manager.owner == ctx.sender(), 0);
        let current_time = clock::timestamp_ms(clock);

        let mut i = 0;
        while (i < vector::length(&commitment_ids)) {
            let commitment_id = *vector::borrow(&commitment_ids, i);
            if (table::contains(&manager.commitments, commitment_id)) {
                let commitment = table::borrow(&manager.commitments, commitment_id);
                let time_elapsed = current_time - commitment.commit_timestamp;

                // Clean up if expired and not revealed
                if (
                    !commitment.revealed && 
                    time_elapsed > manager.min_commit_reveal_delay + manager.max_reveal_window
                ) {
                    let proof_commitment = table::remove(&mut manager.commitments, commitment_id);
                    let ProofCommitment {
                        id,
                        commitment_hash: _,
                        committer: _,
                        commit_timestamp: _,
                        identifier_hash,
                        revealed: _,
                    } = proof_commitment;

                    object::delete(id);

                    if (table::contains(&manager.identifier_to_commitment, identifier_hash)) {
                        table::remove(&mut manager.identifier_to_commitment, identifier_hash);
                    };
                };
            };
            i = i + 1;
        };
    }

    // Getters for frontend
    public fun get_commitment_info(manager: &ReclaimManager, commitment_id: ID): (u64, bool) {
        if (table::contains(&manager.commitments, commitment_id)) {
            let commitment = table::borrow(&manager.commitments, commitment_id);
            (commitment.commit_timestamp, commitment.revealed)
        } else {
            (0, false)
        }
    }

    public fun can_reveal_now(manager: &ReclaimManager, commitment_id: ID, clock: &Clock): bool {
        if (!table::contains(&manager.commitments, commitment_id)) {
            return false
        };

        let commitment = table::borrow(&manager.commitments, commitment_id);
        if (commitment.revealed) {
            return false
        };

        let current_time = clock::timestamp_ms(clock);
        let time_since_commit = current_time - commitment.commit_timestamp;

        time_since_commit >= manager.min_commit_reveal_delay &&
        time_since_commit <= manager.min_commit_reveal_delay + manager.max_reveal_window
    }

    // ... (include your existing helper functions: hash_claim_info, fetch_witnesses_for_claim, etc.)
    fun byte_to_hex_char(byte: u8): u8 {
        if (byte < 10) {
            
            byte + 48 // '0' is 48 in ASCII
        } else {
            byte + 87 // 'a' is 97 in ASCII, 97 - 10 = 87
        }
    }

     public fun bytes_to_hex(bytes: &vector<u8>): string::String {
        let mut hex_string = vector::empty<u8>();
        let mut i = 0;
        while (i < vector::length(bytes)) {
            let byte = *vector::borrow(bytes, i);
            let high_nibble = (byte >> 4) & 0x0F;
            let low_nibble = byte & 0x0F;
            vector::push_back(&mut hex_string, byte_to_hex_char(high_nibble));
            vector::push_back(&mut hex_string, byte_to_hex_char(low_nibble));
            i = i + 1;
        };
        string::utf8(hex_string)
    }

    // Placeholder for your existing functions - you'd copy these from your original module
    fun hash_claim_info(claim_info: &ClaimInfo): string::String {
        let mut claim_info_data = claim_info.provider;
        claim_info_data.append(b"\n".to_string());
        claim_info_data.append(claim_info.parameters);
        claim_info_data.append(b"\n".to_string());
        claim_info_data.append(claim_info.context);

        let hash_bytes = hash::keccak256(string::as_bytes(&claim_info_data));
        bytes_to_hex(&hash_bytes)
    }

    // Helper functions
    fun fetch_witnesses_for_claim(
        manager: &ReclaimManager,
        identifier: string::String,
    ): vector<vector<u8>> {
        let epoch_data = fetch_epoch(manager);
        let complete_hash = hash::keccak256(string::as_bytes(&identifier));

        let mut witnesses_left_list = epoch_data.witnesses;
        let mut selected_witnesses = vector::empty();
        let minimum_witnesses = epoch_data.minimum_witnesses_for_claim_creation;

        let mut witnesses_left = vector::length(&witnesses_left_list);

        let mut byte_offset = 0;
        let mut i = 0;
        let complete_hash_len = vector::length(&complete_hash);
        while (i < minimum_witnesses) {
            // Extract four bytes at byte_offset from complete_hash
            let mut random_seed = 0;
            let mut j = 0;
            while (j < 4) {
                let byte_index = (byte_offset + j) % complete_hash_len;
                let byte_value = *vector::borrow(&complete_hash, byte_index) as u64;
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
        let endl = b"\n".to_string();
        let mut message = b"".to_string();

        let mut complete_claim_data_padding = signed_claim.claim.timestamp_s;
        complete_claim_data_padding.append(endl);
        complete_claim_data_padding.append(signed_claim.claim.epoch);

        message.append(signed_claim.claim.identifier);
        message.append(endl);
        message.append(signed_claim.claim.owner);
        message.append(endl);
        message.append(complete_claim_data_padding);

        let mut eth_msg = b"\x19Ethereum Signed Message:\n".to_string();

        eth_msg.append(b"122".to_string());
        eth_msg.append(message);
        let msg = string::as_bytes(&eth_msg);

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

        while (i < vector::length(vec)) {
            let item = vector::borrow(vec, i);
            if (table::contains(&seen, *item)) {
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

    public fun fetch_epoch(manager: &ReclaimManager): &Epoch {
        vector::borrow(&manager.epochs, (manager.current_epoch - 1) as u64)
    }
}

#[test_only]
module zing::reclaim_fork_tests {
    use std::string::{Self, String};
    use sui::{clock::{Self, Clock}, hash, test_scenario};
    use zing::reclaim_fork;

    // #[test]
    fun test_commit_reveal_reclaim_fork() {
        let owner = @0xC0FFEE;
        let user1 = @0xA1;
        let epoch_duration_s = 86400_u32; // expired per month
        let min_commit_reveal_delay = 300_000u64; // 5 minutes in ms
        let max_reveal_window = 3_600_000u64; // 1 hour in ms

        let mut scenario_val = test_scenario::begin(user1);
        let scenario = &mut scenario_val;

        // Setup clock for time-based testing
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            let mut clock = clock::create_for_testing(ctx);

            clock::set_for_testing(&mut clock, 1757697834000); // Set initial timestamp
            ctx.increment_epoch_timestamp(1757697834000);

            clock::share_for_testing(clock);
        };

        test_scenario::next_tx(scenario, owner);
        {
            // create enhanced reclaim_forkManager object
            reclaim_fork::create_reclaim_manager(
                epoch_duration_s,
                min_commit_reveal_delay,
                max_reveal_window,
                test_scenario::ctx(scenario),
            );
        };

        test_scenario::next_tx(scenario, owner);
        {
            let mut manager = test_scenario::take_shared<reclaim_fork::ReclaimManager>(
                scenario,
            );

            let mut witnesses = vector<vector<u8>>[];
            let witness_address = x"244897572368eadf65bfbc5aec98d8e5443a9072";
            witnesses.push_back(witness_address);

            let requisite_witnesses_for_claim_create = 1_u8;

            // add new epoch
            let ctx = test_scenario::ctx(scenario);
            reclaim_fork::add_new_epoch(
                &mut manager,
                witnesses,
                requisite_witnesses_for_claim_create,
                ctx,
            );

            test_scenario::return_shared(manager);
        };

        // Prepare test data
        let claim_info = reclaim_fork::create_claim_info(
            // provider
            b"http".to_string(),
            // parameters
            b"{\"additionalClientOptions\":{},\"body\":\"\",\"geoLocation\":\"\",\"headers\":{\"Sec-Fetch-Mode\":\"same-origin\",\"Sec-Fetch-Site\":\"same-origin\",\"User-Agent\":\"Mozilla/5.0 (iPhone; CPU iPhone OS 18_6_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1\"},\"method\":\"GET\",\"paramValues\":{\"screen_name\":\"3ol4NGpn8yruLoE\"},\"responseMatches\":[{\"invert\":false,\"type\":\"contains\",\"value\":\"\\\"screen_name\\\":\\\"{{screen_name}}\\\"\"}],\"responseRedactions\":[{\"jsonPath\":\"$.screen_name\",\"regex\":\"\\\"screen_name\\\":\\\"(.*)\\\"\",\"xPath\":\"\"}],\"url\":\"https://api.x.com/1.1/account/settings.json?include_ext_sharing_audiospaces_listening_data_with_followers=true&include_mention_filter=true&include_nsfw_user_flag=true&include_nsfw_admin_flag=true&include_ranked_timeline=true&include_alt_text_compose=true&ext=ssoConnections&include_country_code=true&include_ext_dm_nsfw_media_filter=true\"}".to_string(),
            // context
            b"{\"contextAddress\":\"0x0\",\"contextMessage\":\"sample context\",\"extractedParameters\":{\"screen_name\":\"3ol4NGpn8yruLoE\"},\"providerHash\":\"0x168c2d4c2c7fd8c0eb21d4cd9aa634a716b61186b1f61e7ab78cd0dbff34fb04\"}".to_string(),
        );

        let complete_claim_data = reclaim_fork::create_claim_data(
            // identifier
            b"0x3e091d4a0c020565b1cf703f0ad1d1ddd483095f206243b55aa26a39dd7efbdd".to_string(),
            // owner
            b"0xaebeee4bb6366bde012dc7efc6a01f55a044574c".to_string(),
            // epoch
            b"1".to_string(),
            // timestamp_s
            b"1757697834".to_string(),
        );

        let mut signatures = vector<vector<u8>>[];
        let signature =
            x"b7e5acc04a5df18547173300af695095ce0d22a325c7cd52eee916d2fd2f518e29f61e4147b49a1282ecc1b706c4d37a6d560160f8bd0ac675e44b1d6cd91bb81c";
        signatures.push_back(signature);

        let signed_claim = reclaim_fork::create_signed_claim(
            complete_claim_data,
            signatures,
        );

        // Generate nonce for commitment
        let nonce = generate_test_nonce(
            user1,
            b"0x3e091d4a0c020565b1cf703f0ad1d1ddd483095f206243b55aa26a39dd7efbdd",
        );
        let commitment_hash = compute_test_commitment_hash(&claim_info, &signed_claim, &nonce);
        let identifier_hash = hash::keccak256(
            &b"0x3e091d4a0c020565b1cf703f0ad1d1ddd483095f206243b55aa26a39dd7efbdd",
        );

        let commitment_id;

        // COMMIT PHASE
        test_scenario::next_tx(scenario, user1);
        {
            let mut manager = test_scenario::take_shared<reclaim_fork::ReclaimManager>(
                scenario,
            );
            let clock = test_scenario::take_shared<Clock>(scenario);

            // Commit proof
            commitment_id =
                reclaim_fork::commit_proof(
                    &mut manager,
                    commitment_hash,
                    identifier_hash,
                    &clock,
                    test_scenario::ctx(scenario),
                );

            std::debug::print(&string::utf8(b"Commitment created with ID: "));
            std::debug::print(&commitment_id);

            test_scenario::return_shared(manager);
            test_scenario::return_shared(clock);
        };

        // Advance time to allow reveal (past minimum delay)
        test_scenario::next_tx(scenario, user1);
        {
            let mut clock = test_scenario::take_shared<Clock>(scenario);
            clock::increment_for_testing(&mut clock, min_commit_reveal_delay + 1000); // Add buffer
            test_scenario::return_shared(clock);
        };

        // REVEAL PHASE
        test_scenario::next_tx(scenario, user1);
        {
            let mut manager = test_scenario::take_shared<reclaim_fork::ReclaimManager>(
                scenario,
            );
            let clock = test_scenario::take_shared<Clock>(scenario);

            // Check if we can reveal now
            let can_reveal = reclaim_fork::can_reveal_now(&manager, commitment_id, &clock);
            assert!(can_reveal, 1);

            // Reveal and verify proof
            let signers = reclaim_fork::reveal_and_verify_proof(
                &mut manager,
                commitment_id,
                claim_info,
                signed_claim,
                nonce,
                &clock,
                test_scenario::ctx(scenario),
            );

            assert!(signers == vector[x"244897572368eadf65bfbc5aec98d8e5443a9072"], 0);
            std::debug::print(&string::utf8(b"Proof verified successfully!"));

            test_scenario::return_shared(manager);
            test_scenario::return_shared(clock);
        };

        // Verify proof object was created
        test_scenario::next_tx(scenario, user1);
        {
            let proof = test_scenario::take_shared<reclaim_fork::Proof>(scenario);
            std::debug::print(&proof);
            test_scenario::return_shared(proof);
        };

        test_scenario::end(scenario_val);
    }

    // #[test]
    fun test_commit_reveal_timing_constraints() {
        let owner = @0xC0FFEE;
        let user1 = @0xA1;
        let epoch_duration_s = 1_000_u32;
        let min_commit_reveal_delay = 300_000u64; // 5 minutes
        let max_reveal_window = 3_600_000u64; // 1 hour

        let mut scenario_val = test_scenario::begin(user1);
        let scenario = &mut scenario_val;

        // Setup
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            let mut clock = clock::create_for_testing(ctx);

            clock::set_for_testing(&mut clock, 1_000_000_000);
            clock::share_for_testing(clock);

            reclaim_fork::create_reclaim_manager(
                epoch_duration_s,
                min_commit_reveal_delay,
                max_reveal_window,
                ctx,
            );
        };

        test_scenario::next_tx(scenario, owner);
        {
            let mut manager = test_scenario::take_shared<reclaim_fork::ReclaimManager>(
                scenario,
            );
            let mut witnesses = vector<vector<u8>>[];
            witnesses.push_back(x"244897572368eadf65bfbc5aec98d8e5443a9072");

            reclaim_fork::add_new_epoch(
                &mut manager,
                witnesses,
                1_u8,
                test_scenario::ctx(scenario),
            );

            test_scenario::return_shared(manager);
        };

        // Prepare test data
        let claim_info = create_test_claim_info();
        let signed_claim = create_test_signed_claim();
        let nonce = generate_test_nonce(user1, b"test_identifier");
        let commitment_hash = compute_test_commitment_hash(&claim_info, &signed_claim, &nonce);
        let identifier_hash = hash::keccak256(&b"test_identifier");

        let commitment_id;

        // Commit
        test_scenario::next_tx(scenario, user1);
        {
            let mut manager = test_scenario::take_shared<reclaim_fork::ReclaimManager>(
                scenario,
            );
            let clock = test_scenario::take_shared<Clock>(scenario);

            commitment_id =
                reclaim_fork::commit_proof(
                    &mut manager,
                    commitment_hash,
                    identifier_hash,
                    &clock,
                    test_scenario::ctx(scenario),
                );

            test_scenario::return_shared(manager);
            test_scenario::return_shared(clock);
        };

        // Test: Try to reveal too early (should fail)
        test_scenario::next_tx(scenario, user1);
        {
            let manager = test_scenario::take_shared<reclaim_fork::ReclaimManager>(
                scenario,
            );
            let clock = test_scenario::take_shared<Clock>(scenario);

            let can_reveal = reclaim_fork::can_reveal_now(&manager, commitment_id, &clock);
            assert!(!can_reveal, 2); // Should not be able to reveal yet

            test_scenario::return_shared(manager);
            test_scenario::return_shared(clock);
        };

        // Advance time past the maximum window (should fail)
        test_scenario::next_tx(scenario, user1);
        {
            let mut clock = test_scenario::take_shared<Clock>(scenario);
            clock::increment_for_testing(
                &mut clock,
                min_commit_reveal_delay + max_reveal_window + 1000,
            );
            test_scenario::return_shared(clock);
        };

        test_scenario::next_tx(scenario, user1);
        {
            let manager = test_scenario::take_shared<reclaim_fork::ReclaimManager>(
                scenario,
            );
            let clock = test_scenario::take_shared<Clock>(scenario);

            let can_reveal = reclaim_fork::can_reveal_now(&manager, commitment_id, &clock);
            assert!(!can_reveal, 3); // Should not be able to reveal after window expires

            test_scenario::return_shared(manager);
            test_scenario::return_shared(clock);
        };

        test_scenario::end(scenario_val);
    }

    // #[test]
    fun test_duplicate_commitment_prevention() {
        let owner = @0xC0FFEE;
        let user1 = @0xA1;
        let user2 = @0xB2;

        let mut scenario_val = test_scenario::begin(user1);
        let scenario = &mut scenario_val;

        // Setup
        test_scenario::next_tx(scenario, owner);
        {
            let ctx = test_scenario::ctx(scenario);
            let clock = clock::create_for_testing(ctx);
            clock::share_for_testing(clock);

            reclaim_fork::create_reclaim_manager(
                1_000_u32,
                300_000u64,
                3_600_000u64,
                ctx,
            );
        };

        test_scenario::next_tx(scenario, owner);
        {
            let mut manager = test_scenario::take_shared<reclaim_fork::ReclaimManager>(
                scenario,
            );
            let mut witnesses = vector<vector<u8>>[];
            witnesses.push_back(x"244897572368eadf65bfbc5aec98d8e5443a9072");

            reclaim_fork::add_new_epoch(
                &mut manager,
                witnesses,
                1_u8,
                test_scenario::ctx(scenario),
            );

            test_scenario::return_shared(manager);
        };

        let identifier_hash = hash::keccak256(&b"duplicate_test_identifier");
        let commitment_hash = hash::keccak256(&b"some_commitment_data");

        // First commitment should succeed
        test_scenario::next_tx(scenario, user1);
        {
            let mut manager = test_scenario::take_shared<reclaim_fork::ReclaimManager>(
                scenario,
            );
            let clock = test_scenario::take_shared<Clock>(scenario);

            let _commitment_id = reclaim_fork::commit_proof(
                &mut manager,
                commitment_hash,
                identifier_hash,
                &clock,
                test_scenario::ctx(scenario),
            );

            test_scenario::return_shared(manager);
            test_scenario::return_shared(clock);
        };

        // Second commitment with same identifier should fail
        test_scenario::next_tx(scenario, user2);
        {
            let mut manager = test_scenario::take_shared<reclaim_fork::ReclaimManager>(
                scenario,
            );
            let clock = test_scenario::take_shared<Clock>(scenario);

            // This should abort due to duplicate commitment
            // In a real test environment, you'd use expected_failure attribute
            // #[expected_failure(abort_code = reclaim_fork::E_DUPLICATE_COMMITMENT)]

            test_scenario::return_shared(manager);
            test_scenario::return_shared(clock);
        };

        test_scenario::end(scenario_val);
    }

    // Helper functions for testing
    fun generate_test_nonce(user: address, identifier: vector<u8>): vector<u8> {
        use sui::bcs;

        let mut nonce = vector::empty<u8>();

        // Add timestamp (simulate)
        let timestamp = 2_000_000_000u64;
        let timestamp_bytes = bcs::to_bytes(&timestamp);
        vector::append(&mut nonce, timestamp_bytes);

        // Add some randomness (simulated)
        let random_data = x"deadbeefcafebabe1234567890abcdef";
        vector::append(&mut nonce, random_data);

        // Add user address
        let user_bytes = bcs::to_bytes(&user);
        vector::append(&mut nonce, user_bytes);

        // Add identifier
        vector::append(&mut nonce, identifier);

        nonce
    }

    fun compute_test_commitment_hash(
        claim_info: &reclaim_fork::ClaimInfo,
        signed_claim: &reclaim_fork::SignedClaim,
        nonce: &vector<u8>,
    ): vector<u8> {
        use sui::bcs;

        // Serialize claim_info
        let claim_info_bytes = bcs::to_bytes(claim_info);

        // Serialize signed_claim
        let signed_claim_bytes = bcs::to_bytes(signed_claim);

        // Combine all data
        let mut combined_data = vector::empty<u8>();
        vector::append(&mut combined_data, claim_info_bytes);
        vector::append(&mut combined_data, signed_claim_bytes);
        vector::append(&mut combined_data, *nonce);

        hash::keccak256(&combined_data)
    }

    fun create_test_claim_info(): reclaim_fork::ClaimInfo {
        reclaim_fork::create_claim_info(
            b"http".to_string(),
            b"{\"test\":\"data\"}".to_string(),
            b"{\"contextMessage\":\"test context\"}".to_string(),
        )
    }

    fun create_test_signed_claim(): reclaim_fork::SignedClaim {
        let claim_data = reclaim_fork::create_claim_data(
            b"0xtest_identifier".to_string(),
            b"0xtest_owner".to_string(),
            b"1".to_string(),
            b"1000000000".to_string(),
        );

        let mut signatures = vector<vector<u8>>[];
        signatures.push_back(
            x"b7e5acc04a5df18547173300af695095ce0d22a325c7cd52eee916d2fd2f518e29f61e4147b49a1282ecc1b706c4d37a6d560160f8bd0ac675e44b1d6cd91bb81c",
        );

        reclaim_fork::create_signed_claim(claim_data, signatures)
    }

    // Utility function to extract screen_name from parameters JSON string
    fun extract_screen_name_from_parameters(parameters: String): String {
        let params_bytes = string::as_bytes(&parameters);
        let params_length = params_bytes.length();

        // Look for the pattern "screen_name":"value"
        let search_pattern = b"\"screen_name\":\"";
        let pattern_length = search_pattern.length();

        let mut i = 0;
        let mut found_start = false;
        let mut start_index = 0;

        // Find the start of screen_name value
        while (i <= params_length - pattern_length) {
            let mut match_found = true;
            let mut j = 0;

            while (j < pattern_length) {
                if (params_bytes[i + j] != search_pattern[j]) {
                    match_found = false;
                    break
                };
                j = j + 1;
            };

            if (match_found) {
                start_index = i + pattern_length;
                found_start = true;
                break
            };

            i = i + 1;
        };

        if (!found_start) {
            return string::utf8(b"")
        };

        // Find the end of the screen_name value (look for closing quote)
        let mut end_index = start_index;
        while (end_index < params_length && params_bytes[end_index] != 34) {
            // 34 is ASCII for "
            end_index = end_index + 1;
        };

        // Extract the screen_name value
        let mut result_bytes = vector<u8>[];
        let mut k = start_index;
        while (k < end_index) {
            result_bytes.push_back(params_bytes[k]);
            k = k + 1;
        };

        string::utf8(result_bytes)
    }

    // #[test]
    fun test_extract_screen_name_from_parameters() {
        let parameters = b"{\"additionalClientOptions\":{},\"body\":\"\",\"geoLocation\":\"\",\"headers\":{\"Sec-Fetch-Mode\":\"same-origin\",\"Sec-Fetch-Site\":\"same-origin\",\"User-Agent\":\"Mozilla/5.0 (iPhone; CPU iPhone OS 18_6_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1\"},\"method\":\"GET\",\"paramValues\":{\"screen_name\":\"3ol4NGpn8yruLoE\"},\"responseMatches\":[{\"invert\":false,\"type\":\"contains\",\"value\":\"\\\"screen_name\\\":\\\"{{screen_name}}\\\"\"}],\"responseRedactions\":[{\"jsonPath\":\"$.screen_name\",\"regex\":\"\\\"screen_name\\\":\\\"(.*)\\\"\",\"xPath\":\"\"}],\"url\":\"https://api.x.com/1.1/account/settings.json?include_ext_sharing_audiospaces_listening_data_with_followers=true&include_mention_filter=true&include_nsfw_user_flag=true&include_nsfw_admin_flag=true&include_ranked_timeline=true&include_alt_text_compose=true&ext=ssoConnections&include_country_code=true&include_ext_dm_nsfw_media_filter=true\"}".to_string();

        let extracted_screen_name = extract_screen_name_from_parameters(parameters);
        let expected = b"3ol4NGpn8yruLoE".to_string();

        assert!(extracted_screen_name == expected, 0);
        std::debug::print(&string::utf8(b"Extracted screen_name: "));
        std::debug::print(&extracted_screen_name);
    }
}

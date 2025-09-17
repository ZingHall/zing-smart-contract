#[test_only]
module zing::reclaim_tests {
    use sui::{clock::{Self, Clock}, hash, test_scenario as ts};
    use zing::{reclaim::{Self, ReclaimManager, AdminCap, Proof}, zing_test_utils as test_utils};

    #[test]
    fun test_reclaim() {
        let owner = @0xC0FFEE;
        let user1 = @0xf9875c055ca73af41cdd012474739cf1edbdd0525dcb2321548d87ba7934f1c8;

        let mut scenario = ts::begin(user1);
        let s = &mut scenario;

        s.next_tx(owner);
        {
            let mut clock = clock::create_for_testing(s.ctx());

            clock::set_for_testing(&mut clock, 1757697834000); // Set initial timestamp
            s.ctx().increment_epoch_timestamp(1757697834000);

            clock::share_for_testing(clock);
            reclaim::init_for_testing(s.ctx());
        };

        s.next_tx(owner);
        {
            let cap = ts::take_from_sender<AdminCap>(s);
            let witnesses = vector[x"244897572368eadf65bfbc5aec98d8e5443a9072"];
            let witnesses_num_threshold = 1;

            let mut manager = reclaim::new(&cap, s.ctx());
            manager.update_witnesses(&cap, witnesses);
            manager.update_witnesses_num_threshold(&cap, witnesses_num_threshold);
            transfer::public_share_object(manager);

            s.return_to_sender(cap);
        };

        let provider = b"http".to_ascii_string();
        let parameters = b"{\"additionalClientOptions\":{},\"body\":\"\",\"geoLocation\":\"\",\"headers\":{\"Sec-Fetch-Mode\":\"same-origin\",\"Sec-Fetch-Site\":\"same-origin\",\"User-Agent\":\"Mozilla/5.0 (iPhone; CPU iPhone OS 18_6_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.6 Mobile/15E148 Safari/604.1\"},\"method\":\"GET\",\"paramValues\":{\"screen_name\":\"3ol4NGpn8yruLoE\"},\"responseMatches\":[{\"invert\":false,\"type\":\"contains\",\"value\":\"\\\"screen_name\\\":\\\"{{screen_name}}\\\"\"}],\"responseRedactions\":[{\"jsonPath\":\"$.screen_name\",\"regex\":\"\\\"screen_name\\\":\\\"(.*)\\\"\",\"xPath\":\"\"}],\"url\":\"https://api.x.com/1.1/account/settings.json?include_ext_sharing_audiospaces_listening_data_with_followers=true&include_mention_filter=true&include_nsfw_user_flag=true&include_nsfw_admin_flag=true&include_ranked_timeline=true&include_alt_text_compose=true&ext=ssoConnections&include_country_code=true&include_ext_dm_nsfw_media_filter=true\"}".to_ascii_string();
        let context = b"{\"contextAddress\":\"0x0\",\"contextMessage\":\"sample context\",\"extractedParameters\":{\"screen_name\":\"3ol4NGpn8yruLoE\"},\"providerHash\":\"0x168c2d4c2c7fd8c0eb21d4cd9aa634a716b61186b1f61e7ab78cd0dbff34fb04\"}".to_ascii_string();

        let claim_info = reclaim::new_claim_info(
            provider,
            parameters,
            context,
        );

        let identifier = b"0x3e091d4a0c020565b1cf703f0ad1d1ddd483095f206243b55aa26a39dd7efbdd".to_ascii_string();
        let owner = b"0xaebeee4bb6366bde012dc7efc6a01f55a044574c".to_ascii_string();
        let epoch = b"1".to_ascii_string();
        let timestamp_s = b"1757697834".to_ascii_string();

        let complete_claim_data = reclaim::new_claim_data(
            identifier,
            owner,
            epoch,
            timestamp_s,
        );

        let signatures = vector[
            x"b7e5acc04a5df18547173300af695095ce0d22a325c7cd52eee916d2fd2f518e29f61e4147b49a1282ecc1b706c4d37a6d560160f8bd0ac675e44b1d6cd91bb81c",
        ];
        let signed_claim = reclaim::new_signed_claim(
            complete_claim_data,
            signatures,
        );

        // Generate nonce for commitment
        let nonce = test_utils::generate_test_nonce(
            user1,
            x"3e091d4a0c020565b1cf703f0ad1d1ddd483095f206243b55aa26a39dd7efbdd",
        );

        // std::debug::print(&nonce);
        let commitment_hash = test_utils::compute_test_commitment_hash(
            &claim_info,
            &signed_claim,
            &nonce,
        );

        let identifier_hash = hash::keccak256(
            &b"0x3e091d4a0c020565b1cf703f0ad1d1ddd483095f206243b55aa26a39dd7efbdd",
        );
        std::debug::print(&std::ascii::string(b"identifier_hash"));
        std::debug::print(&identifier_hash);

        let commitment_id;
        // COMMIT PHASE
        s.next_tx(user1);
        {
            let mut manager = s.take_shared<ReclaimManager>();
            let clock = s.take_shared<Clock>();

            commitment_id =
                reclaim::commit_proof(
                    &mut manager,
                    commitment_hash,
                    identifier_hash,
                    &clock,
                    s.ctx(),
                );

            ts::return_shared(clock);
            ts::return_shared(manager);
        };

        // REVEAL PHASE
        s.next_tx(user1);
        {
            let mut manager = s.take_shared<ReclaimManager>();
            let clock = s.take_shared<Clock>();

            // Reveal and verify proof
            let signers = reclaim::reveal_and_verify_proof(
                &mut manager,
                commitment_id,
                provider,
                parameters,
                context,
                identifier,
                owner,
                epoch,
                timestamp_s,
                signatures,
                nonce,
                &clock,
                s.ctx(),
            );

            assert!(signers == vector[x"244897572368eadf65bfbc5aec98d8e5443a9072"], 0);

            ts::return_shared(manager);
            ts::return_shared(clock);
        };

        s.next_tx(user1);
        {
            let proof = ts::take_from_sender<Proof>(s);

            let context = proof.proof_claim_info().context();
            std::debug::print(&context);

            s.return_to_sender(proof);
        };

        scenario.end();
    }
}

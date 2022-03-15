open Core
open Async
open Integration_test_lib

module Make (Inputs : Intf.Test.Inputs_intf) = struct
  open Inputs
  open Engine
  open Dsl

  type network = Network.t

  type node = Network.Node.t

  type dsl = Dsl.t

  let config =
    let open Test_config in
    let open Test_config.Block_producer in
    { default with
      requires_graphql = true
    ; block_producers =
        [ { balance = "8000000000"; timing = Untimed }
        ; { balance = "1000000000"; timing = Untimed }
        ; { balance = "1000000000"; timing = Untimed }
        ]
    ; num_snark_workers = 0
    }

  let run network t =
    let open Malleable_error.Let_syntax in
    let logger = Logger.create () in
    let block_producer_nodes = Network.block_producers network in
    let%bind () =
      Malleable_error.List.iter block_producer_nodes
        ~f:(Fn.compose (wait_for t) Wait_condition.node_to_initialize)
    in
    let node = List.hd_exn block_producer_nodes in
    let constraint_constants =
      Genesis_constants.Constraint_constants.compiled
    in
    let%bind fee_payer_pk = Util.pub_key_of_node node in
    let%bind fee_payer_sk = Util.priv_key_of_node node in
    let (keypair : Signature_lib.Keypair.t) =
      { public_key = fee_payer_pk |> Signature_lib.Public_key.decompress_exn
      ; private_key = fee_payer_sk
      }
    in
    let num_snapp_accounts = 3 in
    let snapp_keypairs =
      List.init num_snapp_accounts ~f:(fun _ -> Signature_lib.Keypair.create ())
    in
    let snapp_account_ids =
      List.map snapp_keypairs ~f:(fun snapp_keypair ->
          Mina_base.Account_id.create
            (snapp_keypair.public_key |> Signature_lib.Public_key.compress)
            Mina_base.Token_id.default)
    in
    let%bind parties_create_account =
      (* construct a Parties.t, similar to snapp_test_transaction create-snapp-account *)
      let open Mina_base in
      let fee = Currency.Fee.of_int 1_000_000 in
      let amount = Currency.Amount.of_int 10_000_000_000 in
      let nonce = Account.Nonce.zero in
      let memo =
        Signed_command_memo.create_from_string_exn "Snapp create account"
      in
      let (parties_spec : Transaction_snark.For_tests.Spec.t) =
        { sender = (keypair, nonce)
        ; fee
        ; receivers = []
        ; amount
        ; snapp_account_keypairs = snapp_keypairs
        ; memo
        ; new_snapp_account = true
        ; snapp_update = Party.Update.dummy
        ; current_auth = Permissions.Auth_required.Signature
        ; call_data = Snark_params.Tick.Field.zero
        ; events = []
        ; sequence_events = []
        }
      in
      return
      @@ Transaction_snark.For_tests.deploy_snapp ~constraint_constants
           parties_spec
    in
    let%bind.Deferred parties_update_permissions, permissions_updated =
      (* construct a Parties.t, similar to snapp_test_transaction update-permissions *)
      let open Mina_base in
      let fee = Currency.Fee.of_int 1_000_000 in
      let nonce = Account.Nonce.of_int 2 in
      let memo =
        Signed_command_memo.create_from_string_exn "Snapp update permissions"
      in
      let new_permissions : Permissions.t =
        { Permissions.user_default with
          edit_state = Permissions.Auth_required.Proof
        ; edit_sequence_state = Proof
        ; set_delegate = Proof
        ; set_verification_key = Proof
        ; set_permissions = Proof
        ; set_snapp_uri = Proof
        ; set_token_symbol = Proof
        ; set_voting_for = Proof
        }
      in
      let (parties_spec : Transaction_snark.For_tests.Spec.t) =
        { sender = (keypair, nonce)
        ; fee
        ; receivers = []
        ; amount = Currency.Amount.zero
        ; snapp_account_keypairs = snapp_keypairs
        ; memo
        ; new_snapp_account = false
        ; snapp_update =
            { Party.Update.dummy with permissions = Set new_permissions }
        ; current_auth =
            (* current set_permissions permission requires Signature *)
            Permissions.Auth_required.Signature
        ; call_data = Snark_params.Tick.Field.zero
        ; events = []
        ; sequence_events = []
        }
      in
      let%map.Deferred parties =
        Transaction_snark.For_tests.update_states ~constraint_constants
          parties_spec
      in
      (parties, new_permissions)
    in
    let%bind.Deferred snapp_update_all, parties_update_all =
      let open Mina_base in
      let fee = Currency.Fee.of_int 1_000_000 in
      let amount = Currency.Amount.zero in
      let nonce = Account.Nonce.of_int 3 in
      let memo =
        Signed_command_memo.create_from_string_exn "Snapp update all"
      in
      let app_state =
        let len = Snapp_state.Max_state_size.n |> Pickles_types.Nat.to_int in
        let fields =
          Quickcheck.random_value
            (Quickcheck.Generator.list_with_length len
               Snark_params.Tick.Field.gen)
        in
        List.map fields ~f:(fun field -> Snapp_basic.Set_or_keep.Set field)
        |> Snapp_state.V.of_list_exn
      in
      let new_delegate =
        Quickcheck.random_value Signature_lib.Public_key.Compressed.gen
      in
      let new_verification_key =
        let data = Pickles.Side_loaded.Verification_key.dummy in
        let hash = Snapp_account.digest_vk data in
        ({ data; hash } : _ With_hash.t)
      in
      let new_permissions =
        Quickcheck.random_value (Permissions.gen ~auth_tag:Proof)
      in
      let new_snapp_uri = "https://www.minaprotocol.com" in
      let new_token_symbol = "SHEKEL" in
      let new_voting_for = Quickcheck.random_value State_hash.gen in
      let snapp_update : Party.Update.t =
        { app_state
        ; delegate = Set new_delegate
        ; verification_key = Set new_verification_key
        ; permissions = Set new_permissions
        ; snapp_uri = Set new_snapp_uri
        ; token_symbol = Set new_token_symbol
        ; timing = (* timing can't be updated for an existing account *)
                   Keep
        ; voting_for = Set new_voting_for
        }
      in
      let (parties_spec : Transaction_snark.For_tests.Spec.t) =
        { sender = (keypair, nonce)
        ; fee
        ; receivers = []
        ; amount
        ; snapp_account_keypairs = snapp_keypairs
        ; memo
        ; new_snapp_account = false
        ; snapp_update
        ; current_auth = Permissions.Auth_required.Proof
        ; call_data = Snark_params.Tick.Field.zero
        ; events = []
        ; sequence_events = []
        }
      in
      let%map.Deferred parties_update_all =
        Transaction_snark.For_tests.update_states ~constraint_constants
          parties_spec
      in
      (snapp_update, parties_update_all)
    in
    let%bind ( parties_create_account_with_timing
             , timing_account_id
             , timing_update
             , timed_account_keypair ) =
      let open Mina_base in
      let fee = Currency.Fee.of_int 1_000_000 in
      let amount = Currency.Amount.of_int 10_000_000_000 in
      let nonce = Account.Nonce.of_int 4 in
      let memo =
        Signed_command_memo.create_from_string_exn
          "Snapp create account with timing"
      in
      let snapp_keypair = Signature_lib.Keypair.create () in
      let (parties_spec : Transaction_snark.For_tests.Spec.t) =
        { sender = (keypair, nonce)
        ; fee
        ; receivers = []
        ; amount
        ; snapp_account_keypairs = [ snapp_keypair ]
        ; memo
        ; new_snapp_account = true
        ; snapp_update =
            (let timing =
               Snapp_basic.Set_or_keep.Set
                 ( { initial_minimum_balance =
                       Currency.Balance.of_int 5_000_000_000
                   ; cliff_time = Mina_numbers.Global_slot.of_int 10000
                   ; cliff_amount = Currency.Amount.of_int 10_000
                   ; vesting_period = Mina_numbers.Global_slot.of_int 2
                   ; vesting_increment = Currency.Amount.of_int 1_000
                   }
                   : Party.Update.Timing_info.value )
             in
             { Party.Update.dummy with timing })
        ; current_auth = Permissions.Auth_required.Signature
        ; call_data = Snark_params.Tick.Field.zero
        ; events = []
        ; sequence_events = []
        }
      in
      let timing_account_id =
        Account_id.create
          (snapp_keypair.public_key |> Signature_lib.Public_key.compress)
          Token_id.default
      in
      return
        ( Transaction_snark.For_tests.deploy_snapp ~constraint_constants
            parties_spec
        , timing_account_id
        , parties_spec.snapp_update
        , snapp_keypair )
    in
    let%bind parties_transfer_from_timed_account =
      let open Mina_base in
      let fee = Currency.Fee.of_int 1_000_000 in
      let amount = Currency.Amount.of_int 1_500_000 in
      let nonce = Account.Nonce.zero in
      let memo =
        Signed_command_memo.create_from_string_exn
          "Snapp transfer, timed account"
      in
      let sender_keypair = timed_account_keypair in
      let receiver_key =
        keypair.public_key |> Signature_lib.Public_key.compress
      in
      let (parties_spec : Transaction_snark.For_tests.Spec.t) =
        { sender = (sender_keypair, nonce)
        ; fee
        ; receivers = [ (receiver_key, amount) ]
        ; amount
        ; snapp_account_keypairs = []
        ; memo
        ; new_snapp_account = false
        ; snapp_update = Party.Update.dummy
        ; current_auth = Permissions.Auth_required.Signature
        ; call_data = Snark_params.Tick.Field.zero
        ; events = []
        ; sequence_events = []
        }
      in
      return @@ Transaction_snark.For_tests.multiple_transfers parties_spec
    in
    let%bind parties_invalid_transfer_from_timed_account =
      let open Mina_base in
      let fee = Currency.Fee.of_int 1_000_000 in
      let amount = Currency.Amount.of_int 7_000_000_000 in
      let nonce = Account.Nonce.of_int 2 in
      let memo =
        Signed_command_memo.create_from_string_exn
          "Invalid transfer, timed account"
      in
      let sender_keypair = timed_account_keypair in
      let receiver_key =
        keypair.public_key |> Signature_lib.Public_key.compress
      in
      let (parties_spec : Transaction_snark.For_tests.Spec.t) =
        { sender = (sender_keypair, nonce)
        ; fee
        ; receivers = [ (receiver_key, amount) ]
        ; amount
        ; snapp_account_keypairs = []
        ; memo
        ; new_snapp_account = false
        ; snapp_update = Party.Update.dummy
        ; current_auth = Permissions.Auth_required.Signature
        ; call_data = Snark_params.Tick.Field.zero
        ; events = []
        ; sequence_events = []
        }
      in
      return @@ Transaction_snark.For_tests.multiple_transfers parties_spec
    in
    let%bind.Deferred parties_update_timing =
      let open Mina_base in
      let fee = Currency.Fee.of_int 1_000_000 in
      let amount = Currency.Amount.zero in
      let nonce = Account.Nonce.of_int 6 in
      let memo =
        Signed_command_memo.create_from_string_exn
          "Snapp, invalid update timing"
      in
      let snapp_update : Party.Update.t =
        { Party.Update.dummy with
          timing =
            Snapp_basic.Set_or_keep.Set
              { initial_minimum_balance = Currency.Balance.of_int 9_000_000_000
              ; cliff_time = Mina_numbers.Global_slot.of_int 4000
              ; cliff_amount = Currency.Amount.of_int 100_000
              ; vesting_period = Mina_numbers.Global_slot.of_int 8
              ; vesting_increment = Currency.Amount.of_int 2_000
              }
        }
      in
      let (parties_spec : Transaction_snark.For_tests.Spec.t) =
        { sender = (keypair, nonce)
        ; fee
        ; receivers = []
        ; amount
        ; snapp_account_keypairs = [ timed_account_keypair ]
        ; memo
        ; new_snapp_account = false
        ; snapp_update
        ; current_auth = Permissions.Auth_required.Proof
        ; call_data = Snark_params.Tick.Field.zero
        ; events = []
        ; sequence_events = []
        }
      in
      Transaction_snark.For_tests.update_states ~constraint_constants
        parties_spec
    in
    let parties_invalid_nonce =
      let p = parties_update_all in
      { p with
        fee_payer =
          { p.fee_payer with
            data =
              { p.fee_payer.data with
                predicate = Mina_base.Account.Nonce.of_int 42
              }
          }
      }
    in
    let parties_invalid_signature =
      let p = parties_update_all in
      { p with
        fee_payer =
          { data =
              { p.fee_payer.data with
                predicate = Mina_base.Account.Nonce.of_int 7
              }
          ; authorization = Mina_base.Signature.dummy
          }
      }
    in
    let with_timeout =
      let soft_slots = 3 in
      let soft_timeout = Network_time_span.Slots soft_slots in
      let hard_timeout = Network_time_span.Slots (soft_slots * 2) in
      Wait_condition.with_timeouts ~soft_timeout ~hard_timeout
    in
    let send_snapp ?(unlock = true) parties =
      [%log info] "Sending snapp"
        ~metadata:[ ("parties", Mina_base.Parties.to_yojson parties) ] ;
      match%bind.Deferred
        Network.Node.send_snapp ~unlock ~logger node ~parties
      with
      | Ok _snapp_id ->
          [%log info] "Snapps transaction sent" ;
          Malleable_error.return ()
      | Error err ->
          let err_str = Error.to_string_mach err in
          [%log error] "Error sending snapp"
            ~metadata:[ ("error", `String err_str) ] ;
          Malleable_error.soft_error_format ~value:() "Error sending snapp: %s"
            err_str
    in
    let send_invalid_snapp ?(unlock = true) parties substring =
      [%log info] "Sending snapp, expected to fail" ;
      match%bind.Deferred
        Network.Node.send_snapp ~unlock ~logger node ~parties
      with
      | Ok _snapp_id ->
          [%log error] "Snapps transaction succeeded, expected error \"%s\""
            substring ;
          Malleable_error.soft_error_format ~value:()
            "Snapps transaction succeeded, expected error \"%s\"" substring
      | Error err ->
          let err_str = Error.to_string_mach err in
          if String.is_substring ~substring err_str then (
            [%log info] "Snapps transaction failed as expected"
              ~metadata:[ ("error", `String err_str) ] ;
            Malleable_error.return () )
          else (
            [%log error]
              "Error sending snapp, for a reason other than the expected \"%s\""
              substring
              ~metadata:[ ("error", `String err_str) ] ;
            Malleable_error.soft_error_format ~value:()
              "Snapp failed: %s, but expected \"%s\"" err_str substring )
    in
    let get_account_permissions account_id =
      [%log info] "Getting permissions for account"
        ~metadata:[ ("account_id", Mina_base.Account_id.to_yojson account_id) ] ;
      match%bind.Deferred
        Network.Node.get_account_permissions ~logger node ~account_id
      with
      | Ok permissions ->
          [%log info] "Got account permissions" ;
          Malleable_error.return permissions
      | Error err ->
          let err_str = Error.to_string_mach err in
          [%log error] "Error getting account permissions"
            ~metadata:[ ("error", `String err_str) ] ;
          Malleable_error.hard_error (Error.of_string err_str)
    in
    let get_account_update account_id =
      [%log info] "Getting update for account"
        ~metadata:[ ("account_id", Mina_base.Account_id.to_yojson account_id) ] ;
      match%bind.Deferred
        Network.Node.get_account_update ~logger node ~account_id
      with
      | Ok update ->
          [%log info] "Got account update" ;
          Malleable_error.return update
      | Error err ->
          let err_str = Error.to_string_mach err in
          [%log error] "Error getting account update"
            ~metadata:[ ("error", `String err_str) ] ;
          Malleable_error.hard_error (Error.of_string err_str)
    in
    let get_account_balance account_id =
      [%log info] "Getting balance for account"
        ~metadata:[ ("account_id", Mina_base.Account_id.to_yojson account_id) ] ;
      match%bind.Deferred
        Network.Node.get_balance_total ~logger node ~account_id
      with
      | Ok balance ->
          [%log info] "Got account balance" ;
          Malleable_error.return balance
      | Error err ->
          let err_str = Error.to_string_mach err in
          [%log error] "Error getting account balance"
            ~metadata:[ ("error", `String err_str) ] ;
          Malleable_error.hard_error (Error.of_string err_str)
    in
    let get_account_balance_locked account_id =
      [%log info] "Getting locked balance for account"
        ~metadata:[ ("account_id", Mina_base.Account_id.to_yojson account_id) ] ;
      match%bind.Deferred
        Network.Node.get_balance_locked ~logger node ~account_id
      with
      | Ok balance ->
          [%log info] "Got account balance" ;
          Malleable_error.return balance
      | Error err ->
          let err_str = Error.to_string_mach err in
          [%log error] "Error getting account balance"
            ~metadata:[ ("error", `String err_str) ] ;
          Malleable_error.hard_error (Error.of_string err_str)
    in
    let compatible req_item ledg_item ~equal =
      match (req_item, ledg_item) with
      | Mina_base.Snapp_basic.Set_or_keep.Keep, _ ->
          true
      | Set v1, Mina_base.Snapp_basic.Set_or_keep.Set v2 ->
          equal v1 v2
      | Set _, Keep ->
          false
    in
    let compatible_updates ~(ledger_update : Mina_base.Party.Update.t)
        ~(requested_update : Mina_base.Party.Update.t) : bool =
      (* the "update" in the ledger is derived from the account

         if the requested update has `Set` for a field, we
         should see `Set` for the same value in the ledger update

         if the requested update has `Keep` for a field, any
         value in the ledger update is acceptable

         for the app state, we apply this principle element-wise
      *)
      let app_states_compat =
        let fs_requested =
          Pickles_types.Vector.Vector_8.to_list requested_update.app_state
        in
        let fs_ledger =
          Pickles_types.Vector.Vector_8.to_list ledger_update.app_state
        in
        List.for_all2_exn fs_requested fs_ledger ~f:(fun req ledg ->
            compatible req ledg ~equal:Pickles.Backend.Tick.Field.equal)
      in
      let delegates_compat =
        compatible requested_update.delegate ledger_update.delegate
          ~equal:Signature_lib.Public_key.Compressed.equal
      in
      let verification_keys_compat =
        compatible requested_update.verification_key
          ledger_update.verification_key
          ~equal:
            [%equal:
              ( Pickles.Side_loaded.Verification_key.t
              , Pickles.Backend.Tick.Field.t )
              With_hash.t]
      in
      let permissions_compat =
        compatible requested_update.permissions ledger_update.permissions
          ~equal:Mina_base.Permissions.equal
      in
      let snapp_uris_compat =
        compatible requested_update.snapp_uri ledger_update.snapp_uri
          ~equal:String.equal
      in
      let token_symbols_compat =
        compatible requested_update.token_symbol ledger_update.token_symbol
          ~equal:String.equal
      in
      let timings_compat =
        compatible requested_update.timing ledger_update.timing
          ~equal:Mina_base.Party.Update.Timing_info.equal
      in
      let voting_fors_compat =
        compatible requested_update.voting_for ledger_update.voting_for
          ~equal:Mina_base.State_hash.equal
      in
      List.for_all
        [ app_states_compat
        ; delegates_compat
        ; verification_keys_compat
        ; permissions_compat
        ; snapp_uris_compat
        ; token_symbols_compat
        ; timings_compat
        ; voting_fors_compat
        ]
        ~f:Fn.id
    in
    let wait_for_snapp parties =
      let%map () =
        wait_for t @@ with_timeout
        @@ Wait_condition.snapp_to_be_included_in_frontier ~parties
      in
      [%log info] "Snapps transaction included in transition frontier"
    in
    let%bind () =
      section "Send a snapp to create snapp accounts"
        (send_snapp parties_create_account)
    in
    let%bind () =
      section
        "Wait for snapp to create accounts to be included in transition \
         frontier"
        (wait_for_snapp parties_create_account)
    in
    let%bind () =
      section "Send a snapp to update permissions"
        (send_snapp parties_update_permissions)
    in
    let%bind () =
      section
        "Wait for snapp to update permissions to be included in transition \
         frontier"
        (wait_for_snapp parties_update_permissions)
    in
    let%bind () =
      section "Verify that updated permissions are in ledger accounts"
        (Malleable_error.List.iter snapp_account_ids ~f:(fun account_id ->
             [%log info] "Verifying permissions for account"
               ~metadata:
                 [ ("account_id", Mina_base.Account_id.to_yojson account_id) ] ;
             let%bind ledger_permissions = get_account_permissions account_id in
             if
               Mina_base.Permissions.equal ledger_permissions
                 permissions_updated
             then (
               [%log info] "Ledger, updated permissions are equal" ;
               return () )
             else (
               [%log error] "Ledger, updated permissions differ"
                 ~metadata:
                   [ ( "ledger_permissions"
                     , Mina_base.Permissions.to_yojson ledger_permissions )
                   ; ( "updated_permissions"
                     , Mina_base.Permissions.to_yojson permissions_updated )
                   ] ;
               Malleable_error.hard_error
                 (Error.of_string
                    "Ledger permissions do not match update permissions") )))
    in
    let%bind () =
      section "Send a snapp to update all fields"
        (send_snapp parties_update_all)
    in
    let%bind () =
      section
        "Wait for snapp to update all fields to be included in transition \
         frontier"
        (wait_for_snapp parties_update_all)
    in
    let%bind () =
      section "Verify snapp updates in ledger"
        (Malleable_error.List.iter snapp_account_ids ~f:(fun account_id ->
             [%log info] "Verifying updates for account"
               ~metadata:
                 [ ("account_id", Mina_base.Account_id.to_yojson account_id) ] ;
             let%bind ledger_update = get_account_update account_id in
             if
               compatible_updates ~ledger_update
                 ~requested_update:snapp_update_all
             then (
               [%log info] "Ledger update and requested update are compatible" ;
               return () )
             else (
               [%log error]
                 "Ledger update and requested update are incompatible"
                 ~metadata:
                   [ ( "ledger_update"
                     , Mina_base.Party.Update.to_yojson ledger_update )
                   ; ( "requested_update"
                     , Mina_base.Party.Update.to_yojson snapp_update_all )
                   ] ;
               Malleable_error.hard_error
                 (Error.of_string
                    "Ledger update and requested update are incompatible") )))
    in
    let%bind () =
      section "Send a snapp to create a snapp account with timing"
        (send_snapp parties_create_account_with_timing)
    in
    let%bind () =
      section
        "Wait for snapp to create account with timing to be included in \
         transition frontier"
        (wait_for_snapp parties_create_account_with_timing)
    in
    let%bind () =
      section "Verify snapp timing in ledger"
        (let%bind ledger_update = get_account_update timing_account_id in
         if compatible_updates ~ledger_update ~requested_update:timing_update
         then (
           [%log info]
             "Ledger timing and requested timing update are compatible" ;
           return () )
         else (
           [%log error]
             "Ledger update and requested update are incompatible, possibly \
              because of the timing"
             ~metadata:
               [ ( "ledger_update"
                 , Mina_base.Party.Update.to_yojson ledger_update )
               ; ( "requested_update"
                 , Mina_base.Party.Update.to_yojson timing_update )
               ] ;

           Malleable_error.hard_error
             (Error.of_string
                "Ledger update and requested update with timing are \
                 incompatible") ))
    in
    let%bind before_balance = get_account_balance timing_account_id in
    let%bind () =
      section "Send a snapp with transfer from timed account that succeeds"
        (send_snapp ~unlock:false parties_transfer_from_timed_account)
    in
    let%bind () =
      section "Waiting for snapp with transfer from timed account that succeeds"
        (wait_for_snapp parties_transfer_from_timed_account)
    in
    let%bind after_balance = get_account_balance timing_account_id in
    let%bind () =
      section "Verifying balance change"
        ( match
            Currency.Amount.( - )
              (Currency.Balance.to_amount before_balance)
              (Currency.Balance.to_amount after_balance)
          with
        | None ->
            Malleable_error.hard_error
              (Error.of_string
                 "Unexpected underflow when taking balance difference")
        | Some diff ->
            let sender_party =
              List.hd_exn parties_transfer_from_timed_account.other_parties
            in
            let amount_to_send =
              Currency.Amount.Signed.magnitude
                (Mina_base.Party.balance_change sender_party)
            in
            let fee =
              Currency.Amount.of_fee
                (Mina_base.Parties.fee parties_transfer_from_timed_account)
            in
            let total_debited =
              Option.value_exn (Currency.Amount.( + ) amount_to_send fee)
            in
            if Currency.Amount.equal diff total_debited then (
              [%log info] "Debited expected amount from timed account" ;
              return () )
            else
              Malleable_error.hard_error
                (Error.createf
                   "Expect to debit %s Mina from timed account (amount sent = \
                    %s, fee = %s), actually debited: %s Mina"
                   (Currency.Amount.to_string total_debited)
                   (Currency.Amount.to_string amount_to_send)
                   (Currency.Amount.to_string fee)
                   (Currency.Amount.to_string diff)) )
    in
    let%bind () =
      section
        "Send a snapp with transfer from timed account that fails due to min \
         balance"
        (let sender_party =
           List.hd_exn parties_invalid_transfer_from_timed_account.other_parties
         in
         let amount_to_send =
           Currency.Amount.Signed.magnitude
             (Mina_base.Party.balance_change sender_party)
         in
         let fee =
           Currency.Amount.of_fee
             (Mina_base.Parties.fee parties_invalid_transfer_from_timed_account)
         in
         let total_to_debit =
           Option.value_exn (Currency.Amount.( + ) amount_to_send fee)
         in
         (* we have enough in account, disregarding min balance *)
         let proposed_balance =
           match
             Currency.Amount.( - )
               (Currency.Balance.to_amount after_balance)
               total_to_debit
           with
           | Some bal ->
               bal
           | None ->
               failwith "Amount to debit more than timed account balance"
         in
         let%bind locked_balance =
           get_account_balance_locked timing_account_id
         in
         (* but proposed balance is less than min ("locked") balance *)
         assert (
           Currency.Amount.( < ) proposed_balance
             (Option.value_exn locked_balance |> Currency.Balance.to_amount) ) ;
         send_snapp ~unlock:false parties_invalid_transfer_from_timed_account)
    in
    let%bind () =
      section
        "Waiting for snapp with transfer from timed account that fails due to \
         min balance"
        (wait_for_snapp parties_invalid_transfer_from_timed_account)
    in
    (* TODO: use transaction status to see that the transaction failed
       as things are, we examine the balance of the sender to see that no funds were transferred
    *)
    let%bind () =
      section "Invalid transfer from timed account did not transfer funds"
        (let%bind after_invalid_balance =
           get_account_balance timing_account_id
         in
         let after_invalid_balance_as_amount =
           Currency.Balance.to_amount after_invalid_balance
         in
         let expected_after_invalid_balance_as_amount =
           Currency.Amount.( - )
             (Currency.Balance.to_amount after_balance)
             (Currency.Amount.of_fee
                (Mina_base.Parties.fee
                   parties_invalid_transfer_from_timed_account))
           |> Option.value_exn
         in
         (* the invalid transfer should result in a fee deduction only *)
         if
           Currency.Amount.equal after_invalid_balance_as_amount
             expected_after_invalid_balance_as_amount
         then return ()
         else
           Malleable_error.hard_error
             (Error.createf
                "The zkApp transaction should have failed because of the \
                 minimum balance constraint, got an actual balance of %s, \
                 expected a balance of %s"
                (Currency.Balance.to_string after_invalid_balance)
                (Currency.Amount.to_string
                   expected_after_invalid_balance_as_amount)))
    in
    let%bind () =
      section "Send a snapp with invalid timing update"
        (send_snapp parties_update_timing)
    in
    let%bind () =
      section "Wait for snapp with invalid timing update"
        (wait_for_snapp parties_update_timing)
    in
    let%bind () =
      section "Verify timing has not changed"
        (let%bind ledger_update = get_account_update timing_account_id in
         if
           compatible ledger_update.timing timing_update.timing
             ~equal:Mina_base.Party.Update.Timing_info.equal
         then (
           [%log info]
             "Ledger update contains original timing, updated timing was not \
              applied, as desired" ;
           return () )
         else (
           [%log error]
             "Ledger update contains new timing, which should not have been \
              applied" ;
           Malleable_error.hard_error
             (Error.of_string "Ledger update contains a timing update") ))
    in
    let%bind () =
      section "Send a snapp with an invalid nonce"
        (send_invalid_snapp parties_invalid_nonce "Invalid_nonce")
    in
    let%bind () =
      section "Send a snapp with an invalid signature"
        (send_invalid_snapp parties_invalid_signature "Invalid_signature")
    in
    return ()
end

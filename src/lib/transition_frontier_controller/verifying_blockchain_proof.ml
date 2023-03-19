open Mina_base
open Core_kernel
open Bit_catchup_state
open Context

(** Extract header from a transition in [Transition_state.Verifying_blockchain_proof] state *)
let to_header_exn = function
  | Transition_state.Verifying_blockchain_proof { header; _ } ->
      header
  | _ ->
      failwith "to_header_exn: unexpected state"

module F = struct
  type proceessing_result = Mina_block.Validation.initial_valid_with_header

  let ignore_gossip = function
    | Transition_state.Verifying_blockchain_proof ({ gossip_data = gd; _ } as r)
      ->
        Gossip.drop_gossip_data `Ignore gd ;
        let gossip_data = Gossip.No_validation_callback in
        Transition_state.Verifying_blockchain_proof { r with gossip_data }
    | st ->
        st

  let to_data = function
    | Transition_state.Verifying_blockchain_proof { substate; baton; _ } ->
        Some Verifying_generic.{ substate; baton }
    | _ ->
        None

  let update Verifying_generic.{ substate; baton } = function
    | Transition_state.Verifying_blockchain_proof r ->
        Transition_state.Verifying_blockchain_proof { r with substate; baton }
    | st ->
        st
end

include Verifying_generic.Make (F)

(** [upon_f] is a callback to be executed upon completion of
  blockchain proof verification (or a failure).
*)
let rec upon_f ~holder ~context ~actions ~transition_states res =
  let (module Context : CONTEXT) = context in
  let top_state_hash = !holder in
  match res with
  | Result.Error () ->
      (* Top state hash will be set to Failed only if it was Processing/Failed before this point *)
      let for_restart_opt =
        update_to_failed ~dsu:Context.processed_dsu ~transition_states
          ~state_hash:top_state_hash
          (Error.of_string "interrupted")
      in
      Option.iter for_restart_opt
        ~f:(start ~context ~actions ~transition_states)
  | Result.Ok (Result.Ok lst) ->
      List.iter lst ~f:(fun header ->
          let state_hash = state_hash_of_header_with_validation header in
          let for_restart_opt =
            update_to_processing_done ~transition_states ~state_hash
              ~dsu:Context.processed_dsu
              ~reuse_ctx:State_hash.(state_hash <> top_state_hash)
              header
          in
          Option.iter for_restart_opt ~f:(fun for_restart ->
              start ~context ~actions ~transition_states for_restart ;
              actions.Misc.mark_processed_and_promote [ state_hash ] ) )
  | Result.Ok (Result.Error (`Invalid_proof e)) ->
      (* We mark invalid only the top header because it is the only one for which
         we can be sure it's invalid. *)
      actions.Misc.mark_invalid
        ~error:(Error.tag e ~tag:"invalid blockchain proof")
        top_state_hash
  | Result.Ok (Result.Error (`Verifier_error e)) ->
      (* Top state hash will be set to Failed only if it was Processing before this point *)
      let for_restart_opt =
        update_to_failed ~dsu:Context.processed_dsu ~transition_states
          ~state_hash:top_state_hash e
      in
      Option.iter for_restart_opt
        ~f:(start ~context ~actions ~transition_states)

(** Launch blockchain proof verification and return the processing context
    for the deferred action launched.

    Pre-condition: function takes list of headers in child-first order.
*)
and launch_in_progress ~context:(module Context : CONTEXT) ~actions
    ~transition_states ~top_state_hash headers =
  let module I = Interruptible.Make () in
  let downto_ =
    List.hd_exn headers |> Mina_block.Validation.header
    |> Mina_block.Header.blockchain_length
  in
  let action = Context.verify_blockchain_proofs (module I) headers in
  let timeout = Time.add (Time.now ()) Context.ancestry_verification_timeout in
  interrupt_after_timeout ~timeout I.interrupt_ivar ;
  let holder = ref top_state_hash in
  Async_kernel.Deferred.upon (I.force action)
  @@ upon_f ~actions ~transition_states ~context:(module Context) ~holder ;
  Substate.In_progress
    { interrupt_ivar = I.interrupt_ivar; timeout; downto_; holder }

and start ~context ~actions ~transition_states states =
  Option.value ~default:()
  @@ let%map.Option top_state = List.last states in
     let headers = List.map ~f:to_header_exn states in
     let top_state_hash =
       (Transition_state.State_functions.transition_meta top_state).state_hash
     in
     let ctx =
       launch_in_progress ~context ~actions ~transition_states ~top_state_hash
         headers
     in
     match top_state with
     | Transition_state.Verifying_blockchain_proof ({ substate; _ } as r) ->
         Transition_states.update transition_states
           (Transition_state.Verifying_blockchain_proof
              { r with substate = { substate with status = Processing ctx } } )
     | _ ->
         ()

(** Promote a transition that is in [Received] state with
    [Processed] status to [Verifying_blockchain_proof] state.
*)
let promote_to ~context ~actions ~header ~transition_states ~substate:s
    ~gossip_data ~body_opt ~aux =
  let (module Context : CONTEXT) = context in
  let ctx =
    match header with
    | Gossip.Initial_valid h ->
        Substate.Done h
    | _ ->
        Substate.Dependent
  in
  let parent_hash =
    Gossip.header_with_hash_of_received_header header
    |> With_hash.data |> Mina_block.Header.protocol_state
    |> Mina_state.Protocol_state.previous_state_hash
  in
  ( if aux.Transition_state.received_via_gossip then
    let for_start =
      collect_dependent_and_pass_the_baton_by_hash ~transition_states
        ~dsu:Context.processed_dsu parent_hash
    in
    start ~context ~actions ~transition_states for_start ) ;
  Transition_state.Verifying_blockchain_proof
    { header = Gossip.pre_initial_valid_of_received_header header
    ; gossip_data
    ; body_opt
    ; substate = { s with Substate.status = Processing ctx }
    ; aux
    ; baton = false
    }

(** Mark the transition in [Verifying_blockchain_proof] processed.

   This function is called when a gossip for the transition is received.
   When gossip is received, blockchain proof is verified before any
   further processing. Hence blockchain verification for the transition
   may be skipped upon receival of a gossip.

   Blockhain proof verification is performed in batches, hence in progress
   context is not discarded but passed to the next ancestor that is in 
   [Verifying_blockchain_proof] and isn't [Processed].
*)
let make_processed ~context ~actions ~transition_states header =
  let (module Context : CONTEXT) = context in
  let state_hash = state_hash_of_header_with_validation header in
  Option.value ~default:()
  @@ let%map.Option for_restart =
       update_to_processing_done ~transition_states ~state_hash
         ~dsu:Context.processed_dsu ~reuse_ctx:true header
     in
     start ~context ~actions ~transition_states for_restart ;
     actions.Misc.mark_processed_and_promote [ state_hash ]

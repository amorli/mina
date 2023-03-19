open Mina_base
open Core_kernel

type received_info =
  { gossip : bool  (** Was it a gossip or a response to an RPC request *)
  ; received_at : Time.t
  ; sender : Network_peer.Peer.t
  }

(** Auxiliary data of a transition.
    
    It's used across many transition states to store details
    of how the transition was received.
*)
type aux_data = { received_via_gossip : bool; received : received_info list }

(** Transition state type.
    
    It contains all the available information about a transition which:

        a) is known to be invalid
        b) is in the process of verification and addition to the frontier

    In case of transition being invalid, only the minimal informaton is stored.

    Transition state type is meant to be used for transitions that were received by gossip or
    that are ancestors of a transition received by gossip.
*)
type t =
  | Received of
      { header : Gossip_types.received_header
      ; substate : unit Substate_types.t
      ; aux : aux_data
      ; gossip_data : Gossip_types.transition_gossip_t
      ; body_opt : Mina_block.Body.t option
      }  (** Transition was received and awaits ancestry to also be fetched. *)
  | Verifying_blockchain_proof of
      { header : Mina_block.Validation.pre_initial_valid_with_header
      ; substate : Mina_block.initial_valid_header Substate_types.t
      ; aux : aux_data
      ; gossip_data : Gossip_types.transition_gossip_t
      ; body_opt : Mina_block.Body.t option
      ; baton : bool
      }  (** Transition goes through verification of its blockchain proof. *)
  | Downloading_body of
      { header : Mina_block.initial_valid_header
      ; substate : Mina_block.Body.t Substate_types.t
      ; aux : aux_data
      ; block_vc : Mina_net2.Validation_callback.t option
      ; baton : bool
      }  (** Transition's body download is in progress. *)
  | Verifying_complete_works of
      { block : Mina_block.initial_valid_block
      ; substate : unit Substate_types.t
      ; aux : aux_data
      ; block_vc : Mina_net2.Validation_callback.t option
      ; baton : bool
      }  (** Transition goes through verification of transaction snarks. *)
  | Building_breadcrumb of
      { block : Mina_block.initial_valid_block
      ; substate : Frontier_base.Breadcrumb.t Substate_types.t
      ; aux : aux_data
      ; block_vc : Mina_net2.Validation_callback.t option
      ; ancestors : State_hash.t Length_map.t
      }  (** Transition's breadcrumb is being built. *)
  | Waiting_to_be_added_to_frontier of
      { breadcrumb : Frontier_base.Breadcrumb.t
      ; source : [ `Catchup | `Gossip | `Internal ]
      ; children : Substate_types.children_sets
      }
      (** Transition's breadcrumb is ready and waits in queue to be added to frontier. *)
  | Invalid of
      { transition_meta : Substate_types.transition_meta; error : Error.t }
      (** Transition is invalid. *)

(** Instantiation of [Substate_types.State_functions] for transition state type [t].  *)
module State_functions : Substate_types.State_functions with type state_t = t =
struct
  type state_t = t

  let name = function
    | Received _ ->
        "received"
    | Verifying_blockchain_proof _ ->
        "verifying blockchain proof"
    | Downloading_body _ ->
        "downloading body"
    | Verifying_complete_works _ ->
        "verifying complete works"
    | Building_breadcrumb _ ->
        "building breadcrumb"
    | Waiting_to_be_added_to_frontier _ ->
        "waiting to be added to frontier"
    | Invalid _ ->
        "invalid"

  let modify_substate ~f:{ Substate_types.modifier = f } state =
    match state with
    | Received ({ substate = s; _ } as obj) ->
        let substate, v = f s in
        Some (Received { obj with substate }, v)
    | Verifying_blockchain_proof ({ substate = s; _ } as obj) ->
        let substate, v = f s in
        Some (Verifying_blockchain_proof { obj with substate }, v)
    | Downloading_body ({ substate = s; _ } as obj) ->
        let substate, v = f s in
        Some (Downloading_body { obj with substate }, v)
    | Verifying_complete_works ({ substate = s; _ } as obj) ->
        let substate, v = f s in
        Some (Verifying_complete_works { obj with substate }, v)
    | Building_breadcrumb ({ substate = s; _ } as obj) ->
        let substate, v = f s in
        Some (Building_breadcrumb { obj with substate }, v)
    | Invalid _ | Waiting_to_be_added_to_frontier _ ->
        None

  let transition_meta st =
    let of_block = With_hash.map ~f:Mina_block.header in
    match st with
    | Received { header; _ } ->
        Substate_types.transition_meta_of_header_with_hash
        @@ Gossip_types.header_with_hash_of_received_header header
    | Verifying_blockchain_proof { header; _ } ->
        Substate_types.transition_meta_of_header_with_hash
        @@ Mina_block.Validation.header_with_hash header
    | Downloading_body { header; _ } ->
        Substate_types.transition_meta_of_header_with_hash
        @@ Mina_block.Validation.header_with_hash header
    | Verifying_complete_works { block; _ } ->
        Substate_types.transition_meta_of_header_with_hash @@ of_block
        @@ Mina_block.Validation.block_with_hash block
    | Building_breadcrumb { block; _ } ->
        Substate_types.transition_meta_of_header_with_hash @@ of_block
        @@ Mina_block.Validation.block_with_hash block
    | Waiting_to_be_added_to_frontier { breadcrumb; _ } ->
        Substate_types.transition_meta_of_header_with_hash @@ of_block
        @@ Frontier_base.Breadcrumb.block_with_hash breadcrumb
    | Invalid { transition_meta; _ } ->
        transition_meta

  let equal_state_levels a b =
    match (a, b) with
    | Received _, Received _ ->
        true
    | Verifying_blockchain_proof _, Verifying_blockchain_proof _ ->
        true
    | Downloading_body _, Downloading_body _ ->
        true
    | Verifying_complete_works _, Verifying_complete_works _ ->
        true
    | Building_breadcrumb _, Building_breadcrumb _ ->
        true
    | Waiting_to_be_added_to_frontier _, Waiting_to_be_added_to_frontier _ ->
        true
    | Invalid _, Invalid _ ->
        true
    | _, _ ->
        false
end

(** Get children sets of a transition state.

    In case of [Invalid] state, [Substate_types.empty_children_sets] is returned. *)
let children st =
  match st with
  | Received { substate = { children; _ }; _ }
  | Verifying_blockchain_proof { substate = { children; _ }; _ }
  | Downloading_body { substate = { children; _ }; _ }
  | Verifying_complete_works { substate = { children; _ }; _ }
  | Building_breadcrumb { substate = { children; _ }; _ }
  | Waiting_to_be_added_to_frontier { children; _ } ->
      children
  | Invalid _ ->
      Substate_types.empty_children_sets

(** Returns true iff the state's status is [Failed].
    
    For [Invalid] and [Waiting_to_be_added_to_frontier], [false] is returned. *)
let is_failed st =
  match st with
  | Received { substate = { status = Failed _; _ }; _ }
  | Verifying_blockchain_proof { substate = { status = Failed _; _ }; _ }
  | Downloading_body { substate = { status = Failed _; _ }; _ }
  | Verifying_complete_works { substate = { status = Failed _; _ }; _ }
  | Building_breadcrumb { substate = { status = Failed _; _ }; _ } ->
      true
  | _ ->
      false

(** Modify auxiliary data stored in the transition state. *)
let modify_aux_data ~f = function
  | Received ({ aux; _ } as r) ->
      Received { r with aux = f aux }
  | Verifying_blockchain_proof ({ aux; _ } as r) ->
      Verifying_blockchain_proof { r with aux = f aux }
  | Downloading_body ({ aux; _ } as r) ->
      Downloading_body { r with aux = f aux }
  | Verifying_complete_works ({ aux; _ } as r) ->
      Verifying_complete_works { r with aux = f aux }
  | Building_breadcrumb ({ aux; _ } as r) ->
      Building_breadcrumb { r with aux = f aux }
  | (Waiting_to_be_added_to_frontier _ as st) | (Invalid _ as st) ->
      st

let aux_data = function
  | Received { aux; _ }
  | Verifying_blockchain_proof { aux; _ }
  | Downloading_body { aux; _ }
  | Verifying_complete_works { aux; _ }
  | Building_breadcrumb { aux; _ } ->
      Some aux
  | _ ->
      None

let shutdown_modifier = function
  | { Substate_types.status = Processing (In_progress { interrupt_ivar; _ })
    ; _
    } as r ->
      Async_kernel.Ivar.fill_if_empty interrupt_ivar () ;
      ({ r with status = Failed (Error.of_string "shut down") }, ())
  | s ->
      (s, ())

let shutdown_in_progress st =
  Option.value_map ~default:st ~f:fst
    (State_functions.modify_substate ~f:{ modifier = shutdown_modifier } st)

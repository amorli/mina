open Core_kernel
open Mina_base

module type Callbacks = sig
  val on_invalid :
       ?reason:[ `Proof | `Signature_or_proof | `Other ]
    -> error:Error.t
    -> aux:Transition_state.aux_data
    -> Substate.transition_meta
    -> unit

  val on_add_new : State_hash.t -> unit

  val on_remove : State_hash.t -> unit
end

module Inmem (C : Callbacks) = struct
  type state_t = Transition_state.t

  type t = Transition_state.t State_hash.Table.t

  let add_new transition_states state =
    let transition_meta =
      Transition_state.State_functions.transition_meta state
    in
    let key = transition_meta.Substate.state_hash in
    State_hash.Table.add_exn transition_states ~key ~data:state ;
    C.on_add_new key

  (** Mark transition and all its descedandants invalid. *)
  let mark_invalid ?reason transition_states ~error:err
      ~state_hash:top_state_hash =
    let open Transition_state in
    let tag =
      sprintf "(from state hash %s) "
        (State_hash.to_base58_check top_state_hash)
    in
    let error = Error.tag ~tag err in
    let res = ref [] in
    let rec go = State_hash.Table.change transition_states ~f
    and f st_opt =
      let%bind.Option state = st_opt in
      let%map.Option aux = Transition_state.aux_data state in
      let transition_meta = State_functions.transition_meta state in
      C.on_invalid ?reason ~error ~aux transition_meta ;
      res := transition_meta :: !res ;
      ( match state with
      | Received { gossip_data; _ }
      | Verifying_blockchain_proof { gossip_data; _ } ->
          Gossip_types.drop_gossip_data `Reject gossip_data
      | Downloading_body { block_vc; _ }
      | Verifying_complete_works { block_vc; _ }
      | Building_breadcrumb { block_vc; _ } ->
          Option.iter
            ~f:
              (Fn.flip Mina_net2.Validation_callback.fire_if_not_already_fired
                 `Reject )
            block_vc
      | Invalid _ | Waiting_to_be_added_to_frontier _ ->
          () ) ;
      let children = children state in
      State_hash.Set.iter children.processing_or_failed ~f:go ;
      State_hash.Set.iter children.processed ~f:go ;
      State_hash.Set.iter children.waiting_for_parent ~f:go ;
      Invalid { transition_meta; error }
    in
    go top_state_hash ; !res

  let find = State_hash.Table.find

  let modify_substate transition_states ~f:{ Substate_types.ext_modifier }
      state_hash =
    let%bind.Option old_st =
      State_hash.Table.find transition_states state_hash
    in
    let%map.Option st, a =
      Transition_state.State_functions.modify_substate
        ~f:{ modifier = (fun subst -> ext_modifier old_st subst) }
        old_st
    in
    State_hash.Table.set transition_states ~key:state_hash ~data:st ;
    a

  let modify_substate_ transition_states ~f state_hash =
    Option.value ~default:()
    @@ let%bind.Option old_st =
         State_hash.Table.find transition_states state_hash
       in
       let%map.Option st, () =
         Transition_state.State_functions.modify_substate ~f old_st
       in
       State_hash.Table.set transition_states ~key:state_hash ~data:st

  let update transition_states state =
    State_hash.Table.set transition_states
      ~key:(Transition_state.State_functions.transition_meta state).state_hash
      ~data:state

  let remove transition_states state_hash =
    Option.value_map ~default:() ~f:(fun _ -> C.on_remove state_hash)
    @@ State_hash.Table.find_and_remove transition_states state_hash

  let update' transition_states ~f state_hash =
    Option.iter (find transition_states state_hash) ~f:(fun st ->
        match f st with
        | None ->
            remove transition_states state_hash
        | Some st' ->
            update transition_states st' )

  let shutdown_in_progress =
    State_hash.Table.map_inplace ~f:Transition_state.shutdown_in_progress

  let fold t ~init ~f =
    State_hash.Table.fold ~f:(fun ~key:_ ~data -> f data) t ~init

  let clear transition_states =
    shutdown_in_progress transition_states ;
    State_hash.Table.clear transition_states
end

type state_t = Transition_state.t

type t = Transition_state.t Substate_types.transition_states

let create_inmem (module C : Callbacks) : t =
  Substate.Transition_states ((module Inmem (C)), State_hash.Table.create ())

let add_new (Substate.Transition_states ((module Impl), m) : t) = Impl.add_new m

let mark_invalid ?reason (Substate.Transition_states ((module Impl), m) : t) =
  Impl.mark_invalid ?reason m

let find (Substate.Transition_states ((module Impl), m) : t) = Impl.find m

let modify_substate (Substate.Transition_states ((module Impl), m) : t) =
  Impl.modify_substate m

let modify_substate_ (Substate.Transition_states ((module Impl), m) : t) =
  Impl.modify_substate_ m

let remove (Substate.Transition_states ((module Impl), m) : t) = Impl.remove m

let update (Substate.Transition_states ((module Impl), m) : t) = Impl.update m

let update' (Substate.Transition_states ((module Impl), m) : t) = Impl.update' m

let shutdown_in_progress (Substate.Transition_states ((module Impl), m) : t) =
  Impl.shutdown_in_progress m

let fold (Substate.Transition_states ((module Impl), m) : t) = Impl.fold m

let clear (Substate.Transition_states ((module Impl), m) : t) = Impl.clear m

let iter ~f m = fold m ~init:() ~f:(fun st () -> f st)

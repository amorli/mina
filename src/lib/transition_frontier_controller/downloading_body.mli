open Mina_base
open Bit_catchup_state

(** Promote a transition that is in [Verifying_blockchain_proof] state with
    [Processed] status to [Downloading_body] state.
*)
val promote_to :
     context:(module Context.CONTEXT)
  -> actions:Misc.actions Async_kernel.Deferred.t
  -> transition_states:Transition_states.t
  -> substate:Mina_block.Validation.initial_valid_with_header Substate.t
  -> gossip_data:Gossip.transition_gossip_t
  -> body_opt:Mina_block.Body.t option
  -> aux:Transition_state.aux_data
  -> Transition_state.t

(** Set [baton] of the next ancestor in [Transition_state.Downloading_body]
    and [Substate.Processing (Substate.In_progress _)] status to [true]
    and restart all the failed ancestors before the next ancestors. *)
val pass_the_baton :
     transition_states:Transition_states.t
  -> context:(module Context.CONTEXT)
  -> actions:Misc.actions Async_kernel.Deferred.t
  -> State_hash.t
  -> unit

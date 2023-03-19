open Mina_base

include module type of Substate_types

(** View the common substate.
    
    Viewer [~f] is applied to the common substate
    and its result is returned by the function.
  *)
val view :
     state_functions:(module State_functions with type state_t = 'state_t)
  -> f:'a viewer
  -> 'state_t
  -> 'a option

(** [collect_ancestors top_state] collects transitions from the top state (inclusive) down the ancestry chain 
  while:
  
    1. [predicate] returns [(`Take _, `Continue true)]
    and
    2. Have same state level as [top_state]

    Returned list of states is in the parent-first order.
    Only states for which [predicate] returned [(`Take true, `Continue_)] are collected.
    State for which [(`Take true, `Continue false)] was returned by [predicate] will be taken.
*)
val collect_ancestors :
     predicate:([ `Take of bool ] * [ `Continue of bool ]) viewer
  -> state_functions:(module State_functions with type state_t = 'state_t)
  -> transition_states:'state_t transition_states
  -> 'state_t
  -> 'state_t list

(** [mark_processed processed] marks a list of state hashes as Processed.

  It returns a list of state hashes to be promoted to higher state.
   
  Pre-conditions:
   1. Order of [processed] respects parent-child relationship and parent always comes first
   2. Respective substates for states from [processed] are in [Processing (Done _)] status

  Post-condition: list returned respects parent-child relationship and parent always comes first *)
val mark_processed :
     logger:Logger.t
  -> state_functions:(module State_functions with type state_t = 'state_t)
  -> transition_states:'state_t transition_states
  -> State_hash.t list
  -> State_hash.t list

(** [mark_processed_single state_hash] marks a transition as Processed.

  It returns a pair of old transition state and old children or [None] if
  marking as [Processed] failed.
  Children structure of [state_hash]'s parent is updated.
  Updating children of transition [state_hash] is responsibility of the caller.

  Pre-condition: Transition [state_hash] is in [Processing (Done _)] status
  Post-condition: list returned respects parent-child relationship and parent always comes first *)
val mark_processed_single :
     logger:Logger.t
  -> state_functions:(module State_functions with type state_t = 'state_t)
  -> transition_states:'state_t transition_states
  -> State_hash.t
  -> ('state_t * children_sets) option

(** Update children of transition's parent when the transition is promoted
    to the higher state.

    This function removes the transition from parent's [Substate.processed] children
    set and adds it either to [Substate.waiting_for_parent] or
    [Substate.processing_or_failed] children set depending on the new status.

    When a transition's previous state was [Transition_state.Waiting_to_be_added_to_frontier],
    transition is not added to any of the parent's children sets.
*)
val update_children_on_promotion :
     state_functions:(module State_functions with type state_t = 'state_t)
  -> transition_states:'state_t transition_states
  -> parent_hash:State_hash.t
  -> state_hash:State_hash.t
  -> 'state_t option
  -> unit

(** [is_processing_done] functions takes state and returns true iff
    the status of the state is [Substate.Processing (Substate.Done _)]. *)
val is_processing_done :
     state_functions:(module State_functions with type state_t = 'state_t)
  -> 'state_t
  -> bool

val add_error_if_failed :
     tag:string
  -> 'a status
  -> (string * Yojson.Safe.t) list
  -> (string * Yojson.Safe.t) list

(** Function takes transition and returns true when one of conditions hold:

  - Transition's parent is not in the catchup state (which means it's in frontier)

  - Transition's parent has a higher state level  *)
val is_parent_higher :
     state_functions:(module State_functions with type state_t = 'state_t)
  -> 'state_t
  -> 'state_t option
  -> bool

module For_tests : sig
  (** [collect_failed_ancestry top_state] collects transitions from the top state (inclusive)
  down the ancestry chain that are:
  
    1. In [Failed] substate
    and
    2. Have same state level as [top_state]

    Returned list of states is in the parent-first order.
*)
  val collect_failed_ancestry :
       state_functions:(module State_functions with type state_t = 'state_t)
    -> transition_states:'state_t transition_states
    -> 'state_t
    -> 'state_t list

  (** [collect_dependent_ancestry top_state] collects transitions from the top state (inclusive) down the ancestry chain 
  while collected states are:
  
    1. In [Waiting_for_parent], [Failed] or [Processing Dependent] substate
    and
    2. Have same state level as [top_state]

    States with [Processed] status are skipped through.
    Returned list of states is in the parent-first order.
*)
  val collect_dependent_ancestry :
       state_functions:(module State_functions with type state_t = 'state_t)
    -> transition_states:'state_t transition_states
    -> 'state_t
    -> 'state_t list
end

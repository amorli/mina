open Async_kernel
open Pipe_lib
open Network_peer
module Transition_cache = Transition_cache

module type CONTEXT = sig
  val logger : Logger.t

  val precomputed_values : Precomputed_values.t

  val constraint_constants : Genesis_constants.Constraint_constants.t

  val consensus_constants : Consensus.Constants.t

  val conf_dir : string
end

type Structured_log_events.t += Bootstrap_complete [@@deriving register_event]

val run :
     context:(module CONTEXT)
  -> trust_system:Trust_system.t
  -> verifier:Verifier.t
  -> network:Mina_networking.t
  -> consensus_local_state:Consensus.Data.Local_state.t
  -> transition_reader:
       ( [ `Block of Mina_block.initial_valid_block Envelope.Incoming.t
         | `Header of Mina_block.initial_valid_header Envelope.Incoming.t ]
       * [ `Valid_cb of Mina_net2.Validation_callback.t option ] )
       Strict_pipe.Reader.t
  -> preferred_peers:Network_peer.Peer.t list
  -> persistent_root:Transition_frontier.Persistent_root.t
  -> persistent_frontier:Transition_frontier.Persistent_frontier.t
  -> initial_root_transition:Mina_block.Validated.t
  -> catchup_mode:
       [ `Bit of Bit_catchup_state.Transition_states.t | `Normal | `Super ]
  -> (Transition_frontier.t * Transition_cache.element list) Deferred.t

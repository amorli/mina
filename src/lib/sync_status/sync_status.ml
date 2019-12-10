open Core_kernel

(** Sync_status represent states interacting with peers in the coda protocol.
    When the protocol is starting, the node should be in the CONNECT state
    trying to connect to a peer. Once it connects to a peer, the node should be
    in the LISTENING state waiting for peers to send a message to them. When
    the node receives a constant flow of messages, its state should be SYNCED.
    However, when the node is bootstrapping, its state is BOOTSTRAPPING. If it
    hasn’t received messages for some time
    (Consensus.Constants.inactivity_secs), then it is OFFLINE. *)
let to_string = function
  | `Connecting ->
      "Connecting"
  | `Listening ->
      "Listening"
  | `Offline ->
      "Offline"
  | `Bootstrap ->
      "Bootstrap"
  | `Synced ->
      "Synced"
  | `Catchup ->
      "Catchup"

let of_string string =
  match String.lowercase string with
  | "connecting" ->
      Ok `Connecting
  | "listening" ->
      Ok `Listening
  | "offline" ->
      Ok `Offline
  | "bootstrap" ->
      Ok `Bootstrap
  | "synced" ->
      Ok `Synced
  | "catchup" ->
      Ok `Catchup
  | status ->
      Error (Error.createf !"%s is not a valid status" status)

let of_string_exn = Fn.compose Or_error.ok_exn of_string

[%%versioned
module Stable = struct
  module V1 = struct
    type t =
      [`Connecting | `Listening | `Offline | `Bootstrap | `Synced | `Catchup]
    [@@deriving sexp, hash, compare, equal, enumerate]

    let to_latest = Fn.id

    module T = struct
      type typ = t [@@deriving sexp, hash, compare, equal, enumerate]

      type t = typ [@@deriving sexp, hash, compare, equal, enumerate]
    end

    include Codable.Make_of_string (struct
      include T

      let to_string = to_string

      let of_string = of_string_exn
    end)

    include Hashable.Make (T)
  end
end]

type t = [`Connecting | `Listening | `Offline | `Bootstrap | `Synced | `Catchup]
[@@deriving sexp, hash, equal, enumerate]

[%%define_locally
Stable.Latest.(to_yojson, of_yojson)]

include Hashable.Make (Stable.Latest.T)

let%test "of_string (to_string x) == x" =
  List.for_all
    [`Offline; `Bootstrap; `Synced; `Connecting; `Listening; `Catchup]
    ~f:(fun sync_status ->
      equal sync_status (of_string (to_string sync_status) |> Or_error.ok_exn)
  )

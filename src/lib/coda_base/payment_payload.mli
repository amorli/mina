open Core
open Fold_lib
open Tuple_lib
open Coda_numbers
open Snark_params.Tick
open Sha256_lib
open Import

type ('pk, 'amount, 'memo) t_ = {receiver: 'pk; amount: 'amount; memo: 'memo}
[@@deriving bin_io, eq, sexp, hash]

type t = (Public_key.Compressed.t, Currency.Amount.t, Payment_memo.t) t_
[@@deriving bin_io, eq, sexp, hash]

val dummy : t

val gen : t Quickcheck.Generator.t

module Stable : sig
  module V1 : sig
    type nonrec ('pk, 'amount, 'memo) t_ = ('pk, 'amount, 'memo) t_ =
      {receiver: 'pk; amount: 'amount; memo: 'memo}
    [@@deriving bin_io, eq, sexp, hash]

    type t =
      ( Public_key.Compressed.Stable.V1.t
      , Currency.Amount.Stable.V1.t
      , Payment_memo.t )
      t_
    [@@deriving bin_io, eq, sexp, hash]
  end
end

type var =
  (Public_key.Compressed.var, Currency.Amount.var, Payment_memo.var) t_

val length_in_triples : int

val typ : (var, t) Typ.t

val to_triples : t -> bool Triple.t list

val fold : t -> bool Triple.t Fold.t

val var_to_triples : var -> (Boolean.var Triple.t list, _) Checked.t

val var_of_t : t -> var

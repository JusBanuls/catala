(* This file is part of the Catala compiler, a specification language for tax
   and social benefits computation rules. Copyright (C) 2020 Inria, contributor:
   Denis Merigoux <denis.merigoux@inria.fr>

   Licensed under the Apache License, Version 2.0 (the "License"); you may not
   use this file except in compliance with the License. You may obtain a copy of
   the License at

   http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
   WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
   License for the specific language governing permissions and limitations under
   the License. *)

open Catala_utils
open Shared_ast

(** Abstract syntax tree for the lambda calculus *)

(** {1 Abstract syntax tree} *)

type lit = lcalc glit

type 'm naked_expr = (lcalc, 'm mark) naked_gexpr
and 'm expr = (lcalc, 'm mark) gexpr

type 'm program = 'm expr Shared_ast.program

(** {1 Language terms construction}*)

val option_enum : EnumName.t
val none_constr : EnumConstructor.t
val some_constr : EnumConstructor.t
val option_enum_config : typ EnumConstructor.Map.t
val make_none : 'm mark -> 'm expr boxed
val make_some : 'm expr boxed -> 'm expr boxed

val make_matchopt_with_abs_arms :
  'm expr boxed -> 'm expr boxed -> 'm expr boxed -> 'm expr boxed

val make_matchopt :
  Pos.t ->
  'm expr Var.t ->
  typ ->
  'm expr boxed ->
  'm expr boxed ->
  'm expr boxed ->
  'm expr boxed
(** [e' = make_matchopt'' pos v e e_none e_some] Builds the term corresponding
    to [match e with | None -> fun () -> e_none |Some -> fun v -> e_some]. *)

val make_bind_cont :
  typed mark ->
  typed expr boxed ->
  (typed expr boxed -> typed expr boxed) ->
  typed expr boxed

val make_bindm_cont :
  typed mark ->
  typed expr boxed list ->
  (typed expr boxed list -> typed expr boxed) ->
  typed expr boxed

(** {1 Special symbols} *)

val handle_default : untyped expr Var.t
val handle_default_opt : untyped expr Var.t

(* This file is part of the Catala compiler, a specification language for tax
   and social benefits computation rules. Copyright (C) 2020-2022 Inria,
   contributor: Denis Merigoux <denis.merigoux@inria.fr>, Alain Delaët-Tixeuil
   <alain.delaet--tixeuil@inria.fr>, Louis Gesbert <louis.gesbert@inria.fr>

   Licensed under the Apache License, Version 2.0 (the "License"); you may not
   use this file except in compliance with the License. You may obtain a copy of
   the License at

   http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
   WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
   License for the specific language governing permissions and limitations under
   the License. *)

open Definitions

(** {2 Transformations} *)

val map_exprs :
  f:('expr1 -> 'expr2 boxed) ->
  varf:('expr1 Var.t -> 'expr2 Var.t) ->
  'expr1 program ->
  'expr2 program Bindlib.box

val get_scope_body :
  (([< dcalc | lcalc ], _) gexpr as 'e) program -> ScopeName.t -> 'e scope_body

val untype :
  (([< dcalc | lcalc ] as 'a), 'm mark) gexpr program ->
  ('a, untyped mark) gexpr program

val to_expr :
  (([< dcalc | lcalc ], _) gexpr as 'e) program -> ScopeName.t -> 'e boxed
(** Usage: [build_whole_program_expr program main_scope] builds an expression
    corresponding to the main program and returning the main scope as a
    function. *)

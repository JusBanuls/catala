(* This file is part of the Catala compiler, a specification language for tax
   and social benefits computation rules. Copyright (C) 2022 Inria,
   contributors: Alain Delaët <alain.delaet--tixeuil@inria.fr>, Denis Merigoux
   <denis.merigoux@inria.fr>

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
open Ast

type partial_evaluation_ctx = {
  var_values : (typed expr, typed expr) Var.Map.t;
  decl_ctx : decl_ctx;
}

let rec partial_evaluation (ctx : partial_evaluation_ctx) (e : 'm expr) :
    (dcalc, 'm mark) boxed_gexpr =
  (* We proceed bottom-up, first apply on the subterms *)
  let e = Expr.map ~f:(partial_evaluation ctx) e in
  let mark = Marked.get_mark e in
  (* Then reduce the parent node *)
  let reduce e =
    (* Todo: improve the handling of eapp(log,elit) cases here, it obfuscates
       the matches and the log calls are not preserved, which would be a good
       property *)
    match Marked.unmark e with
    | EApp
        {
          f =
            ( EOp (Unop Not), _
            | ( EApp { f = EOp (Unop (Log _)), _; args = [(EOp (Unop Not), _)] },
                _ ) ) as op;
          args = [e1];
        } -> (
      (* reduction of logical not *)
      match e1 with
      | ELit (LBool false), _ -> ELit (LBool true)
      | ELit (LBool true), _ -> ELit (LBool false)
      | e1 -> EApp { f = op; args = [e1] })
    | EApp
        {
          f =
            ( EOp (Binop Or), _
            | ( EApp { f = EOp (Unop (Log _)), _; args = [(EOp (Binop Or), _)] },
                _ ) ) as op;
          args = [e1; e2];
        } -> (
      (* reduction of logical or *)
      match e1, e2 with
      | (ELit (LBool false), _), new_e | new_e, (ELit (LBool false), _) ->
        Marked.unmark new_e
      | (ELit (LBool true), _), _ | _, (ELit (LBool true), _) ->
        ELit (LBool true)
      | _ -> EApp { f = op; args = [e1; e2] })
    | EApp
        {
          f =
            ( EOp (Binop And), _
            | ( EApp { f = EOp (Unop (Log _)), _; args = [(EOp (Binop And), _)] },
                _ ) ) as op;
          args = [e1; e2];
        } -> (
      (* reduction of logical and *)
      match e1, e2 with
      | (ELit (LBool true), _), new_e | new_e, (ELit (LBool true), _) ->
        Marked.unmark new_e
      | (ELit (LBool false), _), _ | _, (ELit (LBool false), _) ->
        ELit (LBool false)
      | _ -> EApp { f = op; args = [e1; e2] })
    | EMatch { e = EInj { e; name = name1; cons }, _; cases; name }
      when EnumName.equal name name1 ->
      (* iota reduction *)
      EApp { f = EnumConstructor.Map.find cons cases; args = [e] }
    | EApp { f = EAbs { binder; _ }, _; args } ->
      (* beta reduction *)
      Marked.unmark (Bindlib.msubst binder (List.map fst args |> Array.of_list))
    | EDefault { excepts; just; cons } -> (
      (* TODO: mechanically prove each of these optimizations correct :) *)
      let excepts =
        List.filter
          (fun except -> Marked.unmark except <> ELit LEmptyError)
          excepts
        (* we can discard the exceptions that are always empty error *)
      in
      let value_except_count =
        List.fold_left
          (fun nb except -> if Expr.is_value except then nb + 1 else nb)
          0 excepts
      in
      if value_except_count > 1 then
        (* at this point we know a conflict error will be triggered so we just
           feed the expression to the interpreter that will print the beautiful
           right error message *)
        Marked.unmark (Interpreter.evaluate_expr ctx.decl_ctx e)
      else
        match excepts, just with
        | [except], _ when Expr.is_value except ->
          (* if there is only one exception and it is a non-empty value it is
             always chosen *)
          Marked.unmark except
        | ( [],
            ( ( ELit (LBool true)
              | EApp
                  { f = EOp (Unop (Log _)), _; args = [(ELit (LBool true), _)] }
                ),
              _ ) ) ->
          Marked.unmark cons
        | ( [],
            ( ( ELit (LBool false)
              | EApp
                  {
                    f = EOp (Unop (Log _)), _;
                    args = [(ELit (LBool false), _)];
                  } ),
              _ ) ) ->
          ELit LEmptyError
        | [], just when not !Cli.avoid_exceptions_flag ->
          (* without exceptions, a default is just an [if then else] raising an
             error in the else case. This exception is only valid in the context
             of compilation_with_exceptions, so we desactivate with a global
             flag to know if we will be compiling using exceptions or the option
             monad. FIXME: move this optimisation somewhere else to avoid this
             check *)
          EIfThenElse
            { cond = just; etrue = cons; efalse = ELit LEmptyError, mark }
        | excepts, just -> EDefault { excepts; just; cons })
    | EIfThenElse
        {
          cond =
            ( ELit (LBool true), _
            | ( EApp
                  { f = EOp (Unop (Log _)), _; args = [(ELit (LBool true), _)] },
                _ ) );
          etrue;
          _;
        } ->
      Marked.unmark etrue
    | EIfThenElse
        {
          cond =
            ( ( ELit (LBool false)
              | EApp
                  {
                    f = EOp (Unop (Log _)), _;
                    args = [(ELit (LBool false), _)];
                  } ),
              _ );
          efalse;
          _;
        } ->
      Marked.unmark efalse
    | EIfThenElse
        {
          cond;
          etrue =
            ( ( ELit (LBool btrue)
              | EApp
                  {
                    f = EOp (Unop (Log _)), _;
                    args = [(ELit (LBool btrue), _)];
                  } ),
              _ );
          efalse =
            ( ( ELit (LBool bfalse)
              | EApp
                  {
                    f = EOp (Unop (Log _)), _;
                    args = [(ELit (LBool bfalse), _)];
                  } ),
              _ );
        } ->
      if btrue && not bfalse then Marked.unmark cond
      else if (not btrue) && bfalse then
        EApp { f = EOp (Unop Not), mark; args = [cond] }
        (* note: this last call eliminates the condition & might skip log calls
           as well *)
      else (* btrue = bfalse *) ELit (LBool btrue)
    | e -> e
  in
  Expr.Box.app1 e reduce mark

let optimize_expr (decl_ctx : decl_ctx) (e : 'm expr) =
  partial_evaluation { var_values = Var.Map.empty; decl_ctx } e

let rec scope_lets_map
    (t : 'a -> 'm expr -> (dcalc, 'm mark) boxed_gexpr)
    (ctx : 'a)
    (scope_body_expr : 'm expr scope_body_expr) :
    'm expr scope_body_expr Bindlib.box =
  match scope_body_expr with
  | Result e ->
    Bindlib.box_apply (fun e' -> Result e') (Expr.Box.lift (t ctx e))
  | ScopeLet scope_let ->
    let var, next = Bindlib.unbind scope_let.scope_let_next in
    let new_scope_let_expr = Expr.Box.lift (t ctx scope_let.scope_let_expr) in
    let new_next = scope_lets_map t ctx next in
    let new_next = Bindlib.bind_var var new_next in
    Bindlib.box_apply2
      (fun new_scope_let_expr new_next ->
        ScopeLet
          {
            scope_let with
            scope_let_expr = new_scope_let_expr;
            scope_let_next = new_next;
          })
      new_scope_let_expr new_next

let rec scopes_map
    (t : 'a -> 'm expr -> (dcalc, 'm mark) boxed_gexpr)
    (ctx : 'a)
    (scopes : 'm expr scopes) : 'm expr scopes Bindlib.box =
  match scopes with
  | Nil -> Bindlib.box Nil
  | ScopeDef scope_def ->
    let scope_var, scope_next = Bindlib.unbind scope_def.scope_next in
    let scope_arg_var, scope_body_expr =
      Bindlib.unbind scope_def.scope_body.scope_body_expr
    in
    let new_scope_body_expr = scope_lets_map t ctx scope_body_expr in
    let new_scope_body_expr =
      Bindlib.bind_var scope_arg_var new_scope_body_expr
    in
    let new_scope_next = scopes_map t ctx scope_next in
    let new_scope_next = Bindlib.bind_var scope_var new_scope_next in
    Bindlib.box_apply2
      (fun new_scope_body_expr new_scope_next ->
        ScopeDef
          {
            scope_def with
            scope_next = new_scope_next;
            scope_body =
              {
                scope_def.scope_body with
                scope_body_expr = new_scope_body_expr;
              };
          })
      new_scope_body_expr new_scope_next

let program_map
    (t : 'a -> 'm expr -> (dcalc, 'm mark) boxed_gexpr)
    (ctx : 'a)
    (p : 'm program) : 'm program Bindlib.box =
  Bindlib.box_apply
    (fun new_scopes -> { p with scopes = new_scopes })
    (scopes_map t ctx p.scopes)

let optimize_program (p : 'm program) : 'm program =
  Bindlib.unbox
    (program_map partial_evaluation
       { var_values = Var.Map.empty; decl_ctx = p.decl_ctx }
       p)

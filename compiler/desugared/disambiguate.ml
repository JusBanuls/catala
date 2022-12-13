(* This file is part of the Catala compiler, a specification language for tax
   and social benefits computation rules. Copyright (C) 2020 Inria, contributor:
   Louis Gesbert <louis.gesbert@inria.fr>

   Licensed under the Apache License, Version 2.0 (the "License"); you may not
   use this file except in compliance with the License. You may obtain a copy of
   the License at

   http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
   WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
   License for the specific language governing permissions and limitations under
   the License. *)

open Shared_ast
open Ast

let expr ctx env e =
  (* The typer takes care of disambiguating: this consists in: - ensuring
     [EAbs.tys] doesn't contain any [TAny] - [EDStructAccess.name_opt] is always
     [Some] *)
  (* Intermediate unboxings are fine since the last [untype] will rebox in
     depth *)
  Typing.check_expr ~leave_unresolved:false ctx ~env (Expr.unbox e)

let rule ctx env rule =
  let env =
    match rule.rule_parameter with
    | None -> env
    | Some (v, ty) -> Typing.Env.add_var v ty env
  in
  (* Note: we could use the known rule type here to direct typing. We choose not
     to because it shouldn't be needed for disambiguation, and we prefer to
     focus on local type errors first. *)
  {
    rule with
    rule_just = expr ctx env rule.rule_just;
    rule_cons = expr ctx env rule.rule_cons;
  }

let scope ctx env scope =
  let env = Typing.Env.open_scope scope.scope_uid env in
  let scope_defs =
    ScopeDefMap.map
      (fun def ->
        let scope_def_rules =
          (* Note: ordering in file order might be better for error reporting ?
             When we gather errors, the ordering could be done afterwards,
             though *)
          RuleName.Map.map (rule ctx env) def.scope_def_rules
        in
        { def with scope_def_rules })
      scope.scope_defs
  in
  let scope_assertions = List.map (expr ctx env) scope.scope_assertions in
  { scope with scope_defs; scope_assertions }

let program prg =
  let env =
    ScopeName.Map.fold
      (fun scope_name scope env ->
        let vars =
          ScopeDefMap.fold
            (fun var def vars ->
              match var with
              | Var (v, _states) -> ScopeVar.Map.add v def.scope_def_typ vars
              | SubScopeVar _ -> vars)
            scope.scope_defs ScopeVar.Map.empty
        in
        Typing.Env.add_scope scope_name ~vars env)
      prg.program_scopes
      (Typing.Env.empty prg.program_ctx)
  in
  let program_scopes =
    ScopeName.Map.map (scope prg.program_ctx env) prg.program_scopes
  in
  { prg with program_scopes }

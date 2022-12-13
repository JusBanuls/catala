(* This file is part of the Catala compiler, a specification language for tax
   and social benefits computation rules. Copyright (C) 2022 Inria, contributor:
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
open Ast

let needs_parens (_e : expr) : bool = false

let format_local_name (fmt : Format.formatter) (v : LocalName.t) : unit =
  Format.fprintf fmt "%a_%s" LocalName.format_t v
    (string_of_int (LocalName.hash v))

let rec format_expr
    (decl_ctx : decl_ctx)
    ?(debug : bool = false)
    (fmt : Format.formatter)
    (e : expr) : unit =
  let format_expr = format_expr decl_ctx ~debug in
  let format_with_parens (fmt : Format.formatter) (e : expr) =
    if needs_parens e then
      Format.fprintf fmt "%a%a%a" Print.punctuation "(" format_expr e
        Print.punctuation ")"
    else Format.fprintf fmt "%a" format_expr e
  in
  match Marked.unmark e with
  | EVar v -> Format.fprintf fmt "%a" format_local_name v
  | EFunc v -> Format.fprintf fmt "%a" TopLevelName.format_t v
  | EStruct (es, s) ->
    Format.fprintf fmt "@[<hov 2>%a@ %a%a%a@]" StructName.format_t s
      Print.punctuation "{"
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt ",@ ")
         (fun fmt (e, (struct_field, _)) ->
           Format.fprintf fmt "%a%a%a%a %a" Print.punctuation "\""
             StructField.format_t struct_field Print.punctuation "\""
             Print.punctuation ":" format_expr e))
      (List.combine es
         (StructField.Map.bindings (StructName.Map.find s decl_ctx.ctx_structs)))
      Print.punctuation "}"
  | EArray es ->
    Format.fprintf fmt "@[<hov 2>%a%a%a@]" Print.punctuation "["
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt ";@ ")
         (fun fmt e -> Format.fprintf fmt "%a" format_expr e))
      es Print.punctuation "]"
  | EStructFieldAccess (e1, field, _) ->
    Format.fprintf fmt "%a%a%a%a%a" format_expr e1 Print.punctuation "."
      Print.punctuation "\"" StructField.format_t field Print.punctuation "\""
  | EInj (e, cons, _) ->
    Format.fprintf fmt "@[<hov 2>%a@ %a@]" Print.enum_constructor cons
      format_expr e
  | ELit l -> Print.lit fmt l
  | EApp ((EOp ((Map | Filter) as op), _), [arg1; arg2]) ->
    Format.fprintf fmt "@[<hov 2>%a@ %a@ %a@]" Print.operator op
      format_with_parens arg1 format_with_parens arg2
  | EApp ((EOp op, _), [arg1; arg2]) ->
    Format.fprintf fmt "@[<hov 2>%a@ %a@ %a@]" format_with_parens arg1
      Print.operator op format_with_parens arg2
  | EApp ((EOp (Log _), _), [arg1]) when not debug ->
    Format.fprintf fmt "%a" format_with_parens arg1
  | EApp ((EOp op, _), [arg1]) ->
    Format.fprintf fmt "@[<hov 2>%a@ %a@]" Print.operator op format_with_parens
      arg1
  | EApp (f, args) ->
    Format.fprintf fmt "@[<hov 2>%a@ %a@]" format_expr f
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt "@ ")
         format_with_parens)
      args
  | EOp op -> Format.fprintf fmt "%a" Print.operator op

let rec format_statement
    (decl_ctx : decl_ctx)
    ?(debug : bool = false)
    (fmt : Format.formatter)
    (stmt : stmt Marked.pos) : unit =
  if debug then () else ();
  match Marked.unmark stmt with
  | SInnerFuncDef (name, func) ->
    Format.fprintf fmt "@[<hov 2>%a@ %a@ %a@ %a@]@\n@[<v 2>  %a@]" Print.keyword
      "let" format_local_name (Marked.unmark name)
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt "@ ")
         (fun fmt ((name, _), typ) ->
           Format.fprintf fmt "%a%a %a@ %a%a" Print.punctuation "("
             format_local_name name Print.punctuation ":" (Print.typ decl_ctx)
             typ Print.punctuation ")"))
      func.func_params Print.punctuation "="
      (format_block decl_ctx ~debug)
      func.func_body
  | SLocalDecl (name, typ) ->
    Format.fprintf fmt "@[<hov 2>%a %a %a@ %a@]" Print.keyword "decl"
      format_local_name (Marked.unmark name) Print.punctuation ":"
      (Print.typ decl_ctx) typ
  | SLocalDef (name, naked_expr) ->
    Format.fprintf fmt "@[<hov 2>%a %a@ %a@]" format_local_name
      (Marked.unmark name) Print.punctuation "="
      (format_expr decl_ctx ~debug)
      naked_expr
  | STryExcept (b_try, except, b_with) ->
    Format.fprintf fmt "@[<v 2>%a%a@ %a@]@\n@[<v 2>%a %a%a@ %a@]" Print.keyword
      "try" Print.punctuation ":"
      (format_block decl_ctx ~debug)
      b_try Print.keyword "with" Print.except except Print.punctuation ":"
      (format_block decl_ctx ~debug)
      b_with
  | SRaise except ->
    Format.fprintf fmt "@[<hov 2>%a %a@]" Print.keyword "raise" Print.except
      except
  | SIfThenElse (e_if, b_true, b_false) ->
    Format.fprintf fmt "@[<v 2>%a @[<hov 2>%a@]%a@ %a@ @]@[<v 2>%a%a@ %a@]"
      Print.keyword "if"
      (format_expr decl_ctx ~debug)
      e_if Print.punctuation ":"
      (format_block decl_ctx ~debug)
      b_true Print.keyword "else" Print.punctuation ":"
      (format_block decl_ctx ~debug)
      b_false
  | SReturn ret ->
    Format.fprintf fmt "@[<hov 2>%a %a@]" Print.keyword "return"
      (format_expr decl_ctx ~debug)
      (ret, Marked.get_mark stmt)
  | SAssert naked_expr ->
    Format.fprintf fmt "@[<hov 2>%a %a@]" Print.keyword "assert"
      (format_expr decl_ctx ~debug)
      (naked_expr, Marked.get_mark stmt)
  | SSwitch (e_switch, enum, arms) ->
    Format.fprintf fmt "@[<v 0>%a @[<hov 2>%a@]%a@]%a" Print.keyword "switch"
      (format_expr decl_ctx ~debug)
      e_switch Print.punctuation ":"
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt "@\n")
         (fun fmt ((case, _), (arm_block, payload_name)) ->
           Format.fprintf fmt "%a %a%a@ %a @[<v 2>%a@ %a@]" Print.punctuation
             "|" Print.enum_constructor case Print.punctuation ":"
             format_local_name payload_name Print.punctuation "→"
             (format_block decl_ctx ~debug)
             arm_block))
      (List.combine
         (EnumConstructor.Map.bindings
            (EnumName.Map.find enum decl_ctx.ctx_enums))
         arms)

and format_block
    (decl_ctx : decl_ctx)
    ?(debug : bool = false)
    (fmt : Format.formatter)
    (block : block) : unit =
  Format.pp_print_list
    ~pp_sep:(fun fmt () -> Format.fprintf fmt "%a@ " Print.punctuation ";")
    (format_statement decl_ctx ~debug)
    fmt block

let format_scope
    (decl_ctx : decl_ctx)
    ?(debug : bool = false)
    (fmt : Format.formatter)
    (body : scope_body) : unit =
  if debug then () else ();
  Format.fprintf fmt "@[<hov 2>%a@ %a@ %a@ %a@]@\n@[<v 2>  %a@]" Print.keyword
    "let" TopLevelName.format_t body.scope_body_var
    (Format.pp_print_list
       ~pp_sep:(fun fmt () -> Format.fprintf fmt "@ ")
       (fun fmt ((name, _), typ) ->
         Format.fprintf fmt "%a%a %a@ %a%a" Print.punctuation "("
           format_local_name name Print.punctuation ":" (Print.typ decl_ctx) typ
           Print.punctuation ")"))
    body.scope_body_func.func_params Print.punctuation "="
    (format_block decl_ctx ~debug)
    body.scope_body_func.func_body

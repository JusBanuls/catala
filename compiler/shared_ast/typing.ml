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

(** Typing for the default calculus. Because of the error terms, we perform type
    inference using the classical W algorithm with union-find unification. *)

open Catala_utils
module A = Definitions

module Any =
  Uid.Make
    (struct
      type info = unit

      let to_string _ = "any"
      let format fmt () = Format.fprintf fmt "any"
      let equal _ _ = true
      let compare _ _ = 0
    end)
    ()

type unionfind_typ = naked_typ Marked.pos UnionFind.elem
(** We do not reuse {!type: Shared_ast.typ} because we have to include a new
    [TAny] variant. Indeed, error terms can have any type and this has to be
    captured by the type sytem. *)

and naked_typ =
  | TLit of A.typ_lit
  | TArrow of unionfind_typ * unionfind_typ
  | TTuple of unionfind_typ list
  | TStruct of A.StructName.t
  | TEnum of A.EnumName.t
  | TOption of unionfind_typ
  | TArray of unionfind_typ
  | TAny of Any.t

let rec typ_to_ast ?(unsafe = false) (ty : unionfind_typ) : A.typ =
  let typ_to_ast = typ_to_ast ~unsafe in
  let ty, pos = UnionFind.get (UnionFind.find ty) in
  match ty with
  | TLit l -> A.TLit l, pos
  | TTuple ts -> A.TTuple (List.map typ_to_ast ts), pos
  | TStruct s -> A.TStruct s, pos
  | TEnum e -> A.TEnum e, pos
  | TOption t -> A.TOption (typ_to_ast t), pos
  | TArrow (t1, t2) -> A.TArrow (typ_to_ast t1, typ_to_ast t2), pos
  | TArray t1 -> A.TArray (typ_to_ast t1), pos
  | TAny _ ->
    if unsafe then A.TAny, pos
    else
      (* No polymorphism in Catala: type inference should return full types
         without wildcards, and this function is used to recover the types after
         typing. *)
      Errors.raise_spanned_error pos
        "Internal error: typing at this point could not be resolved"

(* Checks that there are no type variables remaining *)
let rec all_resolved ty =
  match Marked.unmark (UnionFind.get (UnionFind.find ty)) with
  | TAny _ -> false
  | TLit _ | TStruct _ | TEnum _ -> true
  | TOption t1 | TArray t1 -> all_resolved t1
  | TArrow (t1, t2) -> all_resolved t1 && all_resolved t2
  | TTuple ts -> List.for_all all_resolved ts

let rec ast_to_typ (ty : A.typ) : unionfind_typ =
  let ty' =
    match Marked.unmark ty with
    | A.TLit l -> TLit l
    | A.TArrow (t1, t2) -> TArrow (ast_to_typ t1, ast_to_typ t2)
    | A.TTuple ts -> TTuple (List.map ast_to_typ ts)
    | A.TStruct s -> TStruct s
    | A.TEnum e -> TEnum e
    | A.TOption t -> TOption (ast_to_typ t)
    | A.TArray t -> TArray (ast_to_typ t)
    | A.TAny -> TAny (Any.fresh ())
  in
  UnionFind.make (Marked.same_mark_as ty' ty)

(** {1 Types and unification} *)

let typ_needs_parens (t : unionfind_typ) : bool =
  let t = UnionFind.get (UnionFind.find t) in
  match Marked.unmark t with TArrow _ | TArray _ -> true | _ -> false

let rec format_typ
    (ctx : A.decl_ctx)
    (fmt : Format.formatter)
    (naked_typ : unionfind_typ) : unit =
  let format_typ = format_typ ctx in
  let format_typ_with_parens (fmt : Format.formatter) (t : unionfind_typ) =
    if typ_needs_parens t then Format.fprintf fmt "(%a)" format_typ t
    else Format.fprintf fmt "%a" format_typ t
  in
  let naked_typ = UnionFind.get (UnionFind.find naked_typ) in
  match Marked.unmark naked_typ with
  | TLit l -> Format.fprintf fmt "%a" Print.tlit l
  | TTuple ts ->
    Format.fprintf fmt "@[<hov 2>(%a)]"
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt "@ *@ ")
         (fun fmt t -> Format.fprintf fmt "%a" format_typ t))
      ts
  | TStruct s -> Format.fprintf fmt "%a" A.StructName.format_t s
  | TEnum e -> Format.fprintf fmt "%a" A.EnumName.format_t e
  | TOption t ->
    Format.fprintf fmt "@[<hov 2>%a@ %s@]" format_typ_with_parens t "eoption"
  | TArrow (t1, t2) ->
    Format.fprintf fmt "@[<hov 2>%a →@ %a@]" format_typ_with_parens t1
      format_typ t2
  | TArray t1 -> (
    match Marked.unmark (UnionFind.get (UnionFind.find t1)) with
    | TAny _ when not !Cli.debug_flag -> Format.pp_print_string fmt "collection"
    | _ -> Format.fprintf fmt "@[collection@ %a@]" format_typ t1)
  | TAny v ->
    if !Cli.debug_flag then Format.fprintf fmt "<a%d>" (Any.hash v)
    else Format.pp_print_string fmt "<any>"

exception Type_error of A.any_expr * unionfind_typ * unionfind_typ

type mark = { pos : Pos.t; uf : unionfind_typ }

(** Raises an error if unification cannot be performed. The position annotation
    of the second [unionfind_typ] argument is propagated (unless it is [TAny]). *)
let rec unify
    (ctx : A.decl_ctx)
    (e : ('a, 'm A.mark) A.gexpr) (* used for error context *)
    (t1 : unionfind_typ)
    (t2 : unionfind_typ) : unit =
  let unify = unify ctx in
  (* Cli.debug_format "Unifying %a and %a" (format_typ ctx) t1 (format_typ ctx)
     t2; *)
  let t1_repr = UnionFind.get (UnionFind.find t1) in
  let t2_repr = UnionFind.get (UnionFind.find t2) in
  let raise_type_error () = raise (Type_error (A.AnyExpr e, t1, t2)) in
  let () =
    match Marked.unmark t1_repr, Marked.unmark t2_repr with
    | TLit tl1, TLit tl2 -> if tl1 <> tl2 then raise_type_error ()
    | TArrow (t11, t12), TArrow (t21, t22) ->
      unify e t12 t22;
      unify e t11 t21
    | TTuple ts1, TTuple ts2 ->
      if List.length ts1 = List.length ts2 then List.iter2 (unify e) ts1 ts2
      else raise_type_error ()
    | TStruct s1, TStruct s2 ->
      if not (A.StructName.equal s1 s2) then raise_type_error ()
    | TEnum e1, TEnum e2 ->
      if not (A.EnumName.equal e1 e2) then raise_type_error ()
    | TOption t1, TOption t2 -> unify e t1 t2
    | TArray t1', TArray t2' -> unify e t1' t2'
    | TAny _, _ | _, TAny _ -> ()
    | ( ( TLit _ | TArrow _ | TTuple _ | TStruct _ | TEnum _ | TOption _
        | TArray _ ),
        _ ) ->
      raise_type_error ()
  in
  ignore
  @@ UnionFind.merge
       (fun t1 t2 -> match Marked.unmark t2 with TAny _ -> t1 | _ -> t2)
       t1 t2

let handle_type_error ctx e t1 t2 =
  (* TODO: if we get weird error messages, then it means that we should use the
     persistent version of the union-find data structure. *)
  let pos =
    match e with
    | A.AnyExpr e -> (
      match Marked.get_mark e with Untyped { pos } | Typed { pos; _ } -> pos)
  in
  let t1_repr = UnionFind.get (UnionFind.find t1) in
  let t2_repr = UnionFind.get (UnionFind.find t2) in
  let t1_pos = Marked.get_mark t1_repr in
  let t2_pos = Marked.get_mark t2_repr in
  let unformat_typ typ =
    let buf = Buffer.create 59 in
    let ppf = Format.formatter_of_buffer buf in
    (* set infinite width to disable line cuts *)
    Format.pp_set_margin ppf max_int;
    format_typ ctx ppf typ;
    Format.pp_print_flush ppf ();
    Buffer.contents buf
  in
  let t1_s fmt () =
    Cli.format_with_style [ANSITerminal.yellow] fmt (unformat_typ t1)
  in
  let t2_s fmt () =
    Cli.format_with_style [ANSITerminal.yellow] fmt (unformat_typ t2)
  in
  Errors.raise_multispanned_error
    [
      ( Some
          (Format.asprintf
             "Error coming from typechecking the following expression:"),
        pos );
      Some (Format.asprintf "Type %a coming from expression:" t1_s ()), t1_pos;
      Some (Format.asprintf "Type %a coming from expression:" t2_s ()), t2_pos;
    ]
    "Error during typechecking, incompatible types:\n%a %a\n%a %a"
    (Cli.format_with_style [ANSITerminal.blue; ANSITerminal.Bold])
    "-->" t1_s ()
    (Cli.format_with_style [ANSITerminal.blue; ANSITerminal.Bold])
    "-->" t2_s ()

let lit_type (type a) (lit : a A.glit) : naked_typ =
  match lit with
  | LBool _ -> TLit TBool
  | LInt _ -> TLit TInt
  | LRat _ -> TLit TRat
  | LMoney _ -> TLit TMoney
  | LDate _ -> TLit TDate
  | LDuration _ -> TLit TDuration
  | LUnit -> TLit TUnit
  | LEmptyError -> TAny (Any.fresh ())

(** Operators have a single type, instead of being polymorphic with constraints.
    This allows us to have a simpler type system, while we argue the syntactic
    burden of operator annotations helps the programmer visualize the type flow
    in the code. *)
let op_type (op : 'a A.operator Marked.pos) : unionfind_typ =
  let pos = Marked.get_mark op in
  let bt = UnionFind.make (TLit TBool, pos) in
  let it = UnionFind.make (TLit TInt, pos) in
  let rt = UnionFind.make (TLit TRat, pos) in
  let mt = UnionFind.make (TLit TMoney, pos) in
  let dut = UnionFind.make (TLit TDuration, pos) in
  let dat = UnionFind.make (TLit TDate, pos) in
  let any = UnionFind.make (TAny (Any.fresh ()), pos) in
  let array_any = UnionFind.make (TArray any, pos) in
  let any2 = UnionFind.make (TAny (Any.fresh ()), pos) in
  let array_any2 = UnionFind.make (TArray any2, pos) in
  let arr x y = UnionFind.make (TArrow (x, y), pos) in
  match Marked.unmark op with
  | A.Ternop A.Fold ->
    arr (arr any2 (arr any any2)) (arr any2 (arr array_any any2))
  | A.Binop (A.And | A.Or | A.Xor) -> arr bt (arr bt bt)
  | A.Binop (A.Add KInt | A.Sub KInt | A.Mult KInt | A.Div KInt) ->
    arr it (arr it it)
  | A.Binop (A.Add KRat | A.Sub KRat | A.Mult KRat | A.Div KRat) ->
    arr rt (arr rt rt)
  | A.Binop (A.Add KMoney | A.Sub KMoney) -> arr mt (arr mt mt)
  | A.Binop (A.Add KDuration | A.Sub KDuration) -> arr dut (arr dut dut)
  | A.Binop (A.Sub KDate) -> arr dat (arr dat dut)
  | A.Binop (A.Add KDate) -> arr dat (arr dut dat)
  | A.Binop (A.Mult KDuration) -> arr dut (arr it dut)
  | A.Binop (A.Div KMoney) -> arr mt (arr mt rt)
  | A.Binop (A.Mult KMoney) -> arr mt (arr rt mt)
  | A.Binop (A.Lt KInt | A.Lte KInt | A.Gt KInt | A.Gte KInt) ->
    arr it (arr it bt)
  | A.Binop (A.Lt KRat | A.Lte KRat | A.Gt KRat | A.Gte KRat) ->
    arr rt (arr rt bt)
  | A.Binop (A.Lt KMoney | A.Lte KMoney | A.Gt KMoney | A.Gte KMoney) ->
    arr mt (arr mt bt)
  | A.Binop (A.Lt KDate | A.Lte KDate | A.Gt KDate | A.Gte KDate) ->
    arr dat (arr dat bt)
  | A.Binop (A.Lt KDuration | A.Lte KDuration | A.Gt KDuration | A.Gte KDuration)
    ->
    arr dut (arr dut bt)
  | A.Binop (A.Eq | A.Neq) -> arr any (arr any bt)
  | A.Binop A.Map -> arr (arr any any2) (arr array_any array_any2)
  | A.Binop A.Filter -> arr (arr any bt) (arr array_any array_any)
  | A.Binop A.Concat -> arr array_any (arr array_any array_any)
  | A.Unop (A.Minus KInt) -> arr it it
  | A.Unop (A.Minus KRat) -> arr rt rt
  | A.Unop (A.Minus KMoney) -> arr mt mt
  | A.Unop (A.Minus KDuration) -> arr dut dut
  | A.Unop A.Not -> arr bt bt
  | A.Unop (A.Log (A.PosRecordIfTrueBool, _)) -> arr bt bt
  | A.Unop (A.Log _) -> arr any any
  | A.Unop A.Length -> arr array_any it
  | A.Unop A.GetDay -> arr dat it
  | A.Unop A.GetMonth -> arr dat it
  | A.Unop A.GetYear -> arr dat it
  | A.Unop A.FirstDayOfMonth -> arr dat dat
  | A.Unop A.LastDayOfMonth -> arr dat dat
  | A.Unop A.RoundMoney -> arr mt mt
  | A.Unop A.RoundDecimal -> arr rt rt
  | A.Unop A.IntToRat -> arr it rt
  | A.Unop A.MoneyToRat -> arr mt rt
  | A.Unop A.RatToMoney -> arr rt mt
  | Binop (Mult KDate) | Binop (Div (KDate | KDuration)) | Unop (Minus KDate) ->
    Errors.raise_spanned_error pos "This operator is not available!"

(** {1 Double-directed typing} *)

module Env = struct
  type 'e t = {
    vars : ('e, unionfind_typ) Var.Map.t;
    scope_vars : A.typ A.ScopeVar.Map.t;
    scopes : A.typ A.ScopeVar.Map.t A.ScopeName.Map.t;
  }

  let empty =
    {
      vars = Var.Map.empty;
      scope_vars = A.ScopeVar.Map.empty;
      scopes = A.ScopeName.Map.empty;
    }

  let get t v = Var.Map.find_opt v t.vars
  let get_scope_var t sv = A.ScopeVar.Map.find_opt sv t.scope_vars

  let get_subscope_out_var t scope var =
    Option.bind (A.ScopeName.Map.find_opt scope t.scopes) (fun vmap ->
        A.ScopeVar.Map.find_opt var vmap)

  let add v tau t = { t with vars = Var.Map.add v tau t.vars }
  let add_var v typ t = add v (ast_to_typ typ) t

  let add_scope_var v typ t =
    { t with scope_vars = A.ScopeVar.Map.add v typ t.scope_vars }

  let add_scope scope_name ~vars t =
    { t with scopes = A.ScopeName.Map.add scope_name vars t.scopes }

  let open_scope scope_name t =
    let scope_vars =
      A.ScopeVar.Map.union
        (fun _ _ -> assert false)
        t.scope_vars
        (A.ScopeName.Map.find scope_name t.scopes)
    in
    { t with scope_vars }
end

let add_pos e ty = Marked.mark (Expr.pos e) ty
let ty (_, { uf; _ }) = uf

(** Infers the most permissive type from an expression *)
let rec typecheck_expr_bottom_up :
    type a m.
    A.decl_ctx ->
    (a, m A.mark) A.gexpr Env.t ->
    (a, m A.mark) A.gexpr ->
    (a, mark) A.boxed_gexpr =
 fun ctx env e ->
  typecheck_expr_top_down ctx env
    (UnionFind.make (add_pos e (TAny (Any.fresh ()))))
    e

(** Checks whether the expression can be typed with the provided type *)
and typecheck_expr_top_down :
    type a m.
    A.decl_ctx ->
    (a, m A.mark) A.gexpr Env.t ->
    unionfind_typ ->
    (a, m A.mark) A.gexpr ->
    (a, mark) A.boxed_gexpr =
 fun ctx env tau e ->
  (* Cli.debug_format "Propagating type %a for naked_expr %a" (format_typ ctx)
     tau (Expr.format ctx) e; *)
  let pos_e = Expr.pos e in
  let () =
    (* If there already is a type annotation on the given expr, ensure it
       matches *)
    match Marked.get_mark e with
    | A.Untyped _ | A.Typed { A.ty = A.TAny, _; _ } -> ()
    | A.Typed { A.ty; _ } -> unify ctx e tau (ast_to_typ ty)
  in
  let context_mark = { uf = tau; pos = pos_e } in
  let uf_mark uf =
    (* Unify with the supplied type first, and return the mark *)
    unify ctx e uf tau;
    { uf; pos = pos_e }
  in
  let unionfind ?(pos = e) t = UnionFind.make (add_pos pos t) in
  let ty_mark ty = uf_mark (unionfind ty) in
  match Marked.unmark e with
  | A.ELocation loc ->
    let ty_opt =
      match loc with
      | DesugaredScopeVar (v, _) | ScopelangScopeVar v ->
        Env.get_scope_var env (Marked.unmark v)
      | SubScopeVar (scope, _, v) ->
        Env.get_subscope_out_var env scope (Marked.unmark v)
    in
    let ty =
      match ty_opt with
      | Some ty -> ty
      | None ->
        Errors.raise_spanned_error pos_e "Reference to %a not found"
          (Expr.format ctx) e
    in
    Expr.elocation loc (uf_mark (ast_to_typ ty))
  | A.EStruct { name; fields } ->
    let mark = ty_mark (TStruct name) in
    let str = A.StructName.Map.find name ctx.A.ctx_structs in
    let _check_fields : unit =
      let missing_fields, extra_fields =
        A.StructField.Map.fold
          (fun fld x (remaining, extra) ->
            if A.StructField.Map.mem fld remaining then
              A.StructField.Map.remove fld remaining, extra
            else remaining, A.StructField.Map.add fld x extra)
          fields
          (str, A.StructField.Map.empty)
      in
      let errs =
        List.map
          (fun (f, ty) ->
            ( Some (Format.asprintf "Missing field %a" A.StructField.format_t f),
              Marked.get_mark ty ))
          (A.StructField.Map.bindings missing_fields)
        @ List.map
            (fun (f, ef) ->
              let dup = A.StructField.Map.mem f str in
              ( Some
                  (Format.asprintf "%s field %a"
                     (if dup then "Duplicate" else "Unknown")
                     A.StructField.format_t f),
                Expr.pos ef ))
            (A.StructField.Map.bindings extra_fields)
      in
      if errs <> [] then
        Errors.raise_multispanned_error errs
          "Mismatching field definitions for structure %a" A.StructName.format_t
          name
    in
    let fields' =
      A.StructField.Map.mapi
        (fun f_name f_e ->
          let f_ty = A.StructField.Map.find f_name str in
          typecheck_expr_top_down ctx env (ast_to_typ f_ty) f_e)
        fields
    in
    Expr.estruct name fields' mark
  | A.EDStructAccess { e = e_struct; name_opt; field } ->
    let t_struct =
      match name_opt with
      | Some name -> TStruct name
      | None -> TAny (Any.fresh ())
    in
    let e_struct' =
      typecheck_expr_top_down ctx env (unionfind t_struct) e_struct
    in
    let name =
      match UnionFind.get (ty e_struct') with
      | TStruct name, _ -> name
      | TAny _, _ ->
        Printf.ksprintf failwith
          "Disambiguation failed before reaching field %s" field
      | _ ->
        Errors.raise_spanned_error (Expr.pos e)
          "This is not a structure, cannot access field %s (%a)" field
          (format_typ ctx) (ty e_struct')
    in
    let fld_ty =
      let str =
        try A.StructName.Map.find name ctx.A.ctx_structs
        with Not_found ->
          Errors.raise_spanned_error pos_e "No structure %a found"
            A.StructName.format_t name
      in
      let field =
        try
          A.StructName.Map.find name
            (A.IdentName.Map.find field ctx.ctx_struct_fields)
        with Not_found ->
          Errors.raise_spanned_error context_mark.pos
            "Field %s does not belong to structure %a" field
            A.StructName.format_t name
      in
      A.StructField.Map.find field str
    in
    let mark = uf_mark (ast_to_typ fld_ty) in
    Expr.edstructaccess e_struct' field (Some name) mark
  | A.EStructAccess { e = e_struct; name; field } ->
    let fld_ty =
      let str =
        try A.StructName.Map.find name ctx.A.ctx_structs
        with Not_found ->
          Errors.raise_spanned_error pos_e "No structure %a found"
            A.StructName.format_t name
      in
      try A.StructField.Map.find field str
      with Not_found ->
        Errors.raise_multispanned_error
          [
            None, pos_e;
            ( Some "Structure %a declared here",
              Marked.get_mark (A.StructName.get_info name) );
          ]
          "Structure %a doesn't define a field %a" A.StructName.format_t name
          A.StructField.format_t field
    in
    let mark = uf_mark (ast_to_typ fld_ty) in
    let e_struct' =
      typecheck_expr_top_down ctx env (unionfind (TStruct name)) e_struct
    in
    Expr.estructaccess e_struct' field name mark
  | A.EInj { name; cons; e = e_enum } ->
    let mark = uf_mark (unionfind (TEnum name)) in
    let e_enum' =
      typecheck_expr_top_down ctx env
        (ast_to_typ
           (A.EnumConstructor.Map.find cons
              (A.EnumName.Map.find name ctx.A.ctx_enums)))
        e_enum
    in
    Expr.einj e_enum' cons name mark
  | A.EMatch { e = e1; name; cases } ->
    let cases_ty = A.EnumName.Map.find name ctx.A.ctx_enums in
    let t_ret = unionfind ~pos:e1 (TAny (Any.fresh ())) in
    let mark = uf_mark t_ret in
    let e1' = typecheck_expr_top_down ctx env (unionfind (TEnum name)) e1 in
    let cases' =
      A.EnumConstructor.Map.mapi
        (fun c_name e ->
          let c_ty = A.EnumConstructor.Map.find c_name cases_ty in
          let e_ty = unionfind ~pos:e (TArrow (ast_to_typ c_ty, t_ret)) in
          typecheck_expr_top_down ctx env e_ty e)
        cases
    in
    Expr.ematch e1' name cases' mark
  | A.EScopeCall { scope; args } ->
    let scope_out_struct =
      (A.ScopeName.Map.find scope ctx.ctx_scopes).out_struct_name
    in
    let mark = uf_mark (unionfind (TStruct scope_out_struct)) in
    let vars = A.ScopeName.Map.find scope env.scopes in
    let args' =
      A.ScopeVar.Map.mapi
        (fun name ->
          typecheck_expr_top_down ctx env
            (ast_to_typ (A.ScopeVar.Map.find name vars)))
        args
    in
    Expr.escopecall scope args' mark
  | A.ERaise ex -> Expr.eraise ex context_mark
  | A.ECatch { body; exn; handler } ->
    let body' = typecheck_expr_top_down ctx env tau body in
    let handler' = typecheck_expr_top_down ctx env tau handler in
    Expr.ecatch body' exn handler' context_mark
  | A.EVar v ->
    let tau' =
      match Env.get env v with
      | Some t -> t
      | None ->
        Errors.raise_spanned_error pos_e
          "Variable %s not found in the current context" (Bindlib.name_of v)
    in
    Expr.evar (Var.translate v) (uf_mark tau')
  | A.ELit lit -> Expr.elit lit (ty_mark (lit_type lit))
  | A.ETuple es ->
    let tys = List.map (fun _ -> unionfind (TAny (Any.fresh ()))) es in
    let mark = uf_mark (unionfind (TTuple tys)) in
    let es' = List.map2 (typecheck_expr_top_down ctx env) tys es in
    Expr.etuple es' mark
  | A.ETupleAccess { e = e1; index; size } ->
    if index >= size then
      Errors.raise_spanned_error (Expr.pos e)
        "Tuple access out of bounds (%d/%d)" index size;
    let tuple_ty =
      TTuple
        (List.init size (fun n ->
             if n = index then tau else unionfind ~pos:e1 (TAny (Any.fresh ()))))
    in
    let e1' = typecheck_expr_top_down ctx env (unionfind ~pos:e1 tuple_ty) e1 in
    Expr.etupleaccess e1' index size context_mark
  | A.EAbs { binder; tys = t_args } ->
    if Bindlib.mbinder_arity binder <> List.length t_args then
      Errors.raise_spanned_error (Expr.pos e)
        "function has %d variables but was supplied %d types"
        (Bindlib.mbinder_arity binder)
        (List.length t_args)
    else
      let tau_args = List.map ast_to_typ t_args in
      let t_ret = unionfind (TAny (Any.fresh ())) in
      let t_func =
        List.fold_right
          (fun t_arg acc -> unionfind (TArrow (t_arg, acc)))
          tau_args t_ret
      in
      let mark = uf_mark t_func in
      assert (List.for_all all_resolved tau_args);
      let xs, body = Bindlib.unmbind binder in
      let xs' = Array.map Var.translate xs in
      let env =
        List.fold_left2
          (fun env x tau_arg -> Env.add x tau_arg env)
          env (Array.to_list xs) tau_args
      in
      let body' = typecheck_expr_top_down ctx env t_ret body in
      let binder' = Bindlib.bind_mvar xs' (Expr.Box.lift body') in
      Expr.eabs binder' (List.map typ_to_ast tau_args) mark
  | A.EApp { f = (EOp _, _) as e1; args } ->
    (* Same as EApp, but the typing order is different to help with
       disambiguation: - type of the operator is extracted first (to figure
       linked type vars between arguments) - arguments are typed right-to-left,
       because our operators with function args always have the functions first,
       and the argument types of those functions can always be inferred from the
       later operator arguments *)
    let t_args = List.map (fun _ -> unionfind (TAny (Any.fresh ()))) args in
    let t_func =
      List.fold_right
        (fun t_arg acc -> unionfind (TArrow (t_arg, acc)))
        t_args tau
    in
    let e1' = typecheck_expr_top_down ctx env t_func e1 in
    let args' =
      List.rev_map2
        (typecheck_expr_top_down ctx env)
        (List.rev t_args) (List.rev args)
    in
    Expr.eapp e1' args' context_mark
  | A.EApp { f = e1; args } ->
    (* Here we type the arguments first (in order), to ensure we know the types
       of the arguments if [f] is [EAbs] before disambiguation. This is also the
       right order for the [let-in] form. *)
    let t_args = List.map (fun _ -> unionfind (TAny (Any.fresh ()))) args in
    let t_func =
      List.fold_right
        (fun t_arg acc -> unionfind (TArrow (t_arg, acc)))
        t_args tau
    in
    let args' = List.map2 (typecheck_expr_top_down ctx env) t_args args in
    let e1' = typecheck_expr_top_down ctx env t_func e1 in
    Expr.eapp e1' args' context_mark
  | A.EOp op -> Expr.eop op (uf_mark (op_type (Marked.mark pos_e op)))
  | A.EDefault { excepts; just; cons } ->
    let cons' = typecheck_expr_top_down ctx env tau cons in
    let just' =
      typecheck_expr_top_down ctx env (unionfind ~pos:just (TLit TBool)) just
    in
    let excepts' = List.map (typecheck_expr_top_down ctx env tau) excepts in
    Expr.edefault excepts' just' cons' context_mark
  | A.EIfThenElse { cond; etrue = et; efalse = ef } ->
    let et' = typecheck_expr_top_down ctx env tau et in
    let ef' = typecheck_expr_top_down ctx env tau ef in
    let cond' =
      typecheck_expr_top_down ctx env (unionfind ~pos:cond (TLit TBool)) cond
    in
    Expr.eifthenelse cond' et' ef' context_mark
  | A.EAssert e1 ->
    let mark = uf_mark (unionfind (TLit TUnit)) in
    let e1' =
      typecheck_expr_top_down ctx env (unionfind ~pos:e1 (TLit TBool)) e1
    in
    Expr.eassert e1' mark
  | A.EErrorOnEmpty e1 ->
    let e1' = typecheck_expr_top_down ctx env tau e1 in
    Expr.eerroronempty e1' context_mark
  | A.EArray es ->
    let cell_type = unionfind (TAny (Any.fresh ())) in
    let mark = uf_mark (unionfind (TArray cell_type)) in
    let es' = List.map (typecheck_expr_top_down ctx env cell_type) es in
    Expr.earray es' mark

let wrap ctx f e =
  try f e
  with Type_error (e, ty1, ty2) -> (
    let bt = Printexc.get_raw_backtrace () in
    try handle_type_error ctx e ty1 ty2
    with e -> Printexc.raise_with_backtrace e bt)

let wrap_expr ctx f e =
  (* We need to unbox here, because the typing may otherwise be stored in
     Bindlib closures and not yet applied, and would escape the `try..with` *)
  wrap ctx (fun e -> Expr.unbox (f e)) e

(** {1 API} *)

let get_ty_mark { uf; pos } = A.Typed { ty = typ_to_ast uf; pos }

let expr_raw
    (type a)
    (ctx : A.decl_ctx)
    ?(env = Env.empty)
    ?(typ : A.typ option)
    (e : (a, 'm) A.gexpr) : (a, mark) A.gexpr =
  let fty =
    match typ with
    | None -> typecheck_expr_bottom_up ctx env
    | Some typ -> typecheck_expr_top_down ctx env (ast_to_typ typ)
  in
  wrap_expr ctx fty e

let check_expr ctx ?env ?typ e =
  Expr.map_marks
    ~f:(fun { pos; _ } -> A.Untyped { pos })
    (expr_raw ctx ?env ?typ e)

(* Infer the type of an expression *)
let expr ctx ?env ?typ e =
  Expr.map_marks ~f:get_ty_mark (expr_raw ctx ?env ?typ e)

let rec scope_body_expr ctx env ty_out body_expr =
  match body_expr with
  | A.Result e ->
    let e' = wrap_expr ctx (typecheck_expr_top_down ctx env ty_out) e in
    let e' = Expr.map_marks ~f:get_ty_mark e' in
    Bindlib.box_apply (fun e -> A.Result e) (Expr.Box.lift e')
  | A.ScopeLet
      {
        scope_let_kind;
        scope_let_typ;
        scope_let_expr = e0;
        scope_let_next;
        scope_let_pos;
      } ->
    let ty_e = ast_to_typ scope_let_typ in
    let e = wrap_expr ctx (typecheck_expr_bottom_up ctx env) e0 in
    wrap ctx (fun t -> unify ctx e0 (ty e) t) ty_e;
    (* We could use [typecheck_expr_top_down] rather than this manual
       unification, but we get better messages with this order of the [unify]
       parameters, which keeps location of the type as defined instead of as
       inferred. *)
    let var, next = Bindlib.unbind scope_let_next in
    let env = Env.add var ty_e env in
    let next = scope_body_expr ctx env ty_out next in
    let scope_let_next = Bindlib.bind_var (Var.translate var) next in
    Bindlib.box_apply2
      (fun scope_let_expr scope_let_next ->
        A.ScopeLet
          {
            scope_let_kind;
            scope_let_typ;
            scope_let_expr;
            scope_let_next;
            scope_let_pos;
          })
      (Expr.Box.lift (Expr.map_marks ~f:get_ty_mark e))
      scope_let_next

let scope_body ctx env body =
  let get_pos struct_name =
    Marked.get_mark (A.StructName.get_info struct_name)
  in
  let struct_ty struct_name =
    UnionFind.make (Marked.mark (get_pos struct_name) (TStruct struct_name))
  in
  let ty_in = struct_ty body.A.scope_body_input_struct in
  let ty_out = struct_ty body.A.scope_body_output_struct in
  let var, e = Bindlib.unbind body.A.scope_body_expr in
  let env = Env.add var ty_in env in
  let e' = scope_body_expr ctx env ty_out e in
  ( Bindlib.bind_var (Var.translate var) e',
    UnionFind.make
      (Marked.mark
         (get_pos body.A.scope_body_output_struct)
         (TArrow (ty_in, ty_out))) )

let rec scopes ctx env = function
  | A.Nil -> Bindlib.box A.Nil
  | A.ScopeDef def ->
    let body_e, ty_scope = scope_body ctx env def.scope_body in
    let scope_next =
      let scope_var, next = Bindlib.unbind def.scope_next in
      let env = Env.add scope_var ty_scope env in
      let next' = scopes ctx env next in
      Bindlib.bind_var (Var.translate scope_var) next'
    in
    Bindlib.box_apply2
      (fun scope_body_expr scope_next ->
        A.ScopeDef
          {
            def with
            scope_body = { def.scope_body with scope_body_expr };
            scope_next;
          })
      body_e scope_next

let program prg =
  let scopes = Bindlib.unbox (scopes prg.A.decl_ctx Env.empty prg.A.scopes) in
  { prg with scopes }

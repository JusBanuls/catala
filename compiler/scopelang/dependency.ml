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

(** Graph representation of the dependencies between scopes in the Catala
    program. Vertices are functions, x -> y if x is used in the definition of y. *)

open Catala_utils
open Shared_ast
module SVertex = ScopeName

(** On the edges, the label is the expression responsible for the use of the
    function *)
module SEdge = struct
  type t = Pos.t

  let compare = compare
  let default = Pos.no_pos
end

module SDependencies =
  Graph.Persistent.Digraph.ConcreteBidirectionalLabeled (SVertex) (SEdge)

module STopologicalTraversal = Graph.Topological.Make (SDependencies)

module SSCC = Graph.Components.Make (SDependencies)
(** Tarjan's stongly connected components algorithm, provided by OCamlGraph *)

let rec expr_used_scopes e =
  let recurse_subterms e =
    Expr.shallow_fold
      (fun e -> ScopeName.Map.union (fun _ x _ -> Some x) (expr_used_scopes e))
      e ScopeName.Map.empty
  in
  match e with
  | (EScopeCall { scope; _ }, m) as e ->
    ScopeName.Map.add scope (Expr.mark_pos m) (recurse_subterms e)
  | EAbs { binder; _ }, _ ->
    let _, body = Bindlib.unmbind binder in
    expr_used_scopes body
  | e -> recurse_subterms e

let rule_used_scopes = function
  | Ast.Assertion e | Ast.Definition (_, _, _, e) ->
    (* TODO: maybe this info could be passed on from previous passes without
       walking through all exprs again *)
    expr_used_scopes e
  | Ast.Call (subscope, subindex, _) ->
    ScopeName.Map.singleton subscope
      (Marked.get_mark (SubScopeName.get_info subindex))

let build_program_dep_graph (prgm : 'm Ast.program) : SDependencies.t =
  let g = SDependencies.empty in
  let g =
    ScopeName.Map.fold
      (fun v _ g -> SDependencies.add_vertex g v)
      prgm.program_scopes g
  in
  ScopeName.Map.fold
    (fun scope_name scope g ->
      List.fold_left
        (fun g rule ->
          let used_scopes = rule_used_scopes rule in
          if ScopeName.Map.mem scope_name used_scopes then
            Errors.raise_spanned_error
              (Marked.get_mark (ScopeName.get_info scope.Ast.scope_decl_name))
              "The scope %a is calling into itself as a subscope, which is \
               forbidden since Catala does not provide recursion"
              ScopeName.format_t scope.Ast.scope_decl_name;
          ScopeName.Map.fold
            (fun used_scope pos g ->
              let edge = SDependencies.E.create used_scope pos scope_name in
              SDependencies.add_edge_e g edge)
            used_scopes g)
        g scope.Ast.scope_decl_rules)
    prgm.program_scopes g

let check_for_cycle_in_scope (g : SDependencies.t) : unit =
  (* if there is a cycle, there will be an strongly connected component of
     cardinality > 1 *)
  let sccs = SSCC.scc_list g in
  if List.length sccs < SDependencies.nb_vertex g then
    let scc = List.find (fun scc -> List.length scc > 1) sccs in
    let spans =
      List.flatten
        (List.map
           (fun v ->
             let var_str, var_info =
               Format.asprintf "%a" ScopeName.format_t v, ScopeName.get_info v
             in
             let succs = SDependencies.succ_e g v in
             let _, edge_pos, succ =
               List.find (fun (_, _, succ) -> List.mem succ scc) succs
             in
             let succ_str = Format.asprintf "%a" ScopeName.format_t succ in
             [
               ( Some ("Cycle variable " ^ var_str ^ ", declared:"),
                 Marked.get_mark var_info );
               ( Some
                   ("Used here in the definition of another cycle variable "
                   ^ succ_str
                   ^ ":"),
                 edge_pos );
             ])
           scc)
    in
    Errors.raise_multispanned_error spans
      "Cyclic dependency detected between scopes!"

let get_scope_ordering (g : SDependencies.t) : ScopeName.t list =
  List.rev (STopologicalTraversal.fold (fun sd acc -> sd :: acc) g [])

module TVertex = struct
  type t = Struct of StructName.t | Enum of EnumName.t

  let hash x =
    match x with Struct x -> StructName.hash x | Enum x -> EnumName.hash x

  let compare x y =
    match x, y with
    | Struct x, Struct y -> StructName.compare x y
    | Enum x, Enum y -> EnumName.compare x y
    | Struct _, Enum _ -> 1
    | Enum _, Struct _ -> -1

  let equal x y =
    match x, y with
    | Struct x, Struct y -> StructName.compare x y = 0
    | Enum x, Enum y -> EnumName.compare x y = 0
    | _ -> false

  let format_t (fmt : Format.formatter) (x : t) : unit =
    match x with
    | Struct x -> StructName.format_t fmt x
    | Enum x -> EnumName.format_t fmt x

  let get_info (x : t) =
    match x with
    | Struct x -> StructName.get_info x
    | Enum x -> EnumName.get_info x
end

module TVertexSet = Set.Make (TVertex)

(** On the edges, the label is the expression responsible for the use of the
    function *)
module TEdge = struct
  type t = Pos.t

  let compare = compare
  let default = Pos.no_pos
end

module TDependencies =
  Graph.Persistent.Digraph.ConcreteBidirectionalLabeled (TVertex) (TEdge)

module TTopologicalTraversal = Graph.Topological.Make (TDependencies)

module TSCC = Graph.Components.Make (TDependencies)
(** Tarjan's stongly connected components algorithm, provided by OCamlGraph *)

let rec get_structs_or_enums_in_type (t : typ) : TVertexSet.t =
  match Marked.unmark t with
  | TStruct s -> TVertexSet.singleton (TVertex.Struct s)
  | TEnum e -> TVertexSet.singleton (TVertex.Enum e)
  | TArrow (t1, t2) ->
    TVertexSet.union
      (get_structs_or_enums_in_type t1)
      (get_structs_or_enums_in_type t2)
  | TLit _ | TAny -> TVertexSet.empty
  | TOption t1 | TArray t1 -> get_structs_or_enums_in_type t1
  | TTuple ts ->
    List.fold_left
      (fun acc t -> TVertexSet.union acc (get_structs_or_enums_in_type t))
      TVertexSet.empty ts

let build_type_graph (structs : struct_ctx) (enums : enum_ctx) : TDependencies.t
    =
  let g = TDependencies.empty in
  let g =
    StructName.Map.fold
      (fun s fields g ->
        StructField.Map.fold
          (fun _ typ g ->
            let def = TVertex.Struct s in
            let g = TDependencies.add_vertex g def in
            let used = get_structs_or_enums_in_type typ in
            TVertexSet.fold
              (fun used g ->
                if TVertex.equal used def then
                  Errors.raise_spanned_error (Marked.get_mark typ)
                    "The type %a is defined using itself, which is forbidden \
                     since Catala does not provide recursive types"
                    TVertex.format_t used
                else
                  let edge =
                    TDependencies.E.create used (Marked.get_mark typ) def
                  in
                  TDependencies.add_edge_e g edge)
              used g)
          fields g)
      structs g
  in
  let g =
    EnumName.Map.fold
      (fun e cases g ->
        EnumConstructor.Map.fold
          (fun _ typ g ->
            let def = TVertex.Enum e in
            let g = TDependencies.add_vertex g def in
            let used = get_structs_or_enums_in_type typ in
            TVertexSet.fold
              (fun used g ->
                if TVertex.equal used def then
                  Errors.raise_spanned_error (Marked.get_mark typ)
                    "The type %a is defined using itself, which is forbidden \
                     since Catala does not provide recursive types"
                    TVertex.format_t used
                else
                  let edge =
                    TDependencies.E.create used (Marked.get_mark typ) def
                  in
                  TDependencies.add_edge_e g edge)
              used g)
          cases g)
      enums g
  in
  g

let check_type_cycles (structs : struct_ctx) (enums : enum_ctx) : TVertex.t list
    =
  let g = build_type_graph structs enums in
  (* if there is a cycle, there will be an strongly connected component of
     cardinality > 1 *)
  let sccs = TSCC.scc_list g in
  (if List.length sccs < TDependencies.nb_vertex g then
   let scc = List.find (fun scc -> List.length scc > 1) sccs in
   let spans =
     List.flatten
       (List.map
          (fun v ->
            let var_str, var_info =
              Format.asprintf "%a" TVertex.format_t v, TVertex.get_info v
            in
            let succs = TDependencies.succ_e g v in
            let _, edge_pos, succ =
              List.find (fun (_, _, succ) -> List.mem succ scc) succs
            in
            let succ_str = Format.asprintf "%a" TVertex.format_t succ in
            [
              ( Some ("Cycle type " ^ var_str ^ ", declared:"),
                Marked.get_mark var_info );
              ( Some
                  ("Used here in the definition of another cycle type "
                  ^ succ_str
                  ^ ":"),
                edge_pos );
            ])
          scc)
   in
   Errors.raise_multispanned_error spans
     "Cyclic dependency detected between types!");
  List.rev (TTopologicalTraversal.fold (fun v acc -> v :: acc) g [])

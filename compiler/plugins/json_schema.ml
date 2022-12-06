(* This file is part of the Catala compiler, a specification language for tax
   and social benefits computation rules. Copyright (C) 2020 Inria,
   contributors: Emile Rolley <emile.rolley@tuta.io>.

   Licensed under the Apache License, Version 2.0 (the "License"); you may not
   use this file except in compliance with the License. You may obtain a copy of
   the License at

   http://www.apache.org/licenses/LICENSE-2.0

   Unless required by applicable law or agreed to in writing, software
   distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
   WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
   License for the specific language governing permissions and limitations under
   the License. *)

(** Catala plugin for generating {{:https://json-schema.org} JSON schemas} used
    to build forms for the Catala website. *)

let name = "json_schema"
let extension = "_schema.json"

open Catala_utils
open Shared_ast
open Lcalc.Ast
open Lcalc.To_ocaml
module D = Dcalc.Ast

(** Contains all format functions used to format a Lcalc Catala program
    representation to a JSON schema describing the corresponding web form. *)
module To_json = struct
  let to_camel_case (s : string) : string =
    String.split_on_char '_' s
    |> (function
         | hd :: tl -> hd :: List.map String.capitalize_ascii tl | l -> l)
    |> String.concat ""

  let format_struct_field_name_camel_case
      (fmt : Format.formatter)
      (v : StructField.t) : unit =
    let s =
      Format.asprintf "%a" StructField.format_t v
      |> String.to_ascii
      |> String.to_snake_case
      |> avoid_keywords
      |> to_camel_case
    in
    Format.fprintf fmt "%s" s

  let rec find_scope_def (target_name : string) :
      'm expr scopes -> 'm expr scope_def option = function
    | Nil -> None
    | ScopeDef scope_def ->
      let name = Format.asprintf "%a" ScopeName.format_t scope_def.scope_name in
      if name = target_name then Some scope_def
      else
        let _, next_scope = Bindlib.unbind scope_def.scope_next in
        find_scope_def target_name next_scope

  let fmt_tlit fmt (tlit : typ_lit) =
    match tlit with
    | TUnit -> Format.fprintf fmt "\"type\": \"null\",@\n\"default\": null"
    | TInt | TRat -> Format.fprintf fmt "\"type\": \"number\",@\n\"default\": 0"
    | TMoney ->
      Format.fprintf fmt
        "\"type\": \"number\",@\n\"minimum\": 0,@\n\"default\": 0"
    | TBool -> Format.fprintf fmt "\"type\": \"boolean\",@\n\"default\": false"
    | TDate -> Format.fprintf fmt "\"type\": \"string\",@\n\"format\": \"date\""
    | TDuration -> failwith "TODO: tlit duration"

  let rec fmt_type fmt (typ : typ) =
    match Marked.unmark typ with
    | TLit tlit -> fmt_tlit fmt tlit
    | TStruct sname ->
      Format.fprintf fmt "\"$ref\": \"#/definitions/%a\"" format_struct_name
        sname
    | TEnum ename ->
      Format.fprintf fmt "\"$ref\": \"#/definitions/%a\"" format_enum_name ename
    | TArray t ->
      Format.fprintf fmt
        "\"type\": \"array\",@\n\
         \"default\": [],@\n\
         @[<hov 2>\"items\": {@\n\
         %a@]@\n\
         }"
        fmt_type t
    | _ -> ()

  let fmt_struct_properties
      (ctx : decl_ctx)
      (fmt : Format.formatter)
      (sname : StructName.t) =
    Format.fprintf fmt "%a"
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt ",@\n")
         (fun fmt (field_name, field_type) ->
           Format.fprintf fmt "@[<hov 2>\"%a\": {@\n%a@]@\n}"
             format_struct_field_name_camel_case field_name fmt_type field_type))
      (StructField.Map.bindings (find_struct sname ctx))

  let fmt_definitions
      (ctx : decl_ctx)
      (fmt : Format.formatter)
      (scope_def : 'e scope_def) =
    let get_name t =
      match Marked.unmark t with
      | TStruct sname -> Format.asprintf "%a" format_struct_name sname
      | TEnum ename -> Format.asprintf "%a" format_enum_name ename
      | _ -> failwith "unreachable: only structs and enums are collected."
    in
    let rec collect_required_type_defs_from_scope_input
        (input_struct : StructName.t) : typ list =
      let rec collect (acc : typ list) (t : typ) : typ list =
        match Marked.unmark t with
        | TStruct s ->
          (* Scope's input is a struct. *)
          (t :: acc) @ collect_required_type_defs_from_scope_input s
        | TEnum e ->
          List.fold_left collect (t :: acc)
            (List.map snd
               (EnumConstructor.Map.bindings
                  (EnumName.Map.find e ctx.ctx_enums)))
        | TArray t -> collect acc t
        | _ -> acc
      in
      find_struct input_struct ctx
      |> StructField.Map.bindings
      |> List.fold_left (fun acc (_, field_typ) -> collect acc field_typ) []
      |> List.sort_uniq (fun t t' -> String.compare (get_name t) (get_name t'))
    in
    let fmt_enum_properties fmt ename =
      let enum_def = find_enum ename ctx in
      Format.fprintf fmt
        "@[<hov 2>\"kind\": {@\n\
         \"type\": \"string\",@\n\
         @[<hov 2>\"anyOf\": [@\n\
         %a@]@\n\
         ]@]@\n\
         }@\n\
         },@\n\
         @[<hov 2>\"allOf\": [@\n\
         %a@]@\n\
         ]@]@\n\
         }"
        (Format.pp_print_list
           ~pp_sep:(fun fmt () -> Format.fprintf fmt ",@\n")
           (fun fmt (enum_cons, _) ->
             Format.fprintf fmt
               "@[<hov 2>{@\n\"type\": \"string\",@\n\"enum\": [\"%a\"]@]@\n}"
               format_enum_cons_name enum_cons))
        (EnumConstructor.Map.bindings enum_def)
        (Format.pp_print_list
           ~pp_sep:(fun fmt () -> Format.fprintf fmt ",@\n")
           (fun fmt (enum_cons, payload_type) ->
             Format.fprintf fmt
               "@[<hov 2>{@\n\
                @[<hov 2>\"if\": {@\n\
                @[<hov 2>\"properties\": {@\n\
                @[<hov 2>\"kind\": {@\n\
                \"const\": \"%a\"@]@\n\
                }@]@\n\
                }@]@\n\
                },@\n\
                @[<hov 2>\"then\": {@\n\
                @[<hov 2>\"properties\": {@\n\
                @[<hov 2>\"payload\": {@\n\
                %a@]@\n\
                }@]@\n\
                }@]@\n\
                }@]@\n\
                }"
               format_enum_cons_name enum_cons fmt_type payload_type))
        (EnumConstructor.Map.bindings enum_def)
    in

    Format.fprintf fmt "@\n%a"
      (Format.pp_print_list
         ~pp_sep:(fun fmt () -> Format.fprintf fmt ",@\n")
         (fun fmt typ ->
           match Marked.unmark typ with
           | TStruct sname ->
             Format.fprintf fmt
               "@[<hov 2>\"%a\": {@\n\
                \"type\": \"object\",@\n\
                @[<hov 2>\"properties\": {@\n\
                %a@]@\n\
                }@]@\n\
                }"
               format_struct_name sname
               (fmt_struct_properties ctx)
               sname
           | TEnum ename ->
             Format.fprintf fmt
               "@[<hov 2>\"%a\": {@\n\
                \"type\": \"object\",@\n\
                @[<hov 2>\"properties\": {@\n\
                %a@]@]@\n"
               format_enum_name ename fmt_enum_properties ename
           | _ -> ()))
      (collect_required_type_defs_from_scope_input
         scope_def.scope_body.scope_body_input_struct)

  let format_program
      (fmt : Format.formatter)
      (scope : string)
      (prgm : 'm Lcalc.Ast.program) =
    match find_scope_def scope prgm.scopes with
    | None -> Cli.error_print "Internal error: scope '%s' not found." scope
    | Some scope_def ->
      Cli.call_unstyled (fun _ ->
          Format.fprintf fmt
            "{@[<hov 2>@\n\
             \"type\": \"object\",@\n\
             \"@[<hov 2>definitions\": {%a@]@\n\
             },@\n\
             \"@[<hov 2>properties\": {@\n\
             %a@]@\n\
             }@]@\n\
             }"
            (fmt_definitions prgm.decl_ctx)
            scope_def
            (fmt_struct_properties prgm.decl_ctx)
            scope_def.scope_body.scope_body_input_struct)
end

let apply
    ~(source_file : Pos.input_file)
    ~(output_file : string option)
    ~(scope : string option)
    (prgm : 'm Lcalc.Ast.program)
    (type_ordering : Scopelang.Dependency.TVertex.t list) =
  ignore source_file;
  ignore type_ordering;
  match scope with
  | Some s ->
    File.with_formatter_of_opt_file output_file (fun fmt ->
        Cli.debug_print
          "Writing JSON schema corresponding to the scope '%s' to the file \
           %s..."
          s
          (Option.value ~default:"stdout" output_file);
        To_json.format_program fmt s prgm)
  | None -> Cli.error_print "A scope must be specified for the plugin: %s" name

let () = Driver.Plugin.register_lcalc ~name ~extension apply

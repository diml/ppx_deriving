open Longident
open Location
open Asttypes
open Parsetree
open Ast_helper
open Ast_convenience

type deriver = {
  name : string ;
  core_type : (core_type -> expression) option;
  type_decl_str : options:(string * expression) list -> path:string list ->
                   type_declaration list -> structure;
  type_ext_str : options:(string * expression) list -> path:string list ->
                  type_extension -> structure;
  type_decl_sig : options:(string * expression) list -> path:string list ->
                   type_declaration list -> signature;
  type_ext_sig : options:(string * expression) list -> path:string list ->
                  type_extension -> signature;
}

let registry : (string, deriver) Hashtbl.t
             = Hashtbl.create 16

let register d = Hashtbl.add registry d.name d

let lookup name =
  try  Some (Hashtbl.find registry name)
  with Not_found -> None

let raise_errorf ?sub ?if_highlight ?loc message =
  message |> Printf.kprintf (fun str ->
    let err = Location.error ?sub ?if_highlight ?loc str in
    raise (Location.Error err))

let create =
  let def_ext_str name ~options ~path typ_ext =
    raise_errorf "Extensible types in structures not supported by deriver %s" name
  in
  let def_ext_sig name ~options ~path typ_ext =
    raise_errorf "Extensible types in signatures not supported by deriver %s" name
  in
  let def_decl_str name ~options ~path typ_decl =
    raise_errorf "Type declarations in structures not supported by deriver %s" name
  in
  let def_decl_sig name ~options ~path typ_decl =
    raise_errorf "Type declaratons in signatures not supported by deriver %s" name
  in
  fun name ?core_type
    ?(type_ext_str=def_ext_str name)
    ?(type_ext_sig=def_ext_sig name)
    ?(type_decl_str=def_decl_str name)
    ?(type_decl_sig=def_decl_sig name)
    () ->
      { name ; core_type ;
        type_decl_str ; type_ext_str ;
        type_decl_sig ; type_ext_sig ;
      }

let string_of_core_type typ =
  Format.asprintf "%a" Pprintast.core_type { typ with ptyp_attributes = [] }

module Arg = struct
  let expr expr =
    `Ok expr

  let int expr =
    match expr with
    | { pexp_desc = Pexp_constant (Const_int n) } -> `Ok n
    | _ -> `Error "integer"

  let bool expr =
    match expr with
    | [%expr true] -> `Ok true
    | [%expr false] -> `Ok false
    | _ -> `Error "boolean"

  let string expr =
    match expr with
    | { pexp_desc = Pexp_constant (Const_string (n, None)) } -> `Ok n
    | _ -> `Error "string"

  let enum values expr =
    match expr with
    | { pexp_desc = Pexp_variant (name, None) }
      when List.mem name values -> `Ok name
    | _ -> `Error (Printf.sprintf "one of: %s"
                    (String.concat ", " (List.map (fun s -> "`"^s) values)))

  let get_attr ~deriver conv attr =
    match attr with
    | None -> None
    | Some ({ txt = name }, PStr [{ pstr_desc = Pstr_eval (expr, []) }]) ->
      begin match conv expr with
      | `Ok v -> Some v
      | `Error desc ->
        raise_errorf ~loc:expr.pexp_loc "%s: invalid [@%s]: %s expected" deriver name desc
      end
    | Some ({ txt = name; loc }, _) ->
      raise_errorf ~loc "%s: invalid [@%s]: value expected" deriver name

  let get_flag ~deriver attr =
    match attr with
    | None -> false
    | Some ({ txt = name }, PStr []) -> true
    | Some ({ txt = name; loc }, _) ->
      raise_errorf ~loc "%s: invalid [@%s]: empty structure expected" deriver name

  let get_expr ~deriver conv expr =
    match conv expr with
    | `Error desc -> raise_errorf ~loc:expr.pexp_loc "%s: %s expected" deriver desc
    | `Ok v -> v
end

type quoter = {
  mutable next_id : int;
  mutable bindings : value_binding list;
}

let create_quoter () = { next_id = 0; bindings = [] }

let quote ~quoter expr =
  let name = "__" ^ string_of_int quoter.next_id in
  quoter.bindings <- (Vb.mk (pvar name) [%expr fun () -> [%e expr]]) :: quoter.bindings;
  quoter.next_id <- quoter.next_id + 1;
  [%expr [%e evar name] ()]

let sanitize ?(quoter=create_quoter ()) expr =
  Exp.let_ Nonrecursive quoter.bindings [%expr
    (let open! Ppx_deriving_runtime in [%e expr]) [@ocaml.warning "-A"]]

let with_quoter fn a =
  let quoter = create_quoter () in
  sanitize ~quoter (fn quoter a)

let expand_path ~path ident =
  String.concat "." (path @ [ident])

let path_of_type_decl ~path type_decl =
  match type_decl.ptype_manifest with
  | Some { ptyp_desc = Ptyp_constr ({ txt = lid }, _) } ->
    begin match lid with
    | Lident _ -> []
    | Ldot (lid, _) -> Longident.flatten lid
    | Lapply _ -> assert false
    end
  | _ -> path

let mangle ?(fixpoint="t") affix name =
  match name = fixpoint, affix with
  | true,  (`Prefix x | `Suffix x) -> x
  | true, `PrefixSuffix (p, s) -> p ^ "_" ^ s
  | false, `PrefixSuffix (p, s) -> p ^ "_" ^ name ^ "_" ^ s
  | false, `Prefix x -> x ^ "_" ^ name
  | false, `Suffix x -> name ^ "_" ^ x

let mangle_type_decl ?fixpoint affix { ptype_name = { txt = name } } =
  mangle ?fixpoint affix name

let mangle_lid ?fixpoint affix lid =
  match lid with
  | Lident s    -> Lident (mangle ?fixpoint affix s)
  | Ldot (p, s) -> Ldot (p, mangle ?fixpoint affix s)
  | Lapply _    -> assert false

let attr ~deriver name attrs =
  let starts str prefix =
    String.length str >= String.length prefix &&
      String.sub str 0 (String.length prefix) = prefix
  in
  let try_prefix prefix f =
    if List.exists (fun ({ txt }, _) -> starts txt prefix) attrs
    then prefix ^ name
    else f ()
  in
  let name =
    try_prefix ("deriving."^deriver^".") (fun () ->
      try_prefix (deriver^".") (fun () ->
        name))
  in
  try Some (List.find (fun ({ txt }, _) -> txt = name) attrs)
  with Not_found -> None

let attr_warning expr =
  let loc = !default_loc in
  let structure = {pstr_desc = Pstr_eval (expr, []); pstr_loc = loc} in
  {txt = "ocaml.warning"; loc}, PStr [structure]

let fold_left_type_params fn accum params =
  List.fold_left (fun accum (param, _) ->
      match param with
      | { ptyp_desc = Ptyp_any } -> accum
      | { ptyp_desc = Ptyp_var name } ->
        fn accum name
      | _ -> assert false)
    accum params

let fold_left_type_decl fn accum { ptype_params } =
  fold_left_type_params fn accum ptype_params

let fold_left_type_ext fn accum { ptyext_params } =
  fold_left_type_params fn accum ptyext_params

let fold_right_type_params fn params accum =
  List.fold_right (fun (param, _) accum ->
      match param with
      | { ptyp_desc = Ptyp_any } -> accum
      | { ptyp_desc = Ptyp_var name } ->
        fn name accum
      | _ -> assert false)
    params accum

let fold_right_type_decl fn { ptype_params } accum =
  fold_right_type_params fn ptype_params accum

let fold_right_type_ext fn { ptyext_params } accum =
  fold_right_type_params fn ptyext_params accum

let free_vars_in_core_type typ =
  let rec free_in typ =
    match typ with
    | { ptyp_desc = Ptyp_any } -> []
    | { ptyp_desc = Ptyp_var name } -> [name]
    | { ptyp_desc = Ptyp_arrow (_, x, y) } -> free_in x @ free_in y
    | { ptyp_desc = (Ptyp_tuple xs | Ptyp_constr (_, xs)) } ->
      List.map free_in xs |> List.concat
    | { ptyp_desc = Ptyp_alias (x, name) } -> [name] @ free_in x
    | { ptyp_desc = Ptyp_poly (bound, x) } ->
      List.filter (fun y -> not (List.mem y bound)) (free_in x)
    | { ptyp_desc = Ptyp_variant (rows, _, _) } ->
      List.map (
          function Rtag (_,_,_,ts) -> List.map free_in ts
                 | Rinherit t -> [free_in t]
        ) rows |> List.concat |> List.concat
    | _ -> assert false
  in
  let rec uniq acc lst =
    match lst with
    | a :: b :: lst when a = b -> uniq acc (b :: lst)
    | x :: lst -> uniq (x :: acc) lst
    | [] -> acc
  in
  List.rev (uniq [] (free_in typ))

let var_name_of_int i =
  let letter = "abcdefghijklmnopqrstuvwxyz" in
  let rec loop i =
    if i < 26 then [letter.[i]] else letter.[i mod 26] :: loop (i / 26)
  in
  String.concat "" (List.map (String.make 1) (loop i))

let fresh_var bound =
  let rec loop i =
    let var_name = var_name_of_int i in
    if List.mem var_name bound then loop (i + 1) else var_name
  in
  loop 0

let poly_fun_of_type_decl type_decl expr =
  fold_right_type_decl (fun name expr -> Exp.fun_ "" None (pvar ("poly_"^name)) expr) type_decl expr

let poly_fun_of_type_ext type_ext expr =
  fold_right_type_ext (fun name expr -> Exp.fun_ "" None (pvar ("poly_"^name)) expr) type_ext expr

let poly_apply_of_type_decl type_decl expr =
  fold_left_type_decl (fun expr name -> Exp.apply expr ["", evar ("poly_"^name)]) expr type_decl

let poly_apply_of_type_ext type_ext expr =
  fold_left_type_ext (fun expr name -> Exp.apply expr ["", evar ("poly_"^name)]) expr type_ext

let poly_arrow_of_type_decl fn type_decl typ =
  fold_right_type_decl (fun name typ -> Typ.arrow "" (fn (Typ.var name)) typ) type_decl typ

let poly_arrow_of_type_ext fn type_ext typ =
  fold_right_type_ext (fun  name typ -> Typ.arrow "" (fn (Typ.var name)) typ) type_ext typ

let core_type_of_type_decl { ptype_name = { txt = name }; ptype_params } =
  Typ.constr (mknoloc (Lident name)) (List.map fst ptype_params)

let core_type_of_type_ext { ptyext_path ; ptyext_params } =
  Typ.constr ptyext_path (List.map fst ptyext_params)

let fold_exprs ?unit fn exprs =
  match exprs with
  | [a] -> a
  | hd::tl -> List.fold_left fn hd tl
  | [] ->
    match unit with
    | Some x -> x
    | None -> raise (Invalid_argument "Ppx_deriving.fold_exprs")

let seq_reduce ?sep a b =
  match sep with
  | Some x -> [%expr [%e a]; [%e x]; [%e b]]
  | None -> [%expr [%e a]; [%e b]]

let binop_reduce x a b =
  [%expr [%e x] [%e a] [%e b]]

let strong_type_of_type ty =
  let free_vars = free_vars_in_core_type ty in
  Typ.force_poly @@ Typ.poly free_vars ty

let derive path pstr_loc item attributes fn arg =
  let deriving = find_attr "deriving" attributes in
  let deriver_exprs, loc =
    match deriving with
    | Some (PStr [{ pstr_desc = Pstr_eval (
                    { pexp_desc = Pexp_tuple exprs }, []); pstr_loc }]) ->
      exprs, pstr_loc
    | Some (PStr [{ pstr_desc = Pstr_eval (
                    { pexp_desc = (Pexp_ident _ | Pexp_apply _) } as expr, []); pstr_loc }]) ->
      [expr], pstr_loc
    | _ -> raise_errorf ~loc:pstr_loc "Unrecognized [@@deriving] annotation syntax"
  in
  List.fold_left (fun items deriver_expr ->
      let name, options =
        match deriver_expr with
        | { pexp_desc = Pexp_ident name } ->
          name, []
        | { pexp_desc = Pexp_apply ({ pexp_desc = Pexp_ident name }, ["",
            { pexp_desc = Pexp_record (options, None) }]) } ->
          name, options |> List.map (fun ({ txt }, expr) ->
            String.concat "." (Longident.flatten txt), expr)
        | { pexp_loc } ->
          raise_errorf ~loc:pexp_loc "Unrecognized [@@deriving] option syntax"
      in
      let name, loc = String.concat "_" (Longident.flatten name.txt), name.loc in
      let is_optional, options =
        match List.assoc "optional" options with
        | exception Not_found -> false, options
        | expr ->
          Arg.(get_expr ~deriver:name bool) expr,
          List.remove_assoc "optional" options
      in
      match lookup name with
      | Some deriver ->
        items @ ((fn deriver) ~options ~path:(!path) arg)
      | None ->
        if is_optional then items
        else raise_errorf ~loc "Cannot locate deriver %s" name)
    [item] deriver_exprs

let derive_type_decl path typ_decls pstr_loc item fn =
  let attributes = List.concat (List.map (fun { ptype_attributes = attrs } -> attrs) typ_decls) in
  derive path pstr_loc item attributes fn typ_decls

let derive_type_ext path typ_ext pstr_loc item fn =
  let attributes = typ_ext.ptyext_attributes in
  derive path pstr_loc item attributes fn typ_ext

let module_from_input_name () =
  match !Location.input_name with
  | "//toplevel//" -> []
  | filename -> [String.capitalize (Filename.(basename (chop_suffix filename ".ml")))]

let mapper =
  let module_nesting = ref [] in
  let with_module name f =
    let old_nesting = !module_nesting in
    module_nesting := !module_nesting @ [name];
    let result = f () in
    module_nesting := old_nesting;
    result
  in
  let expression mapper expr =
    match expr with
    | { pexp_desc = Pexp_extension ({ txt = name; loc }, payload) }
        when String.(length name >= 7 && sub name 0 7 = "derive.") ->
      let name = String.sub name 7 ((String.length name) - 7) in
      let deriver =
        match lookup name with
        | Some { core_type = Some deriver } -> deriver
        | Some _ -> raise_errorf ~loc "Deriver %s does not support inline notation" name
        | None -> raise_errorf ~loc "Cannot locate deriver %s" name
      in
      begin match payload with
      | PTyp typ -> deriver typ
      | _ -> raise_errorf ~loc "Unrecognized [%%derive.*] syntax"
      end
    | { pexp_desc = Pexp_extension ({ txt = name; loc }, PTyp typ) } ->
      begin match lookup name with
      | Some { core_type = Some deriver } ->
        Ast_helper.with_default_loc typ.ptyp_loc (fun () -> deriver typ)
      | _ -> Ast_mapper.(default_mapper.expr) mapper expr
      end
    | _ -> Ast_mapper.(default_mapper.expr) mapper expr
  in
  let structure mapper items =
    match items with
    | { pstr_desc = Pstr_type typ_decls; pstr_loc } as item :: rest when
        List.exists (fun ty -> has_attr "deriving" ty.ptype_attributes) typ_decls ->
      Ast_helper.with_default_loc pstr_loc (fun () ->
        derive_type_decl module_nesting typ_decls pstr_loc item
          (fun deriver -> deriver.type_decl_str)
	@ mapper.Ast_mapper.structure mapper rest)
    | { pstr_desc = Pstr_typext typ_ext; pstr_loc } as item :: rest when
          has_attr "deriving" typ_ext.ptyext_attributes ->
      Ast_helper.with_default_loc pstr_loc (fun () ->
        derive_type_ext module_nesting typ_ext pstr_loc item
          (fun deriver -> deriver.type_ext_str)
	@ mapper.Ast_mapper.structure mapper rest)
    | { pstr_desc = Pstr_module ({ pmb_name = { txt = name } } as mb) } as item :: rest ->
      { item with pstr_desc = Pstr_module (
          with_module name
	    (fun () -> mapper.Ast_mapper.module_binding mapper mb)) }
        :: mapper.Ast_mapper.structure mapper rest
    | { pstr_desc = Pstr_recmodule mbs } as item :: rest ->
      { item with pstr_desc = Pstr_recmodule (
          mbs |> List.map (fun ({ pmb_name = { txt = name } } as mb) ->
            with_module name
	      (fun () -> mapper.Ast_mapper.module_binding mapper mb))) }
        :: mapper.Ast_mapper.structure mapper rest
    | { pstr_loc } as item :: rest ->
      mapper.Ast_mapper.structure_item mapper item
      :: mapper.Ast_mapper.structure mapper rest
    | [] -> []
  in
  let signature mapper items =
    match items with
    | { psig_desc = Psig_type typ_decls; psig_loc } as item :: rest when
        List.exists (fun ty -> has_attr "deriving" ty.ptype_attributes) typ_decls ->
      Ast_helper.with_default_loc psig_loc (fun () ->
        derive_type_decl module_nesting typ_decls psig_loc item
          (fun deriver -> deriver.type_decl_sig)
	@ mapper.Ast_mapper.signature mapper rest)
    | { psig_desc = Psig_typext typ_ext; psig_loc } as item :: rest when
        has_attr "deriving" typ_ext.ptyext_attributes ->
      Ast_helper.with_default_loc psig_loc (fun () ->
        derive_type_ext module_nesting typ_ext psig_loc item
          (fun deriver -> deriver.type_ext_sig)
	@ mapper.Ast_mapper.signature mapper rest)
    | { psig_desc = Psig_module ({ pmd_name = { txt = name } } as md) } as item :: rest ->
      { item with psig_desc = Psig_module (
          with_module name
	    (fun () -> mapper.Ast_mapper.module_declaration mapper md)) }
        :: mapper.Ast_mapper.signature mapper rest
    | { psig_desc = Psig_recmodule mds } as item :: rest ->
      { item with psig_desc = Psig_recmodule (
          mds |> List.map (fun ({ pmd_name = { txt = name } } as md) ->
            with_module name
	      (fun () -> mapper.Ast_mapper.module_declaration mapper md))) }
        :: mapper.Ast_mapper.signature mapper rest
    | { psig_loc } as item :: rest ->
      mapper.Ast_mapper.signature_item mapper item
      :: mapper.Ast_mapper.signature mapper rest
    | [] -> []
  in
  Ast_mapper.{default_mapper with
    expr = expression;
    structure = (fun mapper items ->
      module_nesting := module_from_input_name ();
      structure { mapper with structure; signature } items);
    signature = (fun mapper items ->
      module_nesting := module_from_input_name ();
      signature { mapper with structure; signature } items)
  }

let hash_variant s =
  let accu = ref 0 in
  for i = 0 to String.length s - 1 do
    accu := 223 * !accu + Char.code s.[i]
  done;
  (* reduce to 31 bits *)
  accu := !accu land (1 lsl 31 - 1);
  (* make it signed for 64 bits architectures *)
  if !accu > 0x3FFFFFFF then !accu - (1 lsl 31) else !accu

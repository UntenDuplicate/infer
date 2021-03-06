(*
 * Copyright (c) 2016 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open CFrontend_utils
open !Utils

let get_source_range an =
  match an with
  | CTL.Decl decl ->
      let decl_info = Clang_ast_proj.get_decl_tuple decl in
      decl_info.Clang_ast_t.di_source_range
  | CTL.Stmt stmt ->
      let stmt_info, _ = Clang_ast_proj.get_stmt_tuple stmt in
      stmt_info.Clang_ast_t.si_source_range

let is_in_main_file translation_unit_context an =
  let file_opt = (fst (get_source_range an)).Clang_ast_t.sl_file in
  match file_opt with
  | None ->
      false
  | Some file ->
      DB.inode_equal
        (CLocation.source_file_from_path file)
        translation_unit_context.CFrontend_config.source_file

let is_ck_context (context: CLintersContext.context) an =
  context.is_ck_translation_unit
  && is_in_main_file context.translation_unit_context an
  && General_utils.is_objc_extension context.translation_unit_context


(** Recursively go up the inheritance hierarchy of a given ObjCInterfaceDecl.
    (Returns false on decls other than that one.) *)
let is_component_or_controller_if decl =
  let open CFrontend_config in
  Ast_utils.is_objc_if_descendant decl [ckcomponent_cl; ckcomponentcontroller_cl]

(** True if it's an objc class impl that extends from CKComponent or
    CKComponentController, false otherwise *)
let rec is_component_or_controller_descendant_impl decl =
  match decl with
  | Clang_ast_t.ObjCImplementationDecl _ ->
      is_component_or_controller_if (Ast_utils.get_super_if (Some decl))
  | Clang_ast_t.LinkageSpecDecl (_, decl_list, _) ->
      contains_ck_impl decl_list
  | _ -> false

(** Returns true if the passed-in list of decls contains an
    ObjCImplementationDecl of a descendant of CKComponent or
    CKComponentController.

    Does not recurse into hierarchy. *)
and contains_ck_impl decl_list =
  IList.exists is_component_or_controller_descendant_impl decl_list

(** An easy way to fix the component kit best practice
    http://componentkit.org/docs/avoid-local-variables.html

    Local variables that are const or const pointers by definition cannot be
    assigned to after declaration, which means the entire class of bugs stemming
    from value mutation after assignment are gone.

    Note we want const pointers, not mutable pointers to const instances.

    OK:

    ```
    const int a;
    int *const b;
    NSString *const c;
    const int *const d;
    ```

    Not OK:

    ```
    const int *z;
    const NSString *y;
    ``` *)
let mutable_local_vars_advice context an =
  let rec get_referenced_type (qual_type: Clang_ast_t.qual_type) : Clang_ast_t.decl option =
    let typ_opt = Ast_utils.get_desugared_type qual_type.qt_type_ptr in
    match (typ_opt : Clang_ast_t.c_type option) with
    | Some ObjCInterfaceType (_, decl_ptr)
    | Some RecordType (_, decl_ptr) -> Ast_utils.get_decl decl_ptr
    | Some PointerType (_, inner_qual_type)
    | Some ObjCObjectPointerType (_, inner_qual_type)
    | Some LValueReferenceType (_, inner_qual_type) -> get_referenced_type inner_qual_type
    | _ -> None in

  let is_of_whitelisted_type qual_type =
    let cpp_whitelist = ["CKComponentScope"; "FBTrackingNodeScope"; "FBTrackingCodeScope"] in
    let objc_whitelist = ["NSError"] in
    match get_referenced_type qual_type with
    | Some CXXRecordDecl (_, ndi, _, _, _, _, _, _) ->
        IList.mem string_equal ndi.ni_name cpp_whitelist
    | Some ObjCInterfaceDecl (_, ndi, _, _, _) ->
        IList.mem string_equal ndi.ni_name objc_whitelist
    | _ -> false in

  match an with
  | CTL.Decl (Clang_ast_t.VarDecl(decl_info, named_decl_info, qual_type, _) as decl)->
      let is_const_ref = match Ast_utils.get_type qual_type.qt_type_ptr with
        | Some LValueReferenceType (_, {Clang_ast_t.qt_is_const}) ->
            qt_is_const
        | _ -> false in
      let is_const = qual_type.qt_is_const || is_const_ref in
      let condition = is_ck_context context an
                      && (not (Ast_utils.is_syntactically_global_var decl))
                      && (not is_const)
                      && not (is_of_whitelisted_type qual_type)
                      && not decl_info.di_is_implicit in
      if condition then
        CTL.True, Some {
          CIssue.issue = CIssue.Mutable_local_variable_in_component_file;
          CIssue.description = "Local variable '" ^ named_decl_info.ni_name
                               ^ "' should be const to avoid reassignment";
          CIssue.suggestion = Some "Add a const (after the asterisk for pointer types).";
          CIssue.loc = CFrontend_checkers.location_from_dinfo context decl_info
        }
      else CTL.False, None
  | _ -> CTL.False, None (* Should only be called with a VarDecl *)


(** Catches functions that should be composite components.
    http://componentkit.org/docs/break-out-composites.html

    Any static function that returns a subclass of CKComponent will be flagged. *)
let component_factory_function_advice context an =
  let is_component_if decl =
    Ast_utils.is_objc_if_descendant decl [CFrontend_config.ckcomponent_cl] in

  match an with
  | CTL.Decl (Clang_ast_t.FunctionDecl (decl_info, _, (qual_type: Clang_ast_t.qual_type), _)) ->
      let objc_interface =
        Ast_utils.type_ptr_to_objc_interface qual_type.qt_type_ptr in
      let condition =
        is_ck_context context an && is_component_if objc_interface in
      if condition then
        CTL.True, Some {
          CIssue.issue = CIssue.Component_factory_function;
          CIssue.description = "Break out composite components";
          CIssue.suggestion = Some (
              "Prefer subclassing CKCompositeComponent to static helper functions \
               that return a CKComponent subclass."
            );
          CIssue.loc = CFrontend_checkers.location_from_dinfo context decl_info
        }
      else CTL.False, None
  | _ -> CTL.False, None (* Should only be called with FunctionDecl *)

(** Components should not inherit from each other. They should instead
    inherit from CKComponent, CKCompositeComponent, or
    CKStatefulViewComponent. (Similar rule applies to component controllers.) *)
let component_with_unconventional_superclass_advice context an =
  let check_interface if_decl =
    match if_decl with
    | Clang_ast_t.ObjCInterfaceDecl (_, _, _, _, _) ->
        if is_component_or_controller_if (Some if_decl) then
          let superclass_name = match Ast_utils.get_super_if (Some if_decl) with
            | Some Clang_ast_t.ObjCInterfaceDecl (_, named_decl_info, _, _, _) ->
                Some named_decl_info.ni_name
            | _ -> None in
          let has_conventional_superclass =
            let open CFrontend_config in
            match superclass_name with
            | Some name when IList.mem string_equal name [
                ckcomponent_cl;
                ckcomponentcontroller_cl;
                "CKCompositeComponent";
                "CKStatefulViewComponent";
                "CKStatefulViewComponentController";
                "NTNativeTemplateComponent"
              ] -> true
            | _ -> false in
          let condition =
            is_component_or_controller_if (Some if_decl)
            && not has_conventional_superclass in
          if condition then
            CTL.True, Some {
              CIssue.issue = CIssue.Component_with_unconventional_superclass;
              CIssue.description = "Never Subclass Components";
              CIssue.suggestion = Some (
                  "Instead, create a new subclass of CKCompositeComponent."
                );
              CIssue.loc = CFrontend_checkers.location_from_decl context if_decl
            }
          else
            CTL.False, None
        else
          CTL.False, None
    | _ -> assert false in
  match an with
  | CTL.Decl (Clang_ast_t.ObjCImplementationDecl (_, _, _, _, impl_decl_info)) ->
      let if_decl_opt =
        Ast_utils.get_decl_opt_with_decl_ref impl_decl_info.oidi_class_interface in
      if Option.is_some if_decl_opt && is_ck_context context an then
        check_interface (Option.get if_decl_opt)
      else
        CTL.False, None
  | _ -> CTL.False, None

(** Components should only have one factory method.

    (They could technically have none if they re-use the parent class's factory
    method.)

    We care about ones that are declared in the interface. In other words, if
    additional factory methods are implementation-only, the rule doesn't catch
    it. While its existence is probably not good, I can't think of any reason
    there would be factory methods that aren't exposed outside of a class is
    not useful if there's only one public factory method. *)
let component_with_multiple_factory_methods_advice context an =
  let is_unavailable_attr attr = match attr with
    | Clang_ast_t.UnavailableAttr _ -> true
    | _ -> false in
  let is_available_factory_method if_decl (decl: Clang_ast_t.decl) =
    let attrs = match decl with
      | ObjCMethodDecl (decl_info, _, _) -> decl_info.Clang_ast_t.di_attributes
      | _ -> assert false in
    let unavailable_attrs = (IList.filter is_unavailable_attr attrs) in
    let is_available = IList.length unavailable_attrs = 0 in
    (Ast_utils.is_objc_factory_method if_decl decl) && is_available in

  let check_interface if_decl =
    match if_decl with
    | Clang_ast_t.ObjCInterfaceDecl (decl_info, _, decls, _, _) ->
        let factory_methods = IList.filter (is_available_factory_method if_decl) decls in
        if (IList.length factory_methods) > 1 then
          CTL.True, Some {
            CIssue.issue = CIssue.Component_with_multiple_factory_methods;
            CIssue.description = "Avoid Overrides";
            CIssue.suggestion =
              Some "Instead, always expose all parameters in a single \
                    designated initializer and document which are optional.";
            CIssue.loc = CFrontend_checkers.location_from_dinfo context decl_info
          }
        else
          CTL.False, None
    | _ -> assert false in
  match an with
  | CTL.Decl (Clang_ast_t.ObjCImplementationDecl (_, _, _, _, impl_decl_info)) ->
      let if_decl_opt =
        Ast_utils.get_decl_opt_with_decl_ref impl_decl_info.oidi_class_interface in
      (match if_decl_opt with
       | Some d when is_ck_context context an -> check_interface d
       | _ -> CTL.False, None)
  | _ -> CTL.False, None

let in_ck_class (context: CLintersContext.context) =
  Option.map_default is_component_or_controller_descendant_impl false context.current_objc_impl
  && General_utils.is_objc_extension context.translation_unit_context

(** Components shouldn't have side-effects in its initializer.

    http://componentkit.org/docs/no-side-effects.html

    The only current way we look for side-effects is by looking for
    asynchronous execution (dispatch_async, dispatch_after) and execution that
    relies on other threads (dispatch_sync). Other side-effects, like reading
    of global variables, is not checked by this analyzer, although still an
    infraction of the rule. *)
let rec _component_initializer_with_side_effects_advice
    (context: CLintersContext.context) call_stmt =
  let condition =
    in_ck_class context
    && context.in_objc_static_factory_method
    && (match context.current_objc_impl with
        | Some d -> is_in_main_file context.translation_unit_context (CTL.Decl d)
        | None -> false) in
  if condition then
    match call_stmt with
    | Clang_ast_t.ImplicitCastExpr (_, stmt :: _, _, _) ->
        _component_initializer_with_side_effects_advice context stmt
    | Clang_ast_t.DeclRefExpr (_, _, _, decl_ref_expr_info) ->
        let refs = [decl_ref_expr_info.drti_decl_ref;
                    decl_ref_expr_info.drti_found_decl_ref] in
        (match IList.find_map_opt Ast_utils.name_of_decl_ref_opt refs with
         | Some "dispatch_after"
         | Some "dispatch_async"
         | Some "dispatch_sync" ->
             CTL.True, Some {
               CIssue.issue = CIssue.Component_initializer_with_side_effects;
               CIssue.description = "No Side-effects";
               CIssue.suggestion = Some "Your +new method should not modify any \
                                         global variables or global state.";
               CIssue.loc = CFrontend_checkers.location_from_stmt context call_stmt
             }
         | _ ->
             CTL.False, None)
    | _->
        CTL.False, None
  else
    CTL.False, None

let component_initializer_with_side_effects_advice
    (context: CLintersContext.context) an =
  match an with
  | CTL.Stmt (CallExpr (_, called_func_stmt :: _, _))  ->
      _component_initializer_with_side_effects_advice context called_func_stmt
  | _ -> CTL.False, None (* only to be called in CallExpr *)

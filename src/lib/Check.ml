(* This file implements the semantic type-checking algorithm described in the
   paper. *)
module D = Domain
module S = Syntax
module Env = ElabEnv

type error =
  | Cannot_synth_term of S.t
  | Type_mismatch of D.tp * D.tp
  | Term_mismatch of D.t * D.t
  | Expecting_universe of D.t
  | Misc of string

exception TypeError of error

let tp_error e = raise @@ TypeError e

type env = ElabEnv.t

let pp_error fmt = function
  | Cannot_synth_term t ->
    Format.fprintf fmt "@[<v> Cannot synthesize the type of: @[<hov 2>  ";
    S.pp fmt t;
    Format.fprintf fmt "@]@]@,"
  | Term_mismatch (t1, t2) ->
    Format.fprintf fmt "@[<v>Cannot equate@,@[<hov 2>  ";
    D.pp fmt t1;
    Format.fprintf fmt "@]@ with@,@[<hov 2>  ";
    D.pp fmt t2;
    Format.fprintf fmt "@]@]@,"
  | Type_mismatch (t1, t2) ->
    Format.fprintf fmt "@[<v>Cannot equate@,@[<hov 2>  ";
    D.pp_tp fmt t1;
    Format.fprintf fmt "@]@ with@,@[<hov 2>  ";
    D.pp_tp fmt t2;
    Format.fprintf fmt "@]@]@,"
  | Expecting_universe d ->
    Format.fprintf fmt "@[<v>Expected some universe but found@ @[<hov 2>";
    D.pp fmt d;
    Format.fprintf fmt "@]@]@,"
  | Misc s -> Format.pp_print_string fmt s

let assert_equal size t1 t2 tp =
  if Nbe.equal_nf size (D.Nf {tp; term = t1}) (D.Nf {tp; term = t2}) then ()
  else tp_error (Term_mismatch (t1, t2))

let rec check ~env ~term ~tp =
  match term with
  | S.Let (def, body) ->
    let def_tp = synth ~env ~term:def in
    let def_val = Nbe.eval def (Env.to_sem_env env) in
    check ~env:(Env.push_term None def_val def_tp env) ~term:body ~tp
  | S.Refl term -> (
      match tp with
      | D.Id (tp, left, right) ->
        check ~env ~term ~tp;
        let term = Nbe.eval term (Env.to_sem_env env) in
        assert_equal (Env.size env) term left tp;
        assert_equal (Env.size env) term right tp
      | t -> tp_error @@ Misc ("Expecting Id but found\n" ^ D.show_tp t) )
  | S.Lam body -> (
      match tp with
      | D.Pi (arg_tp, clo) ->
        let var = D.mk_var arg_tp (Env.size env) in
        let dest_tp = Nbe.do_tp_clo clo var in
        check
          ~env:(Env.push_term None var arg_tp env)
          ~term:body ~tp:dest_tp
      | t -> tp_error @@ Misc ("Expecting Pi but found\n" ^ D.show_tp t) )
  | S.Pair (left, right) -> (
      match tp with
      | D.Sg (left_tp, right_tp) ->
        check ~env ~term:left ~tp:left_tp;
        let left_sem = Nbe.eval left (Env.to_sem_env env) in
        check ~env ~term:right ~tp:(Nbe.do_tp_clo right_tp left_sem)
      | t -> tp_error @@ Misc ("Expecting Sg but found\n" ^ D.show_tp t) )
  | _ ->
    let tp' = synth ~env ~term in
    if Nbe.equal_tp (Env.size env) tp' tp then ()
    else tp_error (Type_mismatch (tp', tp))

and synth ~env ~term =
  match term with
  | S.Var i -> Env.get_local i env
  | S.Global sym -> 
    let D.Nf {tp; _} = Env.get_global sym env in
    tp
  | Check (term, tp') ->
    let tp = Nbe.eval_tp tp' @@ Env.to_sem_env env in
    check ~env ~term ~tp;
    tp
  | S.Zero -> D.Nat
  | S.Suc term ->
    check ~env ~term ~tp:Nat;
    D.Nat
  | S.Fst p -> (
      match synth ~env ~term:p with
      | Sg (left_tp, _) -> left_tp
      | t -> tp_error @@ Misc ("Expecting Sg but found\n" ^ D.show_tp t) )
  | S.Snd p -> (
      match synth ~env ~term:p with
      | Sg (_, right_tp) ->
        let proj = Nbe.eval (Fst p) (Env.to_sem_env env) in
        Nbe.do_tp_clo right_tp proj
      | t -> tp_error @@ Misc ("Expecting Sg but found\n" ^ D.show_tp t) )
  | S.Ap (f, a) -> (
      match synth ~env ~term:f with
      | Pi (src, dest) ->
        check ~env ~term:a ~tp:src;
        let a_sem = Nbe.eval a (Env.to_sem_env env) in
        Nbe.do_tp_clo dest a_sem
      | t -> tp_error @@ Misc ("Expecting Pi but found\n" ^ D.show_tp t) )
  | S.NRec (mot, zero, suc, n) ->
    check ~env ~term:n ~tp:Nat;
    let var = D.mk_var Nat (Env.size env) in
    check_tp ~env:(Env.push_term None var Nat env) ~tp:mot;
    let sem_env = Env.to_sem_env env in
    let zero_tp = Nbe.eval_tp mot {sem_env with locals = Zero :: sem_env.locals} in
    let ih_tp = Nbe.eval_tp mot {sem_env with locals = var :: sem_env.locals} in
    let ih_var = D.mk_var ih_tp (Env.size env + 1) in
    let suc_tp = Nbe.eval_tp mot {sem_env with locals = Suc var :: sem_env.locals} in
    check ~env ~term:zero ~tp:zero_tp;
    check
      ~env:
        (Env.push_term None var Nat env
         |> Env.push_term None ih_var ih_tp)
      ~term:suc ~tp:suc_tp;
    Nbe.eval_tp mot {sem_env with locals = Nbe.eval n sem_env :: sem_env.locals}
  | S.J (mot, refl, eq) -> (
      let eq_tp = synth ~env ~term:eq in
      let sem_env = Env.to_sem_env env in
      match eq_tp with
      | D.Id (tp', left, right) ->
        let mot_var1 = D.mk_var tp' (Env.size env) in
        let mot_var2 = D.mk_var tp' (Env.size env + 1) in
        let mot_var3 =
          D.mk_var (D.Id (tp', mot_var1, mot_var2)) (Env.size env + 1)
        in
        let mot_env =
          Env.push_term None mot_var1 tp' env
          |> Env.push_term None mot_var2 tp'
          |> Env.push_term None mot_var3 (D.Id (tp', mot_var1, mot_var2))
        in
        check_tp ~env:mot_env ~tp:mot;
        let refl_var = D.mk_var tp' (Env.size env) in
        let refl_tp =
          Nbe.eval_tp mot {sem_env with locals = D.Refl refl_var :: refl_var :: refl_var :: sem_env.locals}
        in
        check
          ~env:(Env.push_term None refl_var tp' env)
          ~term:refl ~tp:refl_tp;
        Nbe.eval_tp mot {sem_env with locals = Nbe.eval eq sem_env :: right :: left :: sem_env.locals}
      | t -> tp_error @@ Misc ("Expecting Id but found\n" ^ D.show_tp t) )
  | _ -> tp_error (Cannot_synth_term term)

and check_tp ~env ~tp =
  match tp with
  | Nat -> ()
  | Pi (l, r)
  | Sg (l, r) ->
    check_tp ~env ~tp:l;
    let l_sem = Nbe.eval_tp l (Env.to_sem_env env) in
    let var = D.mk_var l_sem (Env.size env) in
    check_tp ~env:(Env.push_term None var l_sem env) ~tp:r
  | Id (tp, l, r) ->
    check_tp ~env ~tp;
    let tp = Nbe.eval_tp tp (Env.to_sem_env env) in
    check ~env ~term:l ~tp;
    check ~env ~term:r ~tp
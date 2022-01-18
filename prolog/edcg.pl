:- module( edcg, [
    op(1200, xfx, '-->>'),   % Similar to '-->'
    op(1200, xfx, '==>>'),   % Similar to '-->'
    op( 990,  fx, '?'),      % For guards with '==>>'
    edcg_import_sentinel/0
]).

:- multifile user:term_expansion/4.

% If running a version of SWI-Prolog older than 8.3.19, define the
% '=>' operator to prevent syntax errors in this module.  The '==>>'
% operator is still defined in the module export, even though it'll
% generate a runtime error if it's used.
:- if(\+ current_op(_, _, '=>')).
:- op(1200, xfx, '=>').
:- endif.

:- use_module(library(debug), [debug/3]).
:- use_module(library(lists), [member/2, selectchk/3]).
:- use_module(library(apply), [maplist/3, maplist/4, foldl/4]).

% These predicates define extra arguments and are defined in the
% modules that use the edcg module.
:- multifile
    acc_info/5,
    acc_info/7,
    pred_info/3,
    pass_info/1,
    pass_info/2.

:- multifile
    prolog_clause:make_varnames_hook/5,
    prolog_clause:unify_clause_hook/5.

% True if the module being read has opted-in to EDCG macro expansion.
wants_edcg_expansion :-
    prolog_load_context(module, Module),
    wants_edcg_expansion(Module).

wants_edcg_expansion(Module) :-
    Module \== edcg,  % don't expand macros in our own library
    predicate_property(Module:edcg_import_sentinel, imported_from(edcg)).

% dummy predicate exported to detect which modules want EDCG expansion
edcg_import_sentinel.

% term_expansion/4 is used to work around SWI-Prolog's attempts to
% match variable names when doing a listing (or interactive trace) and
% getting confused; this sometimes results in a strange error message
% for an unknown extended_pos(Pos,N).

% Returning a variable for _Layout2 means "I don't know".
% See https://swi-prolog.discourse.group/t/strange-warning-message-from-compile-or-listing/3774
user:term_expansion(Term, Layout0, Expansion, Layout) :-
    wants_edcg_expansion,
    edcg_expand_clause(Term, Expansion, Layout0, Layout).

% TODO: Uncomment the following for guitracer.
% prolog_clause:unify_clause_hook(Read, Decompiled, Module, TermPos0, TermPos) :-
%     wants_edcg_expansion(Module),
%     edcg_expand_clause(Read, Decompiled, TermPos0, TermPos).

% TODO: implement the following for guitracer
%   prolog_clause:make_varnames_hook(ReadClause, DecompiledClause, Offsets, Names, Term) :- ...

% TODO: support ((H,PB-->>B) [same as regular DCG]
edcg_expand_clause((H-->>B), Expansion, ClausePos0, ClausePos) :-
    edcg_expand_clause_wrap((H-->>B), Expansion, ClausePos0, ClausePos).
edcg_expand_clause((H,PB==>>B), Expansion, ClausePos0, ClausePos) :-
    edcg_expand_clause_wrap((H,PB==>>B), Expansion, ClausePos0, ClausePos).
edcg_expand_clause((H==>>B), Expansion, ClausePos0, ClausePos) :-
    edcg_expand_clause_wrap((H==>>B), Expansion, ClausePos0, ClausePos).

edcg_expand_clause_wrap(Clause, Expansion, ClausePos0, ClausePos) :-
    % TODO: the first check should always succeed, so remove it
    (   validate_term_position(Clause, ClausePos0)  % for debugging
    ->  true
    ;   throw(error(invalid_term_position_read(Clause,ClausePos0), _))
    ),
    (   '_expand_clause'(Clause, Expansion, ClausePos0, ClausePos)
    ->  true
    ;   throw(error('FAILED_expand_clause'(Clause, Expansion, ClausePos0, ClausePos), _))
    ),
    (   % ground(ClausePos),  % TODO: uncomment this
        validate_term_position(Expansion, ClausePos) % for debugging
    ->  true
    ;   throw(error(invalid_term_position_expansion(Expansion, ClausePos), _))
    ).

% :- det('_expand_clause'/4).
% Perform EDCG macro expansion
% TODO: support ((H,PB-->>B) [same as regular DCG]

'_expand_clause'(Clause, Expansion, ClausePos0, ClausePos),
        ClausePos0 = parentheses_term_position(From,To,InnerClausePos0) =>
    ClausePos =      parentheses_term_position(From,To,InnerClausePos),
    '_expand_clause'(Clause, Expansion, InnerClausePos0, InnerClausePos).
'_expand_clause'((H-->>B), Expansion, ClausePos0, ClausePos),
        ClausePos0 = term_position(From,To,ArrowFrom,ArrowTo,[HPos,BPos]) =>
    ClausePos =      term_position(From,To,ArrowFrom,ArrowTo,[HxPos,BxPos]),
    Expansion = (TH:-TB),
    '_expand_head_body'(H, B, TH, TB, NewAcc, HPos,BPos, HxPos,BxPos),
    '_finish_acc'(NewAcc),
    !.
'_expand_clause'((H,PB==>>B), Expansion, _ClausePos0, _ClausePos) => % TODO: ClausePos
    Expansion = (TH,Guards=>TB2),
    '_expand_guard'(PB, Guards), % TODO: ClausePos
    '_expand_head_body'(H, B, TH, TB, NewAcc, _HPos,_BPos, _HxPos,_BxPos),
    '_finish_acc_ssu'(NewAcc, TB, TB2),
    !.
% H==>>B is essentially the same as H-->>B except that it produces =>
% But it needs to come last because otherwise H,PB would not be detected
'_expand_clause'((H==>>B), Expansion, ClausePos0, ClausePos),
        ClausePos0 = term_position(From,To,ArrowFrom,ArrowTo,[HPos,BPos]) =>
    ClausePos =      term_position(From,To,ArrowFrom,ArrowTo,[HxPos,BxPos]),
    Expansion = (TH=>TB2),
    '_expand_head_body'(H, B, TH, TB, NewAcc, HPos,BPos, HxPos,BxPos),
    '_finish_acc_ssu'(NewAcc, TB, TB2),
    !.

:- det('_expand_guard'/2).
% TODO: Do we want to expand the guards?
%       For now, just verify that they all start with '?'
'_expand_guard'((?G0,G2), Expansion) =>
    Expansion = (G, GE2),
    '_expand_guard_curly'(G0, G),
    '_expand_guard'(G2, GE2).
'_expand_guard'(?G0, G) =>
    '_expand_guard_curly'(G0, G).
'_expand_guard'(G, _) =>
    throw(error(type_error(guard,G),_)).

:- det('_expand_guard_curly'/2).
'_expand_guard_curly'({G}, G) :- !.
'_expand_guard_curly'(G, G).


:- det('_expand_head_body'/9).
'_expand_head_body'(H, B, TH, TB, NewAcc, HPos,BPos, HxPos,BxPos) :-
    functor(H, Na, Ar),
    '_has_hidden'(H, HList), % TODO: can backtrack - should it?
    debug(edcg,'Expanding ~w',[H]),
    '_new_goal'(H, HList, HArity, TH, HPos, HxPos),
    '_create_acc_pass'(HList, HArity, TH, Acc, Pass),
    '_expand_goal'(B, TB, Na/Ar, HList, Acc, NewAcc, Pass, BPos, BxPos),
    !.

% Expand a goal:
'_expand_goal'(Goal, Expansion, NaAr, HList, Acc, NewAcc, Pass, Pos, ExpandPos),
        Pos =   parentheses_term_position(From,To,InnerPos) =>
    ExpandPos = parentheses_term_position(From,To,InnerExpandPos),
    '_expand_goal'(Goal, Expansion, NaAr, HList, Acc, NewAcc, Pass, InnerPos, InnerExpandPos).
'_expand_goal'((G1,G2), Expansion, NaAr, HList, Acc, NewAcc, Pass, Pos, ExpandPos) =>
    Pos       = term_position(From,To,CommaFrom,CommaTo,[G1Pos,G2Pos]),
    ExpandPos = term_position(From,To,CommaFrom,CommaTo,[G1xPos,G2xPos]),
    Expansion = (TG1,TG2),
    '_expand_goal'(G1, TG1, NaAr, HList, Acc, MidAcc, Pass, G1Pos, G1xPos),
    '_expand_goal'(G2, TG2, NaAr, HList, MidAcc, NewAcc, Pass, G2Pos, G2xPos).
'_expand_goal'((G1->G2;G3), Expansion, NaAr, HList, Acc, NewAcc, Pass, Pos, ExpandPos) =>
    Pos       = term_position(From,To,SemicolonFrom,SemicolonTo,
                              [term_position(IfThenFrom,IfThenTo,ArrowFrom,ArrowTo,[G1Pos,G2Pos]), G3Pos]),
    ExpandPos = term_position(From,To,SemicolonFrom,SemicolonTo,
                              [term_position(IfThenFrom,IfThenTo,ArrowFrom,ArrowTo,[TG1Pos,TG2Pos]), TG3Pos]),
    Expansion = (TG1->TG2;TG3),
    '_expand_goal'(G1, TG1, NaAr, HList, Acc, MidAcc, Pass, G1Pos, TG1Pos),
    '_expand_goal'(G2, MG2, NaAr, HList, MidAcc, Acc1, Pass, G2Pos, TG2Pos),
    '_expand_goal'(G3, MG3, NaAr, HList, Acc, Acc2, Pass, G3Pos, TG3Pos),
    '_merge_acc'(Acc, Acc1, MG2, TG2, Acc2, MG3, TG3, NewAcc).
'_expand_goal'((G1*->G2;G3), Expansion, NaAr, HList, Acc, NewAcc, Pass, Pos, ExpandPos) =>
    Pos       = term_position(From,To,SemicolonFrom,SemicolonTo,
                              [term_position(IfThenFrom,IfThenTo,ArrowFrom,ArrowTo,[G1Pos,G2Pos]), G3Pos]),
    ExpandPos = term_position(From,To,SemicolonFrom,SemicolonTo,
                              [term_position(IfThenFrom,IfThenTo,ArrowFrom,ArrowTo,[TG1Pos,TG2Pos]), TG3Pos]),
    Expansion = (TG1*->TG2;TG3),
    '_expand_goal'(G1, TG1, NaAr, HList, Acc, MidAcc, Pass, G1Pos, TG1Pos),
    '_expand_goal'(G2, MG2, NaAr, HList, MidAcc, Acc1, Pass, G2Pos, TG2Pos),
    '_expand_goal'(G3, MG3, NaAr, HList, Acc, Acc2, Pass, G3Pos, TG3Pos),
    '_merge_acc'(Acc, Acc1, MG2, TG2, Acc2, MG3, TG3, NewAcc).
'_expand_goal'((G1;G2), Expansion, NaAr, HList, Acc, NewAcc, Pass, Pos, ExpandPos) =>
    Pos       = term_position(From,To,SemicolonFrom,SemicolonTo,[G1Pos,G2Pos]),
    ExpandPos = term_position(From,To,SemicolonFrom,SemicolonTo,[G1xPos,G2xPos]),
    Expansion = (TG1;TG2),
    '_expand_goal'(G1, MG1, NaAr, HList, Acc, Acc1, Pass, G1Pos, G1xPos),
    '_expand_goal'(G2, MG2, NaAr, HList, Acc, Acc2, Pass, G2Pos, G2xPos),
    '_merge_acc'(Acc, Acc1, MG1, TG1, Acc2, MG2, TG2, NewAcc).
'_expand_goal'((G1->G2), Expansion, NaAr, HList, Acc, NewAcc, Pass, Pos, ExpandPos) =>
    Pos       = term_position(From,To,ArrowFrom,ArrowTo,[G1Pos,G2Pos]),
    ExpandPos = term_position(From,To,ArrowFrom,ArrowTo,[G1xPos,G2xPos]),
    Expansion = (TG1->TG2),
    '_expand_goal'(G1, TG1, NaAr, HList, Acc, MidAcc, Pass, G1Pos, G1xPos),
    '_expand_goal'(G2, TG2, NaAr, HList, MidAcc, NewAcc, Pass, G2Pos, G2xPos).
'_expand_goal'((G1*->G2), Expansion, NaAr, HList, Acc, NewAcc, Pass, Pos, ExpandPos) =>
    Pos       = term_position(From,To,ArrowFrom,ArrowTo,[G1Pos,G2Pos]),
    ExpandPos = term_position(From,To,ArrowFrom,ArrowTo,[G1xPos,G2xPos]),
    Expansion = (TG1*->TG2),
    '_expand_goal'(G1, TG1, NaAr, HList, Acc, MidAcc, Pass, G1Pos, G1xPos),
    '_expand_goal'(G2, TG2, NaAr, HList, MidAcc, NewAcc, Pass, G2Pos, G2xPos).
'_expand_goal'((\+G), Expansion, NaAr, HList, Acc, NewAcc, Pass, Pos, ExpandPos) =>
    Pos       =  term_position(From,To,NotFrom,NotTo,[GPos]),
    ExpandPos = term_position(From,To,NotFrom,NotTo,[GxPos]),
    Expansion = (\+TG),
    NewAcc = Acc,
    '_expand_goal'(G, TG, NaAr, HList, Acc, _TempAcc, Pass, GPos, GxPos).
'_expand_goal'({G}, Expansion, _, _, Acc, NewAcc, _, _Pos, _ExpandPos) =>
    Expansion = G,
    NewAcc = Acc.
'_expand_goal'(insert(X,Y), Expansion, _, _, Acc, NewAcc, _, Pos, ExpandPos) =>
    Pos = term_position(_From,_To,_InsertFrom,_InsertTo,[_XPos,_YPos]),
    ExpandPos = _, % TODO: expanded goal location
    Expansion = (LeftA=X),
    '_replace_acc'(dcg, LeftA, RightA, Y, RightA, Acc, NewAcc), !.
'_expand_goal'(insert(X,Y):A, Expansion, _, _, Acc, NewAcc, _, _Pos, _ExpandPos) => % TODO: expanded goal location
    Expansion = (LeftA=X),
    '_replace_acc'(A, LeftA, RightA, Y, RightA, Acc, NewAcc),
    debug(edcg,'Expanding accumulator goal: ~w',[insert(X,Y):A]),
    !.
% Force hidden arguments in L to be appended to G:
'_expand_goal'((G:A), TG, _, _HList, Acc, NewAcc, Pass, Pos, ExpandPos),
        \+'_list'(G),
        '_has_hidden'(G, []) =>
    Pos = term_position(_From,_To,_ColonFrom,_ColonTo,[_GPos,_APos]),
    ExpandPos = _, % TODO: expanded goal location
    '_make_list'(A, AList),
    '_new_goal'(G, AList, GArity, TG, _, _),
    '_use_acc_pass'(AList, GArity, TG, Acc, NewAcc, Pass).
% Use G's regular hidden arguments & override defaults for those arguments
% not in the head:
'_expand_goal'((G:A), TG, _, _HList, Acc, NewAcc, Pass, Pos, ExpandPos),
        \+'_list'(G),
        '_has_hidden'(G, GList), GList\==[] =>
    Pos = term_position(_From,_To,_ColonFrom,_ColonTo,[_G1Pos,_G2Pos]),
    ExpandPos = _, % TODO: expanded goal location
    '_make_list'(A, L),
    '_new_goal'(G, GList, GArity, TG, _, _),
    '_replace_defaults'(GList, NGList, L),
    '_use_acc_pass'(NGList, GArity, TG, Acc, NewAcc, Pass).
'_expand_goal'((L:A), Joiner, NaAr, _, Acc, NewAcc, _, Pos, ExpandPos),
        '_list'(L) =>
    Pos = term_position(_From,_To,_ColonFrom,_ColonTo,[_G1Pos,_G2Pos]),
    ExpandPos = _, % TODO: expanded goal location
    '_joiner'(L, A, NaAr, Joiner, Acc, NewAcc).
'_expand_goal'(L, Joiner, NaAr, _, Acc, NewAcc, _, _Pos, _ExpandPos), % TODO: expanded goal location
        '_list'(L) =>
    '_joiner'(L, dcg, NaAr, Joiner, Acc, NewAcc).
'_expand_goal'((X/A/Y), Expansion, _, _, Acc, NewAcc, _, Pos, ExpandPos),
        member(acc(A,X,Y), Acc),
        var(X), var(Y), atomic(A) =>
    Pos = term_position(_From,_To,_Slash2From,_Slash2To,
                        [term_position(_XFrom,_XTo,_Slash1From,_Slash1To, [_XPos,_APos]),
                         _YPos]),
    ExpandPos = _, % TODO: expanded goal location
    Expansion = true,
    NewAcc = Acc.
'_expand_goal'((X/A), Expansion, _, _, Acc, NewAcc, _, Pos, ExpandPos),
        atomic(A),
        member(acc(A,X,_), Acc) =>
    Pos = term_position(_From,_To,_SlashFrom,_SlashTo,[_XPos,_APos]),
    ExpandPos = _, % TODO: expanded goal location
    Expansion = true,
    NewAcc = Acc,
    debug(edcg,'Expanding accumulator goal: ~w',[X/A]),
    !.
'_expand_goal'((X/A), Expansion, _, _, Acc, NewAcc, Pass, Pos, ExpandPos),
        atomic(A),
        member(pass(A,X), Pass) =>
    Pos = term_position(_From,_To,_SlashFrom,_SlashTo,[_XPos,_APos]),
    ExpandPos = _, % TODO: expanded goal location
    Expansion = true,
    NewAcc = Acc,
    debug(edcg,'Expanding passed argument goal: ~w',[X/A]),
    !.
'_expand_goal'((A/X), Expansion, _, _, Acc, NewAcc, _, Pos, ExpandPos),
        atomic(A),
        member(acc(A,_,X), Acc) =>
    Pos = term_position(_From,_To,_SlashFrom,_SlashTo,[_APos,_XPos]),
    ExpandPos = _, % TODO: expanded goal location
    Expansion = true,
    NewAcc = Acc.
'_expand_goal'((X/Y), true, NaAr, _, Acc, NewAcc, _, Pos, ExpandPos) =>
    Pos = term_position(_From,_To,_SlashFrom,_SlashTo,[_XPos,_YPos]),
    ExpandPos = _, % TODO: expanded goal location
    NewAcc = Acc,
    print_message(warning,missing_hidden_parameter(NaAr,X/Y)).
% Defaulty cases:
'_expand_goal'(G, TG, _HList, _, Acc, NewAcc, Pass, Pos, ExpandPos) =>
    '_has_hidden'(G, GList), !,
    '_new_goal'(G, GList, GArity, TG, Pos, ExpandPos),
    '_use_acc_pass'(GList, GArity, TG, Acc, NewAcc, Pass).

% ==== The following was originally acc-pass.pl ====

% Operations on the Acc and Pass data structures:

:- det('_create_acc_pass'/5).
% Create the Acc and Pass data structures:
% Acc contains terms of the form acc(A,LeftA,RightA) where A is the name of an
% accumulator, and RightA and LeftA are the accumulating parameters.
% Pass contains terms of the form pass(A,Arg) where A is the name of a passed
% argument, and Arg is the argument.
'_create_acc_pass'([], _, _, Acc, Pass) =>
    Acc = [],
    Pass = [].
'_create_acc_pass'([A|AList], Index, TGoal, Acc2, Pass),
    '_is_acc'(A) =>
    Acc2 = [acc(A,LeftA,RightA)|Acc],
    Index1 is Index+1,
    arg(Index1, TGoal, LeftA),
    Index2 is Index+2,
    arg(Index2, TGoal, RightA),
    '_create_acc_pass'(AList, Index2, TGoal, Acc, Pass).
'_create_acc_pass'([A|AList], Index, TGoal, Acc, Pass2),
    '_is_pass'(A) =>
    Pass2 = [pass(A,Arg)|Pass],
    Index1 is Index+1,
    arg(Index1, TGoal, Arg),
    '_create_acc_pass'(AList, Index1, TGoal, Acc, Pass).
'_create_acc_pass'([A|_AList], _Index, _TGoal, _Acc, _Pass),
    \+'_is_acc'(A),
    \+'_is_pass'(A) =>
    print_message(error,not_a_hidden_param(A)).


:- det('_use_acc_pass'/6).
% Use the Acc and Pass data structures to create the arguments of a body goal:
% Add the hidden parameters named in GList to the goal.
'_use_acc_pass'([], _, _, Acc, NewAcc, _) =>
    NewAcc = Acc.
% 1a. The accumulator A is used in the head:
%     Note: the '_replace_acc' guard instantiates MidAcc
'_use_acc_pass'([A|GList], Index, TGoal, Acc, NewAcc, Pass),
    '_replace_acc'(A, LeftA, RightA, MidA, RightA, Acc, MidAcc) =>
    Index1 is Index+1,
    arg(Index1, TGoal, LeftA),
    Index2 is Index+2,
    arg(Index2, TGoal, MidA),
    '_use_acc_pass'(GList, Index2, TGoal, MidAcc, NewAcc, Pass).
% 1b. The accumulator A is not used in the head:
'_use_acc_pass'([A|GList], Index, TGoal, Acc, NewAcc, Pass),
    '_acc_info'(A, LStart, RStart) =>
    Index1 is Index+1,
    arg(Index1, TGoal, LStart),
    Index2 is Index+2,
    arg(Index2, TGoal, RStart),
    '_use_acc_pass'(GList, Index2, TGoal, Acc, NewAcc, Pass).
% 2a. The passed argument A is used in the head:
'_use_acc_pass'([A|GList], Index, TGoal, Acc, NewAcc, Pass),
    '_is_pass'(A),
    member(pass(A,Arg), Pass) =>
    Index1 is Index+1,
    arg(Index1, TGoal, Arg),
    '_use_acc_pass'(GList, Index1, TGoal, Acc, NewAcc, Pass).
% 2b. The passed argument A is not used in the head:
'_use_acc_pass'([A|GList], Index, TGoal, Acc, NewAcc, Pass),
    '_pass_info'(A, AStart) =>
    Index1 is Index+1,
    arg(Index1, TGoal, AStart),
    '_use_acc_pass'(GList, Index1, TGoal, Acc, NewAcc, Pass).
% 3. Defaulty case when A does not exist:
'_use_acc_pass'([A|_GList], _Index, _TGoal, Acc, Acc, _Pass) =>
    print_message(error,not_a_hidden_param(A)).

:- det('_finish_acc'/1).
% Finish the Acc data structure:
% Link its Left and Right accumulation variables together in pairs:
% TODO: does this work correctly in the presence of cuts? ("!") - see README
'_finish_acc'([]).
'_finish_acc'([acc(_,Link,Link)|Acc]) :- '_finish_acc'(Acc).

:- det('_finish_acc_ssu'/3).
% TODO: add Layout info, to match the added LeftA=RightA goals
'_finish_acc_ssu'([], TB, TB).
'_finish_acc_ssu'([acc(_,LeftA,RightA)|Acc], TB0, TB) :-
    '_finish_acc_ssu'(Acc, (LeftA=RightA,TB0), TB).

% Replace elements in the Acc data structure:
% Succeeds iff replacement is successful.
'_replace_acc'(A, L1, R1, L2, R2, Acc, NewAcc) :-
    member(acc(A,L1,R1), Acc), !,
    '_replace'(acc(A,_,_), acc(A,L2,R2), Acc, NewAcc).

:- det('_merge_acc'/8).
% Combine two accumulator lists ('or'ing their values)
'_merge_acc'([], [], G1, G1, [], G2, G2, []) :- !.
'_merge_acc'([acc(Acc,OL,R)|Accs], [acc(Acc,L1,R)|Accs1], G1, NG1,
         [acc(Acc,L2,R)|Accs2], G2, NG2, [acc(Acc,NL,R)|NewAccs]) :- !,
    ( ( OL == L1, OL \== L2 ) ->
      MG1 = (G1,L1=L2), MG2 = G2, NL = L2
        ; ( OL == L2, OL \== L1 ) ->
      MG2 = (G2,L2=L1), MG1 = G1, NL = L1
        ; MG1 = G1, MG2 = G2, L1 = L2, L2 = NL ),
    '_merge_acc'(Accs, Accs1, MG1, NG1, Accs2, MG2, NG2, NewAccs).

% ==== The following was originally generic-util.pl ====

% Generic utilities special-util.pl

:- det('_match'/4).
% Match arguments L, L+1, ..., H of the predicates P and Q:
'_match'(L, H, _, _) :- L>H, !.
'_match'(L, H, P, Q) :- L=<H, !,
    arg(L, P, A),
    arg(L, Q, A),
    L1 is L+1,
    '_match'(L1, H, P, Q).


'_list'(L) :- nonvar(L), L=[_|_], !.
'_list'(L) :- L==[], !.

:- det('_make_list'/2).
'_make_list'(A, [A]) :- \+'_list'(A), !.
'_make_list'(L,   L) :-   '_list'(L), !.

:- det('_replace'/4).
% replace(Elem, RepElem, List, RepList)
'_replace'(_, _, [], []) :- !.
'_replace'(A, B, [A|L], [B|R]) :- !,
    '_replace'(A, B, L, R).
'_replace'(A, B, [C|L], [C|R]) :-
    \+C=A, !,
    '_replace'(A, B, L, R).

% ==== The following was originally special-util.pl ====

% Specialized utilities:

% Given a goal Goal and a list of hidden parameters GList
% create a new goal TGoal with the correct number of arguments.
% Also return the arity of the original goal.
'_new_goal'(Goal, GList, GArity, TGoal, GPos, GxPos) :-
    functor(Goal, Name, GArity),
    '_number_args'(GList, GArity, TArity),
    functor(TGoal, Name, TArity),
    '_match'(1, GArity, Goal, TGoal),
    ExtraArity is TArity - GArity,
    length(Extras, ExtraArity),
    term_pos_expand(GPos, Extras, GxPos).

% Add the number of arguments needed for the hidden parameters:
'_number_args'([], N, N).
'_number_args'([A|List], N, M) :-
    '_is_acc'(A), !,
    N2 is N+2,
    '_number_args'(List, N2, M).
'_number_args'([A|List], N, M) :-
    '_is_pass'(A), !,
    N1 is N+1,
    '_number_args'(List, N1, M).
'_number_args'([_|List], N, M) :- !,
    % error caught elsewhere
    '_number_args'(List, N, M).

% Give a list of G's hidden parameters:
'_has_hidden'(G, GList) :-
    functor(G, GName, GArity),
    (   pred_info(GName, GArity, GList)
    ->  true
    ;   GList = []
    ).

% Create an ExpandPos for a goal's Pos with expanded parameters
term_pos_expand(Pos, _, _ExpandPos), var(Pos) => true. % TODO: remove
term_pos_expand(From-To, [], ExpandPos) =>
    ExpandPos = From-To.
term_pos_expand(From-To, GList, ExpandPos) =>
    ExpandPos = term_position(From,To,From,To,PosExtra),
    maplist(pos_extra(To,To), GList, PosExtra).
term_pos_expand(term_position(From,To,FFrom,FTo,ArgsPos), GList, ExpandPos) =>
    ExpandPos = term_position(From,To,FFrom,FTo,ArgsPosExtra),
    maplist(pos_extra(To,To), GList, PosExtra),
    append(ArgsPos, PosExtra, ArgsPosExtra).
term_pos_expand(brace_term_position(From,To,ArgsPos), GList, ExpandPos) =>
    ExpandPos = btrace_term_position(From,To,ArgsPosExtra),
    maplist(pos_extra(To,To), GList, PosExtra),
    append(ArgsPos, PosExtra, ArgsPosExtra).
% Other things, such as `string_position` and
% `parentheses_term_position, shouldn't appear.
% And list_position (for accumulators) is handled separately

% Map an existing From,To to From-To. The 3rd parameter is from Hlist
% and is only used for controlling the number of elements in the
% calling maplist.
pos_extra(From, To, _, From-To).

% Succeeds if A is an accumulator:
'_is_acc'(A), atomic(A) => '_acc_info'(A, _, _, _, _, _, _).
'_is_acc'(A), functor(A, N, 2) => '_acc_info'(N, _, _, _, _, _, _).

% Succeeds if A is a passed argument:
'_is_pass'(A), atomic(A) => '_pass_info'(A, _).
'_is_pass'(A), functor(A, N, 1) => '_pass_info'(N, _).

% Get initial values for the accumulator:
'_acc_info'(AccParams, LStart, RStart) :-
    functor(AccParams, Acc, 2),
    '_is_acc'(Acc), !,
    arg(1, AccParams, LStart),
    arg(2, AccParams, RStart).
'_acc_info'(Acc, LStart, RStart) :-
    '_acc_info'(Acc, _, _, _, _, LStart, RStart).

% Isolate the internal database from the user database:
'_acc_info'(Acc, Term, Left, Right, Joiner, LStart, RStart) :-
    acc_info(Acc, Term, Left, Right, Joiner, LStart, RStart).
'_acc_info'(Acc, Term, Left, Right, Joiner, _, _) :-
    acc_info(Acc, Term, Left, Right, Joiner).
'_acc_info'(dcg, Term, Left, Right, Left=[Term|Right], _, []).

% Get initial value for the passed argument:
% Also, isolate the internal database from the user database.
'_pass_info'(PassParam, PStart) :-
    functor(PassParam, Pass, 1),
    '_is_pass'(Pass), !,
    arg(1, PassParam, PStart).
'_pass_info'(Pass, PStart) :-
    pass_info(Pass, PStart).
'_pass_info'(Pass, _) :-
    pass_info(Pass).

% Calculate the joiner for an accumulator A:
'_joiner'([], _, _, true, Acc, Acc).
'_joiner'([Term|List], A, NaAr, (Joiner,LJoiner), Acc, NewAcc) :-
    '_replace_acc'(A, LeftA, RightA, MidA, RightA, Acc, MidAcc),
    '_acc_info'(A, Term, LeftA, MidA, Joiner, _, _), !,
    '_joiner'(List, A, NaAr, LJoiner, MidAcc, NewAcc).
% Defaulty case:
'_joiner'([_Term|List], A, NaAr, Joiner, Acc, NewAcc) :-
    print_message(warning, missing_accumulator(NaAr,A)),
    '_joiner'(List, A, NaAr, Joiner, Acc, NewAcc).

% Replace hidden parameters with ones containing initial values:
'_replace_defaults'([], [], _).
'_replace_defaults'([A|GList], [NA|NGList], AList) :-
    '_replace_default'(A, NA, AList),
    '_replace_defaults'(GList, NGList, AList).

'_replace_default'(A, NewA, AList) :-  % New initial values for accumulator.
    functor(NewA, A, 2),
    member(NewA, AList), !.
'_replace_default'(A, NewA, AList) :-  % New initial values for passed argument.
    functor(NewA, A, 1),
    member(NewA, AList), !.
'_replace_default'(A, NewA, _) :-      % Use default initial values.
    A=NewA.

% ==== The following was originally messages.pl ====

:- multifile prolog:message//1.

prolog:message(missing_accumulator(Predicate,Accumulator)) -->
    ['In ~w the accumulator ''~w'' does not exist'-[Predicate,Accumulator]].
prolog:message(missing_hidden_parameter(Predicate,Term)) -->
    ['In ~w the term ''~w'' uses a non-existent hidden parameter.'-[Predicate,Term]].
prolog:message(not_a_hidden_param(Name)) -->
    ['~w is not a hidden parameter'-[Name]].

% === The following are for debugging term_expansion/4

% TODO: replace by prolog_clause:valid_term_position/2

%! validate_term_position(+Term, @TermPos) is semidet.
% Check that a Term has an appropriate TermPos layout.
% An incorrect TermPos results in either failure of this predicate or
% an error.
%
% If a position in TermPos is a variable, the validation of
% the corresponding part of Term succeeds. This matches the
% term_expansion/4 treats "unknown" layout information.
% If part of a TermPos is given, then all its "from" and "to"
% information must be specified; for example, `string_position
%
% @param Term Any Prolog term including a variable).
% @param TermPos The detailed layout of the term, for example
%        from using =|read_term(Term, subterm_positions(TermPos)|=.
%
% This should always succeed:
% ==
%    read_term(Term, [subterm_positions(TermPos)]),
%    valid_term_position(Term, TermPos)
% ==

% @throws existence_error(matching_rule, Subterm) if a subterm of Term is
%         inconsistent with the corresponding part of TermPos.

% @see read_term/2, read_term/3, term_string/3
% @see expand_term/4, term_expansion/4, expand_goal/4, expand_term/4
% @see clause_info/4, clause_info/5
% @see prolog_clause:unify_clause_hook/5

validate_term_position(Term, TermPos) :-
    validate_term_position(0, 0x7fffffffffffffff, Term, TermPos).

validate_term_position(OuterFrom, OuterTo, _Term, TermPos), var(TermPos),
        OuterFrom =< OuterTo => true.
validate_term_position(OuterFrom, OuterTo, Var, From-To),
        var(Var),
        valid_term_position_from_to(OuterFrom, OuterTo, From, To) => true.
validate_term_position(OuterFrom, OuterTo, Atom, From-To),
        atom(Atom),
        valid_term_position_from_to(OuterFrom, OuterTo, From, To) => true.
validate_term_position(OuterFrom, OuterTo, Number, From-To),
        number(Number),
        valid_term_position_from_to(OuterFrom, OuterTo, From, To) => true.
validate_term_position(OuterFrom, OuterTo, [], From-To),
        valid_term_position_from_to(OuterFrom, OuterTo, From, To) => true.
validate_term_position(OuterFrom, OuterTo, String, string_position(From,To)),
        current_prolog_flag(double_quotes, string),
        string(String),
        valid_term_position_from_to(OuterFrom, OuterTo, From, To) => true.
validate_term_position(OuterFrom, OuterTo, String, string_position(From,To)),
        current_prolog_flag(double_quotes, codes),
        is_of_type(codes, String),
        valid_term_position_from_to(OuterFrom, OuterTo, From, To) => true.
validate_term_position(OuterFrom, OuterTo, String, string_position(From,To)),
        current_prolog_flag(double_quotes, chars),
        is_of_type(chars, String),
        valid_term_position_from_to(OuterFrom, OuterTo, From, To) => true.
validate_term_position(OuterFrom, OuterTo, String, string_position(From,To)),
        current_prolog_flag(double_quotes, atom),
        atom(String),
        valid_term_position_from_to(OuterFrom, OuterTo, From, To) => true.
validate_term_position(OuterFrom, OuterTo, {Arg}, brace_term_position(From,To,ArgPos)),
        valid_term_position_from_to(OuterFrom, OuterTo, From, To) =>
    validate_term_position(From, To, Arg, ArgPos).
validate_term_position(OuterFrom, OuterTo, [Hd|Tl], list_position(From,To,ElemsPos,none)),
        valid_term_position_from_to(OuterFrom, OuterTo, From, To) =>
    term_position_list_tail([Hd|Tl], _HdPart, []),
    maplist(validate_term_position, [Hd|Tl], ElemsPos).
validate_term_position(OuterFrom, OuterTo, [Hd|Tl], list_position(From, To, ElemsPos, TailPos)),
        valid_term_position_from_to(OuterFrom, OuterTo, From, To) =>
    term_position_list_tail([Hd|Tl], HdPart, Tail),
    maplist(validate_term_position(From,To), HdPart, ElemsPos),
    validate_term_position(Tail, TailPos).
validate_term_position(OuterFrom, OuterTo, Term, term_position(From,To, FFrom,FTo,SubPos)),
        valid_term_position_from_to(OuterFrom, OuterTo, From, To) =>
    compound_name_arguments(Term, Name, Arguments),
    validate_term_position(Name, FFrom-FTo),
    maplist(validate_term_position(From,To), Arguments, SubPos).
validate_term_position(OuterFrom, OuterTo, Dict, dict_position(From,To,TagFrom,TagTo,KeyValuePosList)),
        valid_term_position_from_to(OuterFrom, OuterTo, From, To) =>
    dict_pairs(Dict, Tag, Pairs),
    validate_term_position(Tag, TagFrom-TagTo),
    foldl(validate_term_position_dict(From,To), Pairs, KeyValuePosList, []).
% key_value_position(From, To, SepFrom, SepTo, Key, KeyPos, ValuePos)
% is handled in validate_term_position_dict.
validate_term_position(OuterFrom, OuterTo, Term, parentheses_term_position(From,To,ContentPos)),
        valid_term_position_from_to(OuterFrom, OuterTo, From, To) =>
    validate_term_position(From, To, Term, ContentPos).
validate_term_position(OuterFrom, OuterTo, _Term, quasi_quotation_position(From,To,SyntaxTerm,SyntaxPos,_ContentPos)),
        valid_term_position_from_to(OuterFrom, OuterTo, From, To) =>
    validate_term_position(From, To, SyntaxTerm, SyntaxPos).

valid_term_position_from_to(OuterFrom, OuterTo, From, To) :-
    integer(OuterFrom),
    integer(OuterTo),
    integer(From),
    integer(To),
    OuterFrom =< OuterTo,
    From =< To,
    OuterFrom =< From,
    To =< OuterTo.

:- det(validate_term_position_dict/3).
validate_term_position_dict(OuterFrom, OuterTo, Key-Value, KeyValuePosList0, KeyValuePosList1) :-
    selectchk(key_value_position(From,To,SepFrom,SepTo,Key,KeyPos,ValuePos),
              KeyValuePosList0, KeyValuePosList1),
    valid_term_position_from_to(OuterFrom, OuterTo, From, To),
    valid_term_position_from_to(OuterFrom, OuterTo, SepFrom, SepTo),
    SepFrom >= OuterFrom,
    validate_term_position(From, SepFrom, Key, KeyPos),
    validate_term_position(SepTo, To, Value, ValuePos).

:- det(term_position_list_tail/3).
%! term_position_list_tail(@List, -HdPart, -Tail) Is det.
% Similar to =|append(HdPart, [Tail], List)|= for proper lists,
% but also works for inproper lists, in which case it unifies
% Tail with the tail of the partial list. HdPart is always a
% proper list:
% ==
% ?- prolog_source:term_position_list_tail([a,b,c], Hd, Tl).
% Hd = [a, b, c],
% Tl = [].
% ?- prolog_source:term_position_list_tail([a,b|X], Hd, Tl).
% X = Tl,
% Hd = [a, b].
% ==
term_position_list_tail([X|Xs], HdPart, Tail) =>
    HdPart = [X|HdPart2],
    term_position_list_tail(Xs, HdPart2, Tail).
term_position_list_tail(Tail0, HdPart, Tail) =>
    HdPart = [],
    Tail0 = Tail.

end_of_file.

:- use_module('../prolog/edcg.pl').  % :- use_module(library(edcg)).

% Declare accumulators
acc_info(adder, X, In, Out, plus(X,In,Out)).

% Declare predicates using these hidden arguments
pred_info(len,0,[adder,dcg]).
pred_info(increment,0,[adder]).

increment -->>
    [1]:adder.


len(Xs,N) :-
    len(0,N,Xs,[]).

len -->>
    [_],
    !,
    increment,
    len.
len -->>
    [].


:- use_module(library(plunit)).

:- begin_tests(edcg_synopsis).

test(t1) :-
    len([],0).

test(t2) :-
    len([a],1).

test(t3) :-
    len([a,b,a],3).

:- end_tests(edcg_synopsis).

end_of_file.

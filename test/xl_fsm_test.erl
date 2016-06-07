%%%-------------------------------------------------------------------
%%% @author Guiqing Hai <gary@XL59.com>
%%% @copyright (C) 2016, Guiqing Hai
%%% @doc
%%%
%%% @end
%%% Created :  7 Jun 2016 by Guiqing Hai <gary@XL59.com>
%%%-------------------------------------------------------------------
-module(xl_fsm_test).
-include_lib("eunit/include/eunit.hrl").

s1_entry(S) ->
    S1 = S#{output => "Hello world!", sign => s2},
    {ok, S1}.

s2_entry(S) ->
    S1 = S#{output => "State 2", sign => s1},
    {ok, S1}.

work_now(S) ->
    {stop, done, S#{output => pi}}.
    
work_slowly(_S) ->
    receive
        {xlx, {stop, _Reason}} ->
            erlang:exit(pi)
    end.

work_fast(#{fsm := Fsm, state_name := Name}) ->
    S0 = xl_state:call(Fsm, state),
    ?assertMatch(#{state_name := Name}, S0),
    erlang:exit(pi).

%% Set counter 2 as pitfall.
s_react({xlx, _, "error_test"}, #{counter := Count}) when Count =:= 2 ->
    error(error_test);
s_react({xlx, _, "error_test"}, S) ->
    Count = maps:get(counter, S, 0),
    {ok, Count + 1, S#{counter => Count + 1}};
s_react(transfer, S) ->
    {stop, transfer, S};
s_react({xlx, _, {get, state}}, S) ->
    {ok, maps:get(state_name, S), S};
s_react({xlx, {transfer, Next}}, S) ->
    {stop, transfer, S#{sign => Next}};
s_react(_, S) ->  % drop unknown message.
    {ok, S}.

create_fsm() ->
    S1 = #{state_name => state1,
           react => fun s_react/2,
           entry => fun s1_entry/1},
    S2 = #{state_name => state2,
           react => fun s_react/2,
           entry => fun s2_entry/1},
    S3 = #{state_name => state3,
           work_mode => block,
           do => fun work_now/1,
           react => fun s_react/2,
           entry => fun s1_entry/1},
    S4 = #{state_name => state4,
           do => fun work_slowly/1,
           react => fun s_react/2,
           entry => fun s2_entry/1},
    S5 = #{state_name => state5,
           do => fun work_fast/1,
           react => fun s_react/2,
           entry => fun s2_entry/1},
    States = #{start => S1,
               state1 => S1,
               state2 => S2,
               state3 => S3,
               state4 => S4,
               state5 => S5,
               {state1, s1} => S1,
               {state1, s2} => S2,
               {state1, s3} => S3,
               {state2, s1} => S1,
               {state2, s2} => S2,
               {state2, s4} => S4,
               {state3, s1} => S1,
               {state3, s2} => S2,
               {state3, s4} => S4,
               {state4, s5} => S5,
               {state4, s2} => S2,
               {state4, s3} => S3,
               {state5, s1} => S1,
               {state5, s2} => S2,
               {state5, s3} => S3},
    xl_state:create(xl_fsm, [{states, States}]).
    
fsm_test() ->
    Fsm = create_fsm(),
    %% standalone process for each state.
    Fsm1 = Fsm#{max_traces => 4,
                recovery =>
                    {state2, #{recovery => {reset, -1, #{new_data => 1}}}}},
    fsm_test_cases(Fsm1).

fsm_recovery_test() ->
    Fsm = create_fsm(),
    Fsm1 = Fsm#{max_pending_size => 5,
                recovery => {0, #{recovery => {reset, 0, #{}}}}},
    fsm_test_cases(Fsm1).

fsm_test_cases(Fsm) ->
    %% Prepare.
    erlang:process_flag(trap_exit, true),
    error_logger:tty(false),
    {ok, Pid} = xl_state:start_link(Fsm),
    %% Basic actions.
    ?assertMatch(state1, xl_state:call(Pid, {get, state})),
    ?assertMatch(#{state_name := state1}, gen_server:call(Pid, state)),
    Pid ! transfer,
    timer:sleep(10),
    ?assert(state2 =:= gen_server:call(Pid, {get, state})),
    ?assert(2 =:=  gen_server:call(Pid, step)),
    %% Failover test.
    ?assert(1 =:= xl_state:call(Pid, "error_test")),
    ?assert(2 =:= xl_state:call(Pid, "error_test")),
    catch xl_state:call(Pid, "error_test", 0),
    SelfHeal = xl_state:call(Pid, max_pending_size),
    try xl_state:call(Pid, {get, state}, 5) of
        state2 ->
            ?assert(SelfHeal =:= 5)
    catch
        exit: timeout ->
            ?assert(SelfHeal =:= undefined)
    end,
    timer:sleep(10),
    %% Worker inside state test.
    gen_server:cast(Pid, {transfer, s4}),
    timer:sleep(10),
    ?assertMatch(state4, xl_state:call(Pid, {get, state})),
    gen_server:cast(Pid, {transfer, s5}),
    timer:sleep(10),
    ?assert(state5 =:= xl_state:call(Pid, {get, state})),
    ?assert(running =:= xl_state:call(Pid, status)),
    gen_server:cast(Pid, {transfer, s3}),
    timer:sleep(10),
    ?assert(state2 =:= xl_state:call(Pid, {get, state})),
    %% Failover test again.
    ?assert(1 =:= xl_state:call(Pid, "error_test")),
    ?assert(2 =:= xl_state:call(Pid, "error_test")),
    catch xl_state:call(Pid, "error_test", 1),
    %% Stop. 
    timer:sleep(10),
    {Sign, Final} = xl_state:stop(Pid),
    #{traces := Trace} = Final,
    case maps:get(max_traces, Final, infinity) of
        infinity ->  % recovery_test: 1->*2->2->2->4->5->3->*2->2 =>2
            ?assertMatch(s1, Sign),
            ?assertMatch(#{step := 10}, Final),
            ?assertMatch(7, length(Trace));
        MaxTrace ->  % fsm_test: 1->*2->2->2->4->5->3->*2->3->3 =>2
            ?assertMatch(s1, Sign),
            ?assertMatch(#{step := 11, new_data := 1}, Final),
            ?assertMatch(MaxTrace, length(Trace))
    end.

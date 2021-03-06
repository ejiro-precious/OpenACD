%%	The contents of this file are subject to the Common Public Attribution
%%	License Version 1.0 (the “License”); you may not use this file except
%%	in compliance with the License. You may obtain a copy of the License at
%%	http://opensource.org/licenses/cpal_1.0. The License is based on the
%%	Mozilla Public License Version 1.1 but Sections 14 and 15 have been
%%	added to cover use of software over a computer network and provide for
%%	limited attribution for the Original Developer. In addition, Exhibit A
%%	has been modified to be consistent with Exhibit B.
%%
%%	Software distributed under the License is distributed on an “AS IS”
%%	basis, WITHOUT WARRANTY OF ANY KIND, either express or implied. See the
%%	License for the specific language governing rights and limitations
%%	under the License.
%%
%%	The Original Code is OpenACD.
%%
%%	The Initial Developers of the Original Code is
%%	Andrew Thompson and Micah Warren.
%%
%%	All portions of the code written by the Initial Developers are Copyright
%%	(c) 2008-2009 SpiceCSM.
%%	All Rights Reserved.
%%
%%	Contributor(s):
%%
%%	Andrew Thompson <andrew at hijacked dot us>
%%	Micah Warren <micahw at lordnull dot com>
%%

%% @doc Connection to the local authenication cache and integration to another module.
%% Authentication is first checked by the integration module (if any).  If that fails,
%% this module will fall back to it's local cache in the mnesia 'agent_auth' table.
%% the cache table is both ram and disc copies on all nodes.

-module(agent_auth_mnesia).

-include("log.hrl").
-include("call.hrl").
-include("agent.hrl").
-include_lib("stdlib/include/qlc.hrl").

-ifdef(TEST).
	-include_lib("eunit/include/eunit.hrl").
-endif.


%% API
-export([
	start/0,
	auth/2,
	build_tables/0,
	upgrade_v1_table/0
]).
-export([
	cache/6,
	destroy/2,
	merge/3,
	add_agent/7,
	add_agent/5,
	add_agent/1,
	set_agent/2,
	get_agent/1,
	get_agent/2,
	get_agents/0,
	get_agents/1,
	set_endpoint/3,
	drop_endpoint/2,
	set_extended_prop/3,
	drop_extended_prop/2,
	get_extended_prop/2,
	encode_password/1
]).
-export([
	new_profile/1,
	new_profile/2,
	set_profile/2,
	set_profile/3,
	get_profile/1,
	get_profiles/0,
	destroy_profile/1
	]).
%% API for release options
-export([
	new_release/1,
	destroy_release/1,
	destroy_release/2,
	update_release/2,
	get_releases/0
	]).
%% helper funcs for merge.
-export([
	query_agent_auth/1,
	query_profiles/1,
	query_release/1
]).

%%====================================================================
%% API
%%====================================================================

start() ->
	%% Agents
	cpx_hooks:set_hook(mn_get_agents, get_agents, ?MODULE, get_agents, [], 100),
	cpx_hooks:set_hook(mn_get_agents_by_profile, get_agents_by_profile, ?MODULE, get_agents, [], 100),
	cpx_hooks:set_hook(mn_get_agent, get_agent, ?MODULE, get_agent, [], 100),
	cpx_hooks:set_hook(mn_add_agent, add_agent, ?MODULE, add_agent, [], 100),
	cpx_hooks:set_hook(mn_set_agent, set_agent, ?MODULE, set_agent, [], 100),
	cpx_hooks:set_hook(mn_destroy_agent, destroy_agent, ?MODULE, destroy, [], 100),
	cpx_hooks:set_hook(mn_auth_agent, auth_agent, ?MODULE, auth, [], 100),

	%% Endpoints
	cpx_hooks:set_hook(mn_set_endpoint, set_endpoint, ?MODULE, set_endpoint, [], 100),
	cpx_hooks:set_hook(mn_drop_endpoint, drop_endpoint, ?MODULE, drop_endpoint, [], 100),

	%% Extended Prop
	cpx_hooks:set_hook(mn_get_extended_prop, get_extended_prop, ?MODULE, get_extended_prop, [], 100),
	cpx_hooks:set_hook(mn_set_extended_prop, set_extended_prop, ?MODULE, set_extended_prop, [], 100),
	cpx_hooks:set_hook(mn_drop_extended_prop, drop_extended_prop, ?MODULE, drop_extended_prop, [], 100),

	%% Profiles
	cpx_hooks:set_hook(mn_get_profiles, get_profiles, ?MODULE, get_profiles, [], 100),
	cpx_hooks:set_hook(mn_get_profile, get_profile, ?MODULE, get_profile, [], 100),
	cpx_hooks:set_hook(mn_new_profile, new_profile, ?MODULE, new_profile, [], 100),
	cpx_hooks:set_hook(mn_set_profile, set_profile, ?MODULE, set_profile, [], 100),
	cpx_hooks:set_hook(mn_destroy_profile, destroy_profile, ?MODULE, destroy_profile, [], 100),

	build_tables().

%% @doc Add `#release_opt{} Rec' to the database.
-spec(new_release/1 :: (Rec :: #release_opt{}) -> {'ok', any()} | {'aborted', any()}).
new_release(Rec) when is_record(Rec, release_opt) ->
	F = fun() ->
		mnesia:write(Rec)
	end,
	do_transaction(F).

%% @doc Remove the release option `string() Label' from the database.
-spec(destroy_release/1 :: (Label :: string()) -> {'atomic', 'ok'}).
destroy_release(Label) when is_list(Label) ->
	destroy_release(label, Label).

%% @doc Remove the release option with the key (id, label) of value from the
%% database.
-spec(destroy_release/2 :: (Key :: 'id' | 'label', Value :: pos_integer() | string()) -> {'ok', any()} | {'error', any()}).
destroy_release(id, Id) ->
	F = fun() ->
		mnesia:delete({release_opt, Id})
	end,
	do_transaction(F);
destroy_release(label, Label) ->
	F = fun() ->
		QH = qlc:q([X || X <- mnesia:table(release_opt), X#release_opt.label =:= Label]),
		case qlc:e(QH) of
			[] ->
				ok;
			[#release_opt{id = Id}] ->
				mnesia:delete({release_opt, Id});
			_Else ->
				erlang:throw(ambiguous_label)
		end
	end,
	do_transaction(F).

%% @doc Update the release option `string() Label' to `#release_opt{} Rec'.
-spec(update_release/2 :: (Label :: string(), Rec :: #release_opt{}) -> {'ok', any()} | {'error', any()}).
update_release(Label, Rec) when is_list(Label), is_record(Rec, release_opt) ->
	F = fun() ->
		mnesia:delete({release_opt, Label}),
		mnesia:write(Rec)
	end,
	do_transaction(F).

%% @doc Get all `#release_opt'.
-spec(get_releases/0 :: () -> {ok, [#release_opt{}]}).
get_releases() ->
	F = fun() ->
		Select = qlc:q([X || X <- mnesia:table(release_opt)]),
		qlc:e(Select)
	end,
	{atomic, Opts} = mnesia:transaction(F),
	{ok, lists:sort(Opts)}.

%% @doc Create a new agent profile.
-spec(new_profile/1 :: (Rec :: #agent_profile{}) -> {'error', any()} | {'ok', any()}).
new_profile(#agent_profile{id = undefined} = Rec) ->
	new_profile(give_profile_id(Rec));
new_profile(#agent_profile{name = "Default"}) ->
	?ERROR("Default cannot be added as a new profile", []),
	{error, not_allowed};
new_profile(Rec) ->
	F = fun() ->
		case qlc:e(qlc:q([Out || #agent_profile{name = N} = Out <- mnesia:table(agent_profile), N =:= Rec#agent_profile.name])) of
			[] ->
				mnesia:write(Rec);
			_ ->
				erlang:error(duplicate_name, Rec)
		end
	end,
	do_transaction(F).

%% @doc Create a new agent profile `string() Name' with `[atom()] Skills'.
-spec(new_profile/2 :: (Name :: string(), Skills :: [atom()]) -> {'atomic', 'ok'}).
new_profile(Name, Skills) ->
	Rec = #agent_profile{name = Name, skills = Skills},
	new_profile(Rec).

-spec(set_profile/3 :: (Oldname :: string(), Name :: string(), Skills :: [atom()]) -> {'atomic', 'ok'}).
set_profile(Oldname, Name, Skills) ->
	{ok, _Old} = agent_auth:get_profile(Oldname),
	New = #agent_profile{
		name = Name,
		skills = Skills
	},
	set_profile(Oldname, New).

%% @doc Update the profile `string() Oldname' to the given rec.
-spec(set_profile/2 :: (Oldname :: string(), Rec :: #agent_profile{}) -> {'ok', any()} | {error, any()}).
set_profile(Old, #agent_profile{id = undefined} = Rec) ->
	{ok, Oldprof} = get_profile(Old),
	set_profile(Old, Rec#agent_profile{id = Oldprof#agent_profile.id});
set_profile(Oldname, #agent_profile{name = Oldname} = Rec) ->
	F = fun() ->
		mnesia:write(Rec)
	end,
	mnesia:transaction(F);
set_profile("Default", _Rec) ->
	?ERROR("Cannot change the name of the default profile", []),
	error;
set_profile(Oldname, #agent_profile{name = Newname} = Rec) ->
	F = fun() ->
		case qlc:e(qlc:q([Found || #agent_profile{name = Nom} = Found <- mnesia:table(agent_profile), Nom =:= Newname])) of
			[] ->
				mnesia:delete({agent_profile, Oldname}),
				mnesia:write(Rec),
				qlc:e(qlc:q([mnesia:write(Arec#agent_auth{profile = Newname}) || Arec <- mnesia:table(agent_auth), Arec#agent_auth.profile =:= Oldname])),
				ok;
			_ ->
				erlang:error(duplicate_name, Rec)
		end
	end,
	do_transaction(F).

%% @doc generate an id for the profile rec and return the 'fixed' rec.
give_profile_id(Rec) ->
	F = fun() ->
		qlc:e(qlc:q([Id || #agent_profile{id = Id} <- mnesia:table(agent_profile)]))
	end,
	{atomic, Ids} = mnesia:transaction(F),
	Fold = fun(Elem, Acc) ->
		Newacc = try list_to_integer(Elem) of
			E when Acc < E->
				E;
			_ ->
				Acc
		catch
			error:badarg ->
				Acc
		end,
		Newacc
	end,
	Id = integer_to_list(lists:foldl(Fold, 0, Ids) + 1),
	Rec#agent_profile{id = Id}.


%% @doc Remove the profile `string() Name'.  Returns `error' if you try to remove the profile `"Default"'.
-spec(destroy_profile/1 :: (Name :: string()) -> {'atomic', 'ok'} | {error, any()}).
destroy_profile("Default") ->
	error;
destroy_profile(Name) ->
	F = fun() ->
		mnesia:delete({agent_profile, Name}),
		{ok, Agents} = get_agents(Name),
		Update = fun(Arec) ->
			Newagent = Arec#agent_auth{profile = "Default"},
			destroy(Arec#agent_auth.login),
			mnesia:write(Newagent)
		end,
		lists:map(Update, Agents),
		ok
	end,
	do_transaction(F).

%% @doc Gets the proflie `string() Name'
-spec(get_profile/1 :: (Name :: string() | {id, string()} | {name, string()}) -> {ok, #agent_profile{}} | 'undefined').
get_profile(Profile) ->
	try integration:get_profile(Profile) of
		none ->
			?DEBUG("integration has no such profile ~p", [Profile]),
			destroy_profile(Profile),
			undefined;
		{ok, Name, Id, Order, Options, Skills} ->
			?DEBUG("integration found profile ~p", [Profile]),

			Rec = #agent_profile{
				name = Name,
				id = Id,
				order = Order,
				options = Options,
				skills = Skills,
				timestamp = util:now()
			},

			F = fun() -> mnesia:write(Rec) end,
			{atomic, ok} = mnesia:transaction(F),

			local_get_profile(Profile);
		{error, nointegration} ->
			?DEBUG("No integration, falling back for ~p", [Profile]),
			local_get_profile(Profile)
	catch
		throw:{badreturn, Err} ->
			?WARNING("Integration failed with message:  ~p", [Err]),
			local_get_profile(Profile)
	end.


-spec(local_get_profile/1 :: (Name :: string() | {id, string()} | {name, string()}) -> #agent_profile{} | 'undefined').
local_get_profile(Name) when is_list(Name) ->
	local_get_profile({name, Name});
local_get_profile({id, Id}) ->
	F = fun() ->
		QH = qlc:q([ X || X <- mnesia:table(agent_profile),
			X#agent_profile.id =:= Id]),
		qlc:e(QH)
	end,
	case mnesia:transaction(F) of
		{atomic, []} ->
			undefined;
		{atomic, [Profile]} ->
			{ok, Profile}
	end;
local_get_profile({name, Name}) ->
	F = fun() ->
		mnesia:read({agent_profile, Name})
	end,
	case mnesia:transaction(F) of
		{atomic, []} ->
			undefined;
		{atomic, [Profile]} ->
			{ok, Profile}
	end.

%% @doc Return all profiles as `[{string() Name, [atom] Skills}]'.
-spec(get_profiles/0 :: () -> {ok, [#agent_profile{}]}).
get_profiles() ->
	F = fun() ->
		QH = qlc:q([ X || X <- mnesia:table(agent_profile)]),
		qlc:e(QH)
	end,
	{atomic, Profiles} = mnesia:transaction(F),
	{ok, sort_profiles(Profiles)}.


%% @doc Sets the agent `string() Oldlogin' with new data in `proplist Props';
%% does not change data that is not in the proplist.  The proplist's
%% `endpoints' field can also contain a partial list, preserving existing
%% settings.
-spec(set_agent/2 :: (Id :: string(), Props :: [{atom(), any()}]) -> {'ok', any()} | {'error', any()}).
set_agent(Id, Props) ->
	F = fun() ->
		QH = qlc:q([X || X <- mnesia:table(agent_auth), X#agent_auth.id =:= Id]),
		[Agent] = qlc:e(QH),
		Newrec = build_agent_record(Props, Agent),
		case qlc:e(qlc:q([Dup || #agent_auth{login = Login, id = Gotid} = Dup <- mnesia:table(agent_auth), Login =:= Newrec#agent_auth.login, Id =/= Gotid])) of
			[] ->
				destroy(Id),
				mnesia:write(Newrec#agent_auth{timestamp = util:now()}),
				ok;
			_ ->
				erlang:error(duplicate_login, Newrec)
		end
	end,
	do_transaction(F).

%% @doc Gets `#agent_auth{}' associated with `string() Login'.
-spec(get_agent/1 :: (Login :: string()) -> {ok, #agent_auth{}} | none).
get_agent(Login) ->
	get_agent(login, Login).

%% @doc Get an agent who's `Key' is `Value'.
-spec(get_agent/2 :: (Key :: 'id' | 'login', Value :: string()) -> {ok, #agent_auth{}} | none).
get_agent(login, Value) ->
	F = fun() ->
		QH = qlc:q([X || X <- mnesia:table(agent_auth), X#agent_auth.login =:= Value]),
		qlc:e(QH)
	end,
	case mnesia:transaction(F) of
		{atomic, [Agent]} -> {ok, Agent};
		_ -> none
	end;
get_agent(id, Value) ->
	F = fun() ->
		QH = qlc:q([X || X <- mnesia:table(agent_auth), X#agent_auth.id =:= Value]),
		qlc:e(QH)
	end,
	case mnesia:transaction(F) of
		{atomic, [Agent]} -> {ok, Agent};
		_ -> none
	end.

%% @doc Gets All the agents.
-spec(get_agents/0 :: () -> {ok, [#agent_auth{}]}).
get_agents() ->
	F = fun() ->
		QH = qlc:q([X || X <- mnesia:table(agent_auth)]),
		qlc:e(QH)
	end,
	{atomic, Agents} = mnesia:transaction(F),
	Sort = fun(#agent_auth{profile = P1}, #agent_auth{profile = P2}) ->
		P1 < P2
	end,
	{ok, lists:sort(Sort, Agents)}.

%% @doc Gets all the agents associated with `string() Profile'.
-spec(get_agents/1 :: (Profile :: string()) -> {ok, [#agent_auth{}]}).
get_agents(Profile) ->
	F = fun() ->
		QH = qlc:q([X || X <- mnesia:table(agent_auth), X#agent_auth.profile =:= Profile]),
		qlc:e(QH)
	end,
	{atomic, Agents} = mnesia:transaction(F),
	Sort = fun(#agent_auth{login = L1}, #agent_auth{login = L2}) ->
		 L1 < L2
	end,
	{ok, lists:sort(Sort, Agents)}.

-spec(set_endpoint/3 :: (Key :: {'login' | 'id', string()}, Endpoint :: atom(), Data :: any()) -> {ok, any()} | {error, any()}).
set_endpoint({Type, Aval}, Endpoint, Data) ->
	case get_agent(Type, Aval) of
		{ok, Rec} ->
			Midends = proplists:delete(Endpoint, Rec#agent_auth.endpoints),
			Newends = [{Endpoint, Data} | Midends],
			F = fun() ->
				mnesia:write(Rec#agent_auth{endpoints = Newends})
			end,
			do_transaction(F);
		_ ->
			{error, noagent}
	end.

-spec(drop_endpoint/2 :: (Key :: {'login' | 'id', string()}, Endpoint :: atom()) -> {'atomic', 'ok'}).
drop_endpoint({Type, Aval}, Endpoint) ->
	case get_agent(Type, Aval) of
		{ok, #agent_auth{endpoints = OldEnds} = Rec} ->
			case proplists:delete(Endpoint, Rec#agent_auth.endpoints) of
				OldEnds ->
					{atomic, ok};
				Newends ->
					F = fun() ->
						mnesia:write(Rec#agent_auth{endpoints = Newends})
					end,
					do_transaction(F)
			end
	end.

-spec(set_extended_prop/3 :: (Key :: {'login' | 'id', string()}, Prop :: atom(), Val :: any()) -> {'ok', any()} | {'error', any()}).
set_extended_prop({Type, Aval}, Prop, Val) ->
	case get_agent(Type, Aval) of
		{ok, Rec} ->
			Midprops = proplists:delete(Prop, Rec#agent_auth.extended_props),
			Newprops = [{Prop, Val} | Midprops],
			F = fun() ->
				mnesia:write(Rec#agent_auth{extended_props = Newprops})
			end,
			do_transaction(F);
		_ ->
			{error, noagent}
	end.

-spec(drop_extended_prop/2 :: (Key :: {'login' | 'id', string()}, Prop :: atom()) ->  {'ok', any()} | {'error', any()}).
drop_extended_prop({Type, Aval}, Prop) ->
	case get_agent(Type, Aval) of
		{ok, Rec} ->
			Newprops = proplists:delete(Prop, Rec#agent_auth.extended_props),
			F = fun() ->
				mnesia:write(Rec#agent_auth{extended_props = Newprops})
			end,
			do_transaction(F);
		_ ->
			{error, noagent}
	end.

%% @doc Get an extened property either from the database or a record
%% directly.
-spec(get_extended_prop/2 :: (Key :: {'login' | 'id', string()}, Prop :: atom()) -> {'ok', any()} | {'error', 'noagent'} | 'undefined').
get_extended_prop({Type, Aval}, Prop) ->
	case get_agent(Type, Aval) of
		{ok, Rec} ->
			get_extended_prop(Rec, Prop);
		_ ->
			{error, noagent}
	end;
get_extended_prop(#agent_auth{extended_props = Props}, Prop) ->
	case proplists:get_value(Prop, Props) of
		undefined -> undefined;
		Else -> {ok, Else}
	end.

%% @doc Utility function to handle merging data after a net split.  Takes the
%% given nodes, selects all records with a timestamp greater than the given
%% time, merges them, and passes the resulting list back to Pid.  Best if used
%% inside a spawn.
-spec(merge/3 :: (Nodes :: [atom()], Time :: pos_integer(), Replyto :: pid()) -> 'ok' | {'error', any()}).
merge(Nodes, Time, Replyto) ->
	Auths = merge_results(query_nodes(Nodes, Time, query_agent_auth)),
	Profs = merge_results(query_nodes(Nodes, Time, query_profiles)),
	Rels = merge_results(query_nodes(Nodes, Time, query_release)),
%	Auths = merge_agent_auth(Nodes, Time),
%	Profs = merge_profiles(Nodes, Time),
%	Rels = merge_release(Nodes, Time),
	Recs = lists:append([Auths, Profs, Rels]),
	Replyto ! {merge_complete, agent_auth, Recs},
	ok.

-spec(query_agent_auth/1 :: (Time :: pos_integer()) -> {'atomic', [#agent_auth{}]}).
query_agent_auth(Time) ->
	F = fun() ->
		QH = qlc:q([Auth || Auth <- mnesia:table(agent_auth), Auth#agent_auth.timestamp >= Time]),
		qlc:e(QH)
	end,
	mnesia:transaction(F).

-spec(query_profiles/1 :: (Time :: pos_integer()) -> {'atomic', [#agent_profile{}]}).
query_profiles(Time) ->
	F = fun() ->
		QH = qlc:q([Prof || Prof <- mnesia:table(agent_profile), Prof#agent_profile.timestamp >= Time]),
		qlc:e(QH)
	end,
	mnesia:transaction(F).

-spec(query_release/1 :: (Time :: pos_integer()) -> {'atomic', [#release_opt{}]}).
query_release(Time) ->
	F = fun() ->
		QH = qlc:q([Rel || Rel <- mnesia:table(release_opt), Rel#release_opt.timestamp >= Time]),
		qlc:e(QH)
	end,
	mnesia:transaction(F).

%merge_agent_auth(Nodes, Time) ->
%	?DEBUG("Staring merge.  Nodes:  ~p.  Time:  ~B", [Nodes, Time]),
%	F = fun() ->
%		QH = qlc:q([Auth || Auth <- mnesia:table(agent_auth), Auth#agent_auth.timestamp >= Time]),
%		qlc:e(QH)
%	end,
%	merge_results(query_nodes(Nodes, F)).

merge_results(Res) ->
	?DEBUG("Merging:  ~p", [Res]),
	merge_results_loop([], Res).

merge_results_loop(Return, []) ->
	?DEBUG("Merge complete:  ~p", [Return]),
	Return;
merge_results_loop(Return, [{atomic, List} | Tail]) ->
	Newreturn = diff_recs(Return, List),
	merge_results_loop(Newreturn, Tail).

%merge_profiles(Nodes, Time) ->
%	F = fun() ->
%		QH = qlc:q([Prof || Prof <- mnesia:table(agent_profile), Prof#agent_profile.timestamp >= Time]),
%		qlc:e(QH)
%	end,
%	merge_results(query_nodes(Nodes, F)).
%
%merge_release(Nodes, Time) ->
%	F = fun() ->
%		QH = qlc:q([Rel || Rel <- mnesia:table(release_opt), Rel#release_opt.timestamp >= Time]),
%		qlc:e(QH)
%	end,
%	merge_results(query_nodes(Nodes, F)).

query_nodes(Nodes, Time, Func) ->
	query_nodes(Nodes, Time, Func, []).

query_nodes([], _, _, Acc) ->
	?DEBUG("Full acc:  ~p", [Acc]),
	Acc;
query_nodes([Node | Tail], Time, Func, Acc) ->
	Newacc = case rpc:call(Node, agent_auth, Func, [Time]) of
		{atomic, Rows} = Rez ->
			?DEBUG("Node ~w got rows ~p", [Node, Rows]),
			[Rez | Acc];
		Else ->
			?WARNING("unable to get rows during merge for node ~w due to ~p", [Node, Else]),
			Acc
	end,
	query_nodes(Tail, Time, Func, Newacc).



%query_nodes(Nodes, Fun) ->
%	query_nodes(Nodes, Fun, []).
%
%query_nodes([], _Fun, Acc) ->
%	?DEBUG("Full acc:  ~p", [Acc]),
%	Acc;
%query_nodes([Node | Tail], Fun, Acc) ->
%	Newacc = case rpc:call(Node, mnesia, transaction, [Fun]) of
%		{atomic, Rows} = Rez ->
%			?DEBUG("Node ~w Got the following rows:  ~p", [Node, Rows]),
%			[Rez | Acc];
%		_Else ->
%			?WARNING("Unable to get rows during merge for node ~w", [Node]),
%			Acc
%	end,
%	query_nodes(Tail, Fun, Newacc).

%% @doc Take the plaintext username and password and attempt to
%% authenticate the agent.
-type(profile_name() :: string()).
-spec(auth/2 :: (Username :: string(), Password :: string()) -> {ok, 'deny'} | {ok, {'allow', string(), skill_list(), security_level(), profile_name()}} | pass).
auth(Username, Password) ->
	Extended = case get_agent(Username) of
		{ok, Rec} ->
			Rec#agent_auth.extended_props;
		_Else ->
			[]
	end,
	try integration:agent_auth(Username, Password, Extended) of
		deny ->
			?INFO("integration denial for ~p", [Username]),
			%destroy(Username),
			{ok, deny};
		destroy ->
			destroy(Username),
			pass;
		{ok, Id, Profile, Security, Newextended} ->
			?INFO("integration allow for ~p", [Username]),
			cache(Id, Username, Password, Profile, Security, Newextended),
			local_auth(Username, Password);
		{error, nointegration} ->
			?INFO("No integration, local authing ~p", [Username]),
			local_auth(Username, Password)
	catch
		throw:{badreturn, Err} ->
			?WARNING("Integration gave a bad return of ~p", [Err]),
			local_auth(Username, Password)
	end.

%% @doc Starts mnesia and creates the tables.  If the tables already exist,
%% returns `ok'.  Otherwise, a default username of `"agent"' is stored
%% with password `"Password123"' and skill `[english]'.
-spec(build_tables/0 :: () -> 'ok').
build_tables() ->
	?DEBUG("building tables...", []),
%	Nodes = lists:append([[node()], nodes()]),
	A = util:build_table(agent_auth, [
				{attributes, record_info(fields, agent_auth)},
				{disc_copies, [node()]}
			]),
	case A of
		{atomic, ok} ->
			write_default_agents();
		_Else when A =:= copied; A =:= exists ->
			ok;
		_Else ->
			A
	end,
	B = util:build_table(release_opt, [
		{attributes, record_info(fields, release_opt)},
		{disc_copies, [node()]}
	]),
	case B of
		{atomic, ok} ->
			ok;
		_Else2 when B =:= copied; B =:= exists ->
			ok;
		_Else2 ->
			B
	end,
	C = util:build_table(agent_profile, [
		{attributes, record_info(fields, agent_profile)},
		{disc_copies, [node()]}
	]),
	case C of
		{atomic, ok} ->
			write_default_profile();
		_Else3 when C =:= copied; C =:= exists ->
			ok;
		_Else3 ->
			C
	end.

%%--------------------------------------------------------------------
%%% Internal functions
%%--------------------------------------------------------------------

%% @doc Caches the passed `Username', `Password', `Skills', and `Security'
%% type.  to the mnesia database.  `Username' is the plaintext name and
%% used as the key.  `Password' is assumed to be plaintext; will be
%% erlang:md5'ed.  `Security' is either `agent', `supervisor', or `admin'.
%% @deprecated Use {@link cache/2} instead.
-type(profile() :: string()).
-type(profile_data() :: {profile(), skill_list()} | profile() | skill_list()).
-spec(cache/6 ::	(Id :: string(), Username :: string(), Password :: string(), Profile :: profile_data(), Security :: 'agent' | 'supervisor' | 'admin', Extended :: [{atom(), any()}]) ->
						{'atomic', 'ok'} | {'aborted', any()}).
cache(Id, Username, Password, {Profile, Skills}, Security, Extended) ->
	cache(Id, [
		{id, Id},
		{login, Username},
		{password, Password},
		{profile, Profile},
		{skills, Skills},
		{securitylevel, Security},
		{extended_props, Extended}
	]);
cache(Id, Username, Password, [Isskill | _Tail] = Skills, Security, Extended) when is_atom(Isskill); is_tuple(Isskill) ->
	case get_agent(id, Id) of
		{ok, Agent} ->
			cache(Id, Username, Password, {Agent#agent_auth.profile, Skills}, Security, Extended);
		none ->
			cache(Id, Username, Password, {"Default", Skills}, Security, Extended)
	end;
cache(Id, Username, Password, Profile, Security, Extended) ->
	cache(Id, Username, Password, {Profile, []}, Security, Extended).

cache(Id, Props) ->
	F = fun() ->
		QH = qlc:q([A || A <- mnesia:table(agent_auth), A#agent_auth.id =:= Id]),
		Writerec = case qlc:e(QH) of
			[] ->
				Midrec = build_agent_record(Props, #agent_auth{}),
				Midrec#agent_auth{id = Id, integrated = util:now()};
			[Baserec] ->
				Midrec = build_agent_record(Props, Baserec),
				Midrec#agent_auth{id = Id, integrated = util:now()}
		end,
		mnesia:write(Writerec)
	end,
	Out = mnesia:transaction(F),
	?DEBUG("Cache username result:  ~p", [Out]),
	Out.

%% @doc adds a user to the local cache bypassing the integrated at check.
%% Note that unlike {@link cache/4} this expects the password in plain
%% text!
%% @deprecated Please use {@link add_agent/1} instead.
-spec(add_agent/5 ::
	(Username :: string(), Password :: string(), Skills :: [atom()], Security :: 'admin' | 'agent' | 'supervisor', Profile :: string()) ->
		{'atomic', 'ok'}).
add_agent(Username, Password, Skills, Security, Profile) ->
	Rec = #agent_auth{
		login = Username,
		password = util:bin_to_hexstr(erlang:md5(Password)),
		skills = Skills,
		securitylevel = Security,
		profile = Profile},
	add_agent(Rec).

%% @doc adds a user to the local cache bypassing the integrated at check.
%% Note that unlike {@link cache/4} this expects the password in plain
%% text!
%% @deprecated Please use {@link add_agent/1} instead.
-spec(add_agent/7 ::
	(Username :: string(), Firstname :: string(), Lastname :: string(), Password :: string(), Skills :: [atom()], Security :: 'admin' | 'agent' | 'supervisor', Profile :: string()) ->
		{'atomic', 'ok'}).
add_agent(Username, Firstname, Lastname, Password, Skills, Security, Profile) ->
	Rec = #agent_auth{
		login = Username,
		password = util:bin_to_hexstr(erlang:md5(Password)),
		skills = Skills,
		securitylevel = Security,
		profile = Profile,
		firstname = Firstname,
		lastname = Lastname},
	add_agent(Rec).

%% @doc adds a user to the local cache.  Accepts either `#agent_auth{}' or
%% a proplist as the initial argument.  If an agent with the given login
%% already exists, this throws an error.  An id is created for ye.  The
%% password should not be encoded.
-spec(add_agent/1 :: (Proplist :: [{atom(), any()}, ...] | #agent_auth{}) -> {'atomic', 'ok'}).
add_agent(Proplist) when is_list(Proplist) ->
	Rec = build_agent_record(Proplist, #agent_auth{}),
	add_agent(Rec);
add_agent(Rec) when is_record(Rec, agent_auth) ->
	Id = make_id(),
	F = fun() ->
		QH = qlc:q([Rec || #agent_auth{login = Nom} <- mnesia:table(agent_auth), Nom =:= Rec#agent_auth.login]),
		case qlc:e(QH) of
			[] ->
				mnesia:write(Rec#agent_auth{id = Id});
			_ ->
				erlang:error(duplicate_login, Rec)
		end
	end,
	mnesia:transaction(F).

make_id() ->
	Ref = erlang:ref_to_list(make_ref()),
	RemovedRef = string:sub_string(Ref, 6),
	FixedRef = string:strip(RemovedRef, right, $>),
	F = fun(Elem, Acc) ->
		case Elem of
			$. ->
				Acc;
			Else ->
				[Else | Acc]
		end
	end,
	lists:reverse(lists:foldl(F, [], FixedRef)).

-spec(destroy/1 :: (Username :: string()) -> {'ok', any()} | {'error', any()}).
destroy(Username) ->
	destroy(login, Username).

%% @doc Destory either by id or login.
-spec(destroy/2 :: (Key :: 'id' | 'login', Value :: string()) -> {'ok', any()} | {'error', any()}).
destroy(id, Value) ->
	F = fun() ->
		mnesia:delete({agent_auth, Value})
	end,
	case mnesia:transaction(F) of
		{atomic, ok} -> {ok, ok};
		Err -> Err
	end;
destroy(login, Value) ->
	F = fun() ->
		QH = qlc:q([X || X <- mnesia:table(agent_auth), X#agent_auth.login =:= Value]),
		[#agent_auth{id = Id}] = qlc:e(QH),
		mnesia:delete({agent_auth, Id})
	end,
	case mnesia:transaction(F) of
		{atomic, ok} -> {ok, ok};
		Err -> Err
	end.

%% @private
% Checks the `Username' and prehashed `Password' using the given `Salt' for the cached password.
% internally called by the auth callback; there should be no need to call this directly (aside from tests).
-spec(local_auth/2 :: (Username :: string(), Password :: string()) -> {'ok', {'allow', string(), skill_list(), security_level(), profile_name()}} | {'ok', 'deny'} | pass).
local_auth(Username, BasePassword) ->
	Password = util:bin_to_hexstr(erlang:md5(BasePassword)),
	F = fun() ->
		QH = qlc:q([X || X <- mnesia:table(agent_auth), X#agent_auth.login =:= Username]),
		qlc:e(QH)
	end,
	case mnesia:transaction(F) of
		{atomic, [Agent]} when is_record(Agent, agent_auth) ->
			case Agent#agent_auth.password of
				Password ->
					?DEBUG("Auth is coolbeans for ~p", [Username]),
					Skills = lists:umerge(lists:sort(Agent#agent_auth.skills), lists:sort(['_agent', '_node'])),
					{ok, {allow, Agent#agent_auth.id, Skills, Agent#agent_auth.securitylevel, Agent#agent_auth.profile}};
				_ ->
					{ok, deny}
			end;
		Else ->
			?DEBUG("Passing off auth due to ~p", [Else]),
			pass
	end.

%% @doc Sorts the profiles based on sort order, then alphabetical.
-spec(sort_profiles/1 :: (List :: [#agent_profile{}]) -> [#agent_profile{}]).
sort_profiles(List) ->
	lists:sort(fun comp_profiles/2, List).

comp_profiles(#agent_profile{name = Aname, order = S}, #agent_profile{name = Bname, order = S}) ->
	Aname =< Bname;
comp_profiles(#agent_profile{order = Asort}, #agent_profile{order = Bsort}) ->
	Asort =< Bsort.

%% @doc Builds up an `#agent_auth{}' from the given `proplist() Proplist'.
%% Merges endpoints and extended props so old ones are not smashed.
-spec(build_agent_record/2 :: (Proplist :: [{atom(), any()}], Rec :: #agent_auth{}) -> #agent_auth{}).
build_agent_record([], Rec) ->
	Rec;
build_agent_record([{id, Id} | Tail], Rec) ->
	build_agent_record(Tail, Rec#agent_auth{id = Id}); %% Should id be overwritten?
build_agent_record([{login, Login} | Tail], Rec) ->
	build_agent_record(Tail, Rec#agent_auth{login = Login});
build_agent_record([{password, Password} | Tail], Rec) ->
	build_agent_record(Tail, Rec#agent_auth{password = encode_password(Password)});
build_agent_record([{skills, Skills} | Tail], Rec) when is_list(Skills) ->
	build_agent_record(Tail, Rec#agent_auth{skills = Skills});
build_agent_record([{securitylevel, Sec} | Tail], Rec) ->
	build_agent_record(Tail, Rec#agent_auth{securitylevel = Sec});
build_agent_record([{profile, Profile} | Tail], Rec) ->
	build_agent_record(Tail, Rec#agent_auth{profile = Profile});
build_agent_record([{firstname, Name} | Tail], Rec) ->
	build_agent_record(Tail, Rec#agent_auth{firstname = Name});
build_agent_record([{lastname, Name} | Tail], Rec) ->
	build_agent_record(Tail, Rec#agent_auth{lastname = Name});
build_agent_record([{endpoints, Ends} | Tail], Rec) when is_list(Ends) ->
	case Rec#agent_auth.endpoints of
		undefined ->
			build_agent_record(Tail, Rec#agent_auth{endpoints = Ends});
		OldEnds ->
			NewEnds = proplist_overwrite(Ends, OldEnds),
			build_agent_record(Tail, Rec#agent_auth{endpoints = NewEnds})
	end;
build_agent_record([{extended_props, Props} | Tail], Rec) ->
	OldProps = Rec#agent_auth.extended_props,
	NewProps = proplist_overwrite(Props, OldProps),
	build_agent_record(Tail, Rec#agent_auth{extended_props = NewProps}).

proplist_overwrite([], Acc) ->
	Acc;
proplist_overwrite([{Key, Value} | Tail], Acc) ->
	MidAcc = proplists:delete(Key, Acc),
	NewAcc = [{Key, Value} | MidAcc],
	proplist_overwrite(Tail, NewAcc);
proplist_overwrite([Atom | Tail], Acc) when is_atom(Atom) ->
	NewAcc = case proplists:get_value(Atom, Acc) of
		undefined ->
			[Atom | Acc];
		Atom ->
			Acc;
		_Else ->
			MidAcc = proplists:delete(Atom, Acc),
			[Atom | MidAcc]
	end,
	proplist_overwrite(Tail, NewAcc).

diff_recs(Left, Right) ->
	Sort = fun(A, B) when is_record(A, agent_auth) ->
			A#agent_auth.id < B#agent_auth.id;
		(A, B) when is_record(A, release_opt) ->
			A#release_opt.label < B#release_opt.label;
		(A, B) when is_record(A, agent_profile) ->
			A#agent_profile.name < B#agent_profile.name
	end,
	Sleft = lists:sort(Sort, Left),
	Sright = lists:sort(Sort, Right),
	diff_recs_loop(Sleft, Sright, []).

diff_recs_loop([], [], Acc) ->
	lists:reverse(Acc);
diff_recs_loop([_H | _T] = Left, [], Acc) ->
	lists:append(lists:reverse(Acc), Left);
diff_recs_loop([], [_H | _T] = Right, Acc) ->
	lists:append(lists:reverse(Acc), Right);
diff_recs_loop([Lhead | LTail] = Left, [Rhead | Rtail] = Right, Acc) ->
	case nom_equal(Lhead, Rhead) of
		true ->
			case timestamp_comp(Lhead, Rhead) of
				false ->
					diff_recs_loop(LTail, Rtail, [Lhead | Acc]);
				true ->
					diff_recs_loop(LTail, Rtail, [Rhead | Acc])
			end;
		false ->
			case nom_comp(Lhead, Rhead) of
				true ->
					diff_recs_loop(LTail, Right, [Lhead | Acc]);
				false ->
					diff_recs_loop(Left, Rtail, [Rhead | Acc])
			end
	end.

nom_equal(A, B) when is_record(A, agent_auth) ->
	A#agent_auth.id =:= B#agent_auth.id;
nom_equal(A, B) when is_record(A, release_opt) ->
	B#release_opt.label =:= A#release_opt.label;
nom_equal(A, B) when is_record(A, agent_profile) ->
	A#agent_profile.name =:= B#agent_profile.name.

nom_comp(A, B) when is_record(A, agent_auth) ->
	A#agent_auth.id < B#agent_auth.id;
nom_comp(A, B) when is_record(A, release_opt) ->
	A#release_opt.label < B#release_opt.label;
nom_comp(A, B) when is_record(A, agent_profile) ->
	A#agent_profile.name < B#agent_profile.name.

timestamp_comp(A, B) when is_record(A, agent_auth) ->
	A#agent_auth.timestamp < B#agent_auth.timestamp;
timestamp_comp(A, B) when is_record(B, release_opt) ->
	A#release_opt.timestamp < B#release_opt.timestamp;
timestamp_comp(A, B) when is_record(A, agent_profile) ->
	A#agent_profile.timestamp < B#agent_profile.timestamp.

encode_password(Password) ->
	util:bin_to_hexstr(erlang:md5(Password)).

do_transaction(F) ->
	case mnesia:transaction(F) of
		{atomic, V} -> {ok, V};
		{aborted, Err} -> {error, Err}
	end.

write_default_agents() ->
	F = fun() ->
		mnesia:write(#agent_auth{id = "1", login="agent", password=util:bin_to_hexstr(erlang:md5("Password123")), skills=[english], profile="Default"}),
		mnesia:write(#agent_auth{id = "2", login="administrator", password=util:bin_to_hexstr(erlang:md5("Password123")), securitylevel=admin, skills=[english], profile="Default"})
	end,
	case mnesia:transaction(F) of
		{atomic, ok} -> ok;
		Else -> Else
	end.

write_default_profile() ->
	G = fun() ->
		mnesia:write(?DEFAULT_PROFILE)
	end,
	case mnesia:transaction(G) of
		{atomic, ok} ->
			ok;
		Else2 ->
			Else2
	end.

upgrade_v1_table() ->
	NewAttributes = [id, login, password, skills, securitylevel, integrated,
		profile, firstname, lastname, endpoints, extended_props, timestamp],
	% old attributes: [id, login, password, skills, securitylevel,
	%    integrated, profile, firstname, lastname, extended_props, timestamp
	mnesia:transform_table(agent_auth, fun upgrade_transform/1, NewAttributes).

upgrade_transform({agent_auth, Id, Login, Password, Skills, Security,
	Integrated, Profile, First, Last, ExProps, Timestamp}) ->
	{agent_auth, Id, Login, Password, Skills, Security, Integrated, Profile,
		First, Last, [], ExProps, Timestamp}.

-ifdef(TEST).

%%--------------------------------------------------------------------
%%% Test functions
%%--------------------------------------------------------------------

crud_test_() ->
	util:start_testnode(),
	N = util:start_testnode(agent_auth_crud_tests),
	{spawn, N, {setup,
	fun() ->
		mnesia:stop(),
		mnesia:delete_schema([node()]),
		mnesia:create_schema([node()]),
		mnesia:start(),
		build_tables(),
		mnesia:clear_table(agent_auth),
		mnesia:clear_table(agent_profile)
	end,
	fun(_) ->
		mnesia:stop(),
		mnesia:delete_schema([node()])
	end,
	[{"trying to add an agent with a duplicate un",
	fun() ->
		add_agent("dup-login", "pass", [], agent, "Default"),
		Out = add_agent("dup-login", "pass", [], agent, "Default"),
		?assertMatch({aborted, {duplicate_login, _Props}}, Out)
	end},
	{"updating an agent to a duplicate name",
	fun() ->
		add_agent("original", "pass", [], agent, "Default"),
		add_agent("target", "pass", [], agent, "Default"),
		{ok, Old} = get_agent("target"),
		Out = set_agent(Old#agent_auth.id, [{login, "original"}]),
		?assertMatch({error, {duplicate_login, _Props}}, Out)
	end},
	{"no duplicat un error when doing an inline update for agent",
	fun() ->
		add_agent("agent", "pass", [], agent, "Default"),
		{ok, Agent} = get_agent("agent"),
		Out = set_agent(Agent#agent_auth.id, [{password, "newpass"}]),
		?assertEqual({ok, ok}, Out)
	end},
	{"Trying to add a profile with duplicate name fails",
	fun() ->
		new_profile("dup-name", []),
		Out = new_profile("dup-name", []),
		?assertMatch({error, {duplicate_name, _Props}}, Out)
	end},
	{"Trying to update a proflie with duplicate name fails",
	fun() ->
		new_profile("original", []),
		new_profile("target", []),
		Out = set_profile("target", #agent_profile{name = "original"}),
		?assertMatch({error, {duplicate_name, _Props}}, Out)
	end}]}}.

auth_no_integration_test_() ->
	util:start_testnode(),
	N = util:start_testnode(agent_auth_auth_no_integration),
	{spawn, N, {setup,
	fun() ->
		mnesia:stop(),
		mnesia:delete_schema([node()]),
		mnesia:create_schema([node()]),
		mnesia:start(),
		build_tables()
	end,
	fun(_) ->
		mnesia:stop(),
		mnesia:delete_schema([node()])
	end,
	[{"authing the default agent success",
	fun() ->
		?assertMatch({ok, {allow, "1", _Skills, agent, "Default"}}, auth("agent", "Password123"))
	end},
	{"pass off auth for an agent that doesn't exist",
	fun() ->
		?assertEqual(pass, auth("arnie", "goober"))
	end},
	{"deny auth with wrong pass",
	fun() ->
		?assertEqual({ok, deny}, auth("agent", "badpass"))
	end},
	{"extended prop test",
	fun() ->
		?assertEqual(undefined, get_extended_prop({id, "1"}, agent)),
		set_extended_prop({id, "1"}, agent, true),
		?assertEqual({ok, true}, get_extended_prop({id, "1"}, agent)),
		drop_extended_prop({id, "1"}, agent),
		?assertEqual(undefined, get_extended_prop({id, "1"}, agent))
	end}]}}.

auth_integration_test_() ->
	util:start_testnode(),
	N = util:start_testnode(agent_auth_auth_integration_tests),
	{spawn, N, {foreach,
	fun() ->
		mnesia:stop(),
		mnesia:delete_schema([node()]),
		mnesia:create_schema([node()]),
		mnesia:start(),
		build_tables(),
		{ok, Mock} = gen_server_mock:named({local, integration}),
		Mock
	end,
	fun(Mock) ->
		mnesia:stop(),
		mnesia:delete_schema([node()]),
		unregister(integration),
		gen_server_mock:stop(Mock)
	end,
	[fun(Mock) ->
		{"auth an agent that's not cached",
		fun() ->
			gen_server_mock:expect_call(Mock, fun({agent_auth, "testagent", "password", []}, _, State) ->
				{ok, {ok, "testid", "Default", agent, []}, State}
			end),
			?assertMatch({ok, {allow, "testid", _Skills, agent, "Default"}}, auth("testagent", "password")),
			?assertMatch({ok, {allow, "testid", _Skills, agent, "Default"}}, local_auth("testagent", "password"))
		end}
	end,
	fun(Mock) ->
		{"auth an agent overwrites the cache",
		fun() ->
			cache("testid", "testagent", "password", "Default", agent, []),
			?assertMatch({ok, {allow, "testid", _Skills, agent, "Default"}}, local_auth("testagent", "password")),
			gen_server_mock:expect_call(Mock, fun({agent_auth, "testagent", "newpass", []}, _, State) ->
				{ok, {ok, "testid", "Default", agent, []}, State}
			end),
			?assertMatch({ok, {allow, "testid", _Skills, agent, "Default"}}, auth("testagent", "newpass")),
			?assertMatch({ok, {allow, "testid", _Skills, agent, "Default"}}, local_auth("testagent", "newpass")),
			?assertEqual({ok, deny}, local_auth("testagent", "password"))
		end}
	end,
	fun(Mock) ->
		{"integration denies, but doesn't remove from cache",
		fun() ->
			?assertMatch({ok, {allow, "1", _, agent, "Default"}}, local_auth("agent", "Password123")),
			gen_server_mock:expect_call(Mock, fun({agent_auth, "agent", "Password123", []}, _, State) ->
				{ok, deny, State}
			end),
			?assertEqual({ok, deny}, auth("agent", "Password123")),
			?assertMatch({ok, {allow, "1", _, agent, "Default"}}, local_auth("agent", "Password123"))
		end}
	end,
	fun(Mock) ->
		{"integration returns a destory, thus removing from cache",
		fun() ->
			?assertMatch({ok, {allow, "1", _, agent, "Default"}}, local_auth("agent", "Password123")),
			gen_server_mock:expect_call(Mock, fun({agent_auth, "agent", "Password123", []}, _, State) ->
				{ok, destroy, State}
			end),
			?assertEqual(pass, auth("agent", "Password123")),
			?assertEqual(pass, local_auth("agent", "Password123"))
		end}
	end,
	fun(Mock) ->
		{"integration fails",
		fun() ->
			gen_server_mock:expect_call(Mock, fun({agent_auth, "agent", "Password123", []}, _, State) ->
				{ok, gooberpants, State}
			end),
			?assertMatch({ok, {allow, "1", _Skills, agent, "Default"}}, auth("agent", "Password123")),
			?assertMatch({ok, {allow, "1", _Skills, agent, "Default"}}, local_auth("agent", "Password123"))
		end}
	end]}}.

release_opt_test_() ->
	util:start_testnode(),
	N = util:start_testnode(agent_auth_release_opt_tests),
	{spawn, N, {foreach,
	fun() ->
		mnesia:stop(),
		mnesia:delete_schema([node()]),
		mnesia:create_schema([node()]),
		mnesia:start(),
		build_tables()
	end,
	fun(_) ->
		mnesia:stop(),
		mnesia:delete_schema([node()])
	end,
	[{"Add new release option", fun() ->
		Releaseopt = #release_opt{label = "testopt", id = 500, bias = 1},
		new_release(Releaseopt),
		F = fun() ->
			Select = qlc:q([X || X <- mnesia:table(release_opt), X#release_opt.label =:= "testopt"]),
			qlc:e(Select)
		end,
		?assertMatch({atomic, [#release_opt{label ="testopt"}]}, mnesia:transaction(F))
	end },
	{"Destroy a release option", fun() ->
		Releaseopt = #release_opt{label = "testopt", id = 500, bias = 1},
		new_release(Releaseopt),
		destroy_release("testopt"),
		F = fun() ->
			Select = qlc:q([X || X <- mnesia:table(release_opt), X#release_opt.label =:= "testopt"]),
			qlc:e(Select)
		end,
		?assertEqual({atomic, []}, mnesia:transaction(F))
	end},
	{"Update a release option", fun() ->
		Oldopt = #release_opt{label = "oldopt", id = 500, bias = 1},
		Newopt = #release_opt{label = "newopt", id = 500, bias = 1},
		new_release(Oldopt),
		update_release("oldopt", Newopt),
		Getold = fun() ->
			Select = qlc:q([X || X <- mnesia:table(release_opt), X#release_opt.label =:= "oldopt"]),
			qlc:e(Select)
		end,
		Getnew = fun() ->
			Select = qlc:q([X || X <- mnesia:table(release_opt), X#release_opt.label =:= "newopt"]),
			qlc:e(Select)
		end,
		?assertEqual({atomic, []}, mnesia:transaction(Getold)),
		?assertMatch({atomic, [#release_opt{label = "newopt"}]}, mnesia:transaction(Getnew))
	end},
	{"Get all release options", fun() ->
		Aopt = #release_opt{label = "aoption", id = 300, bias = 1},
		Bopt = #release_opt{label = "boption", id = 200, bias = 1},
		Copt = #release_opt{label = "coption", id = 100, bias = -1},
		new_release(Copt),
		new_release(Bopt),
		new_release(Aopt),
		?assertMatch({ok, [#release_opt{label = "coption"}, #release_opt{label = "boption"}, #release_opt{label = "aoption"}]}, get_releases())
	end}]}}.

profile_test_() ->
	util:start_testnode(),
	N = util:start_testnode(agent_auth_profile_test),
	{spawn, N, {foreach,
	fun() ->
		mnesia:stop(),
		mnesia:delete_schema([node()]),
		mnesia:create_schema([node()]),
		mnesia:start(),
		build_tables()
	end,
	fun(_) ->
		mnesia:stop(),
		mnesia:delete_schema([node()])
	end,
	[{"Add a profile", fun() ->
		F = fun() ->
			QH = qlc:q([X || X <- mnesia:table(agent_profile), X#agent_profile.name =:= "test profile"]),
			qlc:e(QH)
		end,
		?assertEqual({atomic, []}, mnesia:transaction(F)),
		?assertEqual({ok, ok}, new_profile("test profile", [testskill])),
		Test = #agent_profile{name = "test profile", skills = [testskill]},
		?assertEqual({atomic, [Test#agent_profile{name = "test profile", id = "1"}]}, mnesia:transaction(F)),
		?assertMatch({ok, #agent_profile{name = "test profile", skills = [testskill]}}, get_profile("test profile"))
	end},
	{"Update a profile", fun() ->
		new_profile(#agent_profile{name = "initial", skills = [english]}),
		?assertNot(undefined == get_profile("initial")),
		?assertEqual({ok, ok}, set_profile("initial", #agent_profile{name = "new", skills = [german]})),
		?assertEqual(undefined, get_profile("initial")),
		?assertEqual({ok, #agent_profile{name = "new", id = "1", skills = [german]}}, get_profile("new"))
	end},
	{"Remove a profile", fun() ->
		F = fun() ->
			QH = qlc:q([X || X <- mnesia:table(agent_profile), X#agent_profile.name =:= "test profile"]),
			qlc:e(QH)
		end,
		new_profile("test profile", [english]),
		?assertEqual({atomic, [#agent_profile{name = "test profile", skills=[english], id = "1", timestamp = util:now()}]}, mnesia:transaction(F)),
		?assertEqual({ok, ok}, destroy_profile("test profile")),
		?assertEqual({atomic, []}, mnesia:transaction(F))
	end },
	{"Get a profile", fun() ->
		?assertEqual(undefined, get_profile("test profile")),
		new_profile("test profile", [testskill]),
		?assertEqual({ok, #agent_profile{name = "test profile", id = "1", skills = [testskill]}}, get_profile("test profile"))
	end},
	{"Get a profile by id", fun() ->
		?assertEqual(undefined, get_profile({id, "1"})),
		new_profile("test profile", [testskill]),
		?assertEqual({ok, #agent_profile{name = "test profile", id = "1", skills = [testskill]}}, get_profile("test profile"))
	end},
	{"Get a profile by name", fun() ->
		?assertEqual(undefined, get_profile({name, "test profile"})),
		new_profile("test profile", [testskill]),
		?assertEqual({ok, #agent_profile{name = "test profile", id = "1", skills = [testskill]}}, get_profile("test profile"))
	end},

	{"Get all profiles", fun() ->
		new_profile("B", [german]),
		new_profile("A", [english]),
		new_profile("C", [testskill]),
		F = fun() ->
			mnesia:delete({agent_profile, "Default"})
		end,
		mnesia:transaction(F),
		?CONSOLE("profs:  ~p", [get_profiles()]),
		?assertMatch({ok, [
			#agent_profile{name = "A", skills = [english]},
			#agent_profile{name = "B", skills = [german]},
			#agent_profile{name = "C", skills = [testskill]}]},
			get_profiles())
	end}]}}.

profile_integration_test_() ->
	util:start_testnode(),
	N = util:start_testnode(agent_auth_profile_test),
	{spawn, N, {foreach,
	fun() ->
		mnesia:stop(),
		mnesia:delete_schema([node()]),
		mnesia:create_schema([node()]),
		mnesia:start(),
		build_tables(),
		{ok, Mock} = gen_server_mock:named({local, integration}),
		Mock
	end,
	fun(Mock) ->
		mnesia:stop(),
		mnesia:delete_schema([node()]),
		unregister(integration),
		gen_server_mock:stop(Mock)
	end,
	[
	fun(Mock) ->
		{"Get a profile in integration",
		fun() ->
			gen_server_mock:expect_call(Mock, fun({get_profile, "test profile"}, _, State) -> {ok, {ok, "test profile", "1", 10, [], [testskill]}, State} end),
			gen_server_mock:expect_call(Mock, fun({get_profile, "test profile"}, _, State) -> {ok, {ok, "test profile", "2", 10, [], [testskill]}, State} end),

			?assertEqual({ok, #agent_profile{name = "test profile", id = "1", order = 10,skills = [testskill], options=[]}}, get_profile("test profile")),
			?assertEqual({ok, #agent_profile{name = "test profile", id = "2", order = 10,skills = [testskill], options=[]}}, get_profile("test profile"))
		end}
	end,
	fun(Mock) ->
		{"Get a non-existing profile in integration",
		fun() ->
			gen_server_mock:expect_call(Mock, fun({get_profile, "test profile"}, _, State) -> {ok, none, State} end),
			?assertEqual(undefined, get_profile("test profile"))
		end}
	end
	]}}.

diff_recs_test_() ->
	[{"agent_auth records",
	fun() ->
		Left = [
			#agent_auth{id = "A", login = "A", timestamp = 1},
			#agent_auth{id = "B", login = "B", timestamp = 3},
			#agent_auth{id = "C", login = "C", timestamp = 5}
		],
		Right = [
			#agent_auth{id = "A", login = "A", timestamp = 5},
			#agent_auth{id = "B", login = "B", timestamp = 3},
			#agent_auth{id = "C", login = "C", timestamp = 1}
		],
		Expected = [
			#agent_auth{id = "A", login = "A", timestamp = 5},
			#agent_auth{id = "B", login = "B", timestamp = 3},
			#agent_auth{id = "C", login = "C", timestamp = 5}
		],
		?assertEqual(Expected, diff_recs(Left, Right))
	end},
	{"release_opts records",
	fun() ->
		Left = [
			#release_opt{label = "A", timestamp = 1},
			#release_opt{label = "B", timestamp = 3},
			#release_opt{label = "C", timestamp = 5}
		],
		Right = [
			#release_opt{label = "A", timestamp = 5},
			#release_opt{label = "B", timestamp = 3},
			#release_opt{label = "C", timestamp = 1}
		],
		Expected = [
			#release_opt{label = "A", timestamp = 5},
			#release_opt{label = "B", timestamp = 3},
			#release_opt{label = "C", timestamp = 5}
		],
		?assertEqual(Expected, diff_recs(Left, Right))
	end},
	{"agent_prof records",
	fun() ->
		Left = [
			#agent_profile{name = "A", timestamp = 1},
			#agent_profile{name = "B", timestamp = 3},
			#agent_profile{name = "C", timestamp = 5}
		],
		Right = [
			#agent_profile{name = "A", timestamp = 5},
			#agent_profile{name = "B", timestamp = 3},
			#agent_profile{name = "C", timestamp = 1}
		],
		Expected = [
			#agent_profile{name = "A", timestamp = 5},
			#agent_profile{name = "B", timestamp = 3},
			#agent_profile{name = "C", timestamp = 5}
		],
		?assertEqual(Expected, diff_recs(Left, Right))
	end},
	{"3 way merge",
	fun() ->
		One = [
			#agent_auth{id = "A", login = "A", timestamp = 1},
			#agent_auth{id = "B", login = "B", timestamp = 3}
		],
		Two = [
			#agent_auth{id = "B", login = "B", timestamp = 3},
			#agent_auth{id = "C", login = "C", timestamp = 5}
		],
		Three = [
			#agent_auth{id = "A", login = "A", timestamp = 5},
			#agent_auth{id = "C", login = "C", timestamp = 1}
		],
		Expected = [
			#agent_auth{id = "A", login = "A", timestamp = 5},
			#agent_auth{id = "B", login = "B", timestamp = 3},
			#agent_auth{id = "C", login = "C", timestamp = 5}
		],
		?assertEqual(Expected, merge_results([{atomic, One}, {atomic, Two}, {atomic, Three}]))
	end}].

-endif.

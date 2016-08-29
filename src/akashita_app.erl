%% -*- coding: utf-8 -*-
%% -------------------------------------------------------------------
%%
%% Copyright (c) 2016 Nathan Fiedler
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License. You may obtain
%% a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied. See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
%%
%% Application management and data storage functions.
%%
-module(akashita_app).
-behaviour(application).
-export([start/2, stop/1, ensure_schema/1]).
-export([retrieve_tag/0, is_bucket_completed/1, remember_completed_bucket/1]).
-export([delete_cache/0]).

% The tag table only has one entry, the previous computed tag.
% The key is 'the_tag', an atom.
-record(akashita_tag, {key   :: atom(),
                       value :: string()}).
-define(THE_TAG, the_tag).

% The buckets table has one row per completed bucket. The key is the bucket
% name, and the value is unused.
-record(akashita_buckets, {name  :: string(),
                           value :: term()}).

start(_Type, _Args) ->
    NodeList = [node()],
    ensure_schema(NodeList),
    ensure_mnesia(NodeList),
    ok = mnesia:wait_for_tables([akashita_tag, akashita_buckets], 5000),
    akashita_sup:start_link().

stop(_) ->
    ok.

% Ensure the schema and our tables are installed in mnesia.
ensure_schema(Nodes) ->
    % create the schema if it does not exist
    case mnesia:system_info(schema_version) of
        {0, 0} ->
            ok = mnesia:create_schema(Nodes);
        {_, _} ->
            ok
    end,
    EnsureTables = fun() ->
        case mnesia:table_info(schema, storage_type) of
            ram_copies ->
                ChangeTable = fun(Node) ->
                    mnesia:change_table_copy_type(schema, Node, disc_copies)
                end,
                [{atomic, ok} = ChangeTable(Node) || Node <- Nodes];
            _ ->
                ok
        end,
        Tables = mnesia:system_info(tables),
        case lists:member(akashita_tag, Tables) of
            false ->
                {atomic, ok} = mnesia:create_table(akashita_tag, [
                    {attributes, record_info(fields, akashita_tag)},
                    {disc_copies, Nodes},
                    {type, bag}
                ]),
                ok;
            true ->
                ok
        end,
        case lists:member(akashita_buckets, Tables) of
            false ->
                {atomic, ok} = mnesia:create_table(akashita_buckets, [
                    {attributes, record_info(fields, akashita_buckets)},
                    {disc_copies, Nodes},
                    {type, set}
                ]),
                ok;
            true ->
                ok
        end
    end,
    % create our tables if they do not exist
    case mnesia:system_info(is_running) of
        no ->
            rpc:multicall(Nodes, application, start, [mnesia]),
            EnsureTables(),
            rpc:multicall(Nodes, application, stop, [mnesia]);
        _ ->
            EnsureTables()
    end.

% Ensure the mnesia application is running on all nodes.
ensure_mnesia(Nodes) ->
    case mnesia:system_info(is_running) of
        no -> rpc:multicall(Nodes, application, start, [mnesia]);
        _ -> ok
    end.

% Retrieve (or compute) the tag used in naming various elements, such as
% zfs snapshots, buckets, objects, etc.
retrieve_tag() ->
    F = fun() ->
        case mnesia:read(akashita_tag, ?THE_TAG) of
            [] ->
                {{Year, Month, Day}, {_Hour, _Min, _Sec}} = calendar:local_time(),
                ValueRaw = io_lib:format("~4.10.0B-~2.10.0B-~2.10.0B", [Year, Month, Day]),
                ValueFlattened = lists:flatten(ValueRaw),
                ok = mnesia:write(#akashita_tag{key=?THE_TAG, value=ValueFlattened}),
                ValueFlattened;
            [Tag] -> Tag#akashita_tag.value
        end
    end,
    mnesia:activity(transaction, F).

% Determine if the named Bucket has already been completed.
% Returns true or false.
is_bucket_completed(Bucket) ->
    F = fun() ->
        case mnesia:read(akashita_buckets, Bucket) of
            [] -> false;
            [_Row] -> true
        end
    end,
    mnesia:activity(transaction, F).

% Remember that the given bucket has been processed, so that the next time
% is_bucket_completed/1 is called, it will return true.
remember_completed_bucket(Bucket) ->
    F = fun() ->
        Value = calendar:local_time(),
        ok = mnesia:write(#akashita_buckets{name=Bucket, value=Value})
    end,
    mnesia:activity(transaction, F).

% All backup processing has successfully completed, wipe out all cached
% data, such as the computed tag and the set of completed buckets.
delete_cache() ->
    {atomic, ok} = mnesia:clear_table(akashita_buckets),
    {atomic, ok} = mnesia:clear_table(akashita_tag),
    ok.

% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License. You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
% License for the specific language governing permissions and limitations under
% the License.


-module(couch_views_reduce).


-export([
    run_reduce/2,
    read_reduce/7
]).


-include("couch_views.hrl").
-include_lib("couch/include/couch_db.hrl").
-include_lib("couch_mrview/include/couch_mrview.hrl").
-include_lib("fabric/include/fabric2.hrl").


run_reduce(#mrst{views = Views}, MappedResults) ->
    lists:map(fun
        (#{deleted := true} = MappedResults0) ->
            MappedResults0;
        (MappedResult) ->
            #{
                results := Results
            } = MappedResult,
            ReduceResults = lists:map(fun ({View, Result}) ->
                #mrview{
                    reduce_funs = ViewReduceFuns
                } = View,
                lists:map(fun({_, ReduceFun}) ->
                    couch_views_reducer:reduce(ReduceFun, Result)
                end, ViewReduceFuns)

            end, lists:zip(Views, Results)),

            MappedResult#{
                reduce_results => ReduceResults
            }
    end, MappedResults).


read_reduce(Db, Sig, ReduceId, Reducer, UserCallback, UserAcc0, Args) ->
    #mrargs{
        limit = Limit,
        group_level = GroupLevel,
        skip = Skip
    } = Args,

    Opts = args_to_btree_opts(Args),

    Acc0 = #{
        sig => Sig,
        view_id => ReduceId,
        user_acc => UserAcc0,
        args => Args,
        callback => UserCallback,
        limit => Limit,
        row_count => 0,
        skip => Skip
    },

    try
        Fun = fun handle_row/3,
        Acc1 = fabric2_fdb:transactional(Db, fun(TxDb) ->
            couch_views_reduce_fdb:fold(TxDb, Sig, ReduceId,
                Reducer, GroupLevel, Opts, Fun, Acc0)
        end),
        #{
            callback := UserCallback,
            user_acc := UserAcc1
        } = Acc1,
        UserAcc2 = maybe_stop(UserCallback(complete, UserAcc1)),
        {ok, UserAcc2}
    catch
        throw:{done, DoneAcc} ->
            {ok, DoneAcc}
    end.


args_to_btree_opts(#mrargs{} = Args) ->
    #mrargs{
        start_key = StartKey,
        end_key = EndKey,
        direction = Direction,
        inclusive_end = InclusiveEnd
    } = Args,

    StartKeyOpts = case {StartKey, Direction} of
        {undefined, rev}  ->
            [{end_key, ebtree:max()}];
        {undefined, fwd}  ->
            [{start_key, ebtree:min()}];
        {StartKey, rev} ->
            [{end_key, {StartKey, ebtree:max()}}];
        {StartKey, fwd} ->
            [{start_key, {StartKey, ebtree:min()}}]
    end,

    EndKeyOpts = case {EndKey, Direction} of
        {undefined, rev} ->
            [{start_key, ebtree:min()}];
        {undefined, fwd} ->
            [{end_key, ebtree:max()}];
        {EndKey, rev} when not InclusiveEnd ->
            [{start_key, {EndKey, ebtree:max()}}];
        {EndKey, rev} when InclusiveEnd ->
            [{start_key, {EndKey, ebtree:min()}}];
        {EndKey, fwd} when InclusiveEnd ->
            [{end_key, {EndKey, ebtree:max()}}];
        {EndKey, fwd} when not InclusiveEnd ->
            [{end_key, {EndKey, ebtree:min()}}]
    end,

    [
        {restart_tx, true},
        {dir, Direction},
        {streaming_mode, want_all}
    ] ++ StartKeyOpts ++ EndKeyOpts.


handle_row(_Key, _Value, #{skip := Skip} = Acc) when Skip > 0 ->
    Acc#{skip := Skip - 1};

handle_row(Key, Value, Acc) ->
    #{
        callback := UserCallback,
        user_acc := UserAcc0,
        row_count := RowCount,
        limit := Limit
    } = Acc,

    Row = [
        {key, Key},
        {value, Value}
    ],

    RowCountNext = RowCount + 1,

    UserAcc1 = maybe_stop(UserCallback({row, Row}, UserAcc0)),
    Acc1 = Acc#{user_acc := UserAcc1, row_count := RowCountNext},

    case RowCountNext == Limit of
        true ->
            UserAcc2 = maybe_stop(UserCallback(complete, UserAcc1)),
            maybe_stop({stop, UserAcc2});
        false ->
            Acc1
    end.


maybe_stop({ok, Acc}) -> Acc;
maybe_stop({stop, Acc}) -> throw({done, Acc}).
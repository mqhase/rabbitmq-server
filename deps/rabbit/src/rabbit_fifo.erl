%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2024 Broadcom. All Rights Reserved. The term “Broadcom” refers to Broadcom Inc. and/or its subsidiaries. All rights reserved.

-module(rabbit_fifo).

-behaviour(ra_machine).

-compile(inline_list_funcs).
-compile(inline).
-compile({no_auto_import, [apply/3]}).
-dialyzer(no_improper_lists).

-include("rabbit_fifo.hrl").
-include_lib("rabbit_common/include/rabbit.hrl").

-define(STATE, ?MODULE).

-define(CONSUMER_PID(Pid), #consumer{cfg = #consumer_cfg{pid = Pid}}).
-define(CONSUMER_PRIORITY(P), #consumer{cfg = #consumer_cfg{priority = P}}).
-define(CONSUMER_TAG_PID(Tag, Pid),
        #consumer{cfg = #consumer_cfg{tag = Tag,
                                      pid = Pid}}).
-define(NON_EMPTY_MAP(M), M when map_size(M) > 0).
-define(EMPTY_MAP, M when map_size(M) == 0).

-export([
         %% ra_machine callbacks
         init/1,
         apply/3,
         state_enter/2,
         tick/2,
         overview/1,

         get_checked_out/4,
         %% versioning
         version/0,
         which_module/1,
         %% aux
         init_aux/1,
         handle_aux/5,
         % queries
         query_messages_ready/1,
         query_messages_checked_out/1,
         query_messages_total/1,
         query_processes/1,
         query_ra_indexes/1,
         query_waiting_consumers/1,
         query_consumer_count/1,
         query_consumers/1,
         query_stat/1,
         query_stat_dlx/1,
         query_single_active_consumer/1,
         query_in_memory_usage/1,
         query_peek/2,
         query_notify_decorators_info/1,
         usage/1,
         is_v4/0,

         %% misc
         dehydrate_state/1,
         normalize/1,
         get_msg_header/1,
         get_header/2,
         get_msg/1,

         %% protocol helpers
         make_enqueue/3,
         make_register_enqueuer/1,
         make_checkout/3,
         make_settle/2,
         make_return/2,
         make_discard/2,
         make_credit/4,
         make_defer/2,
         make_purge/0,
         make_purge_nodes/1,
         make_update_config/1,
         make_eval_consumer_timeouts/1,
         make_garbage_collection/0
        ]).

-ifdef(TEST).
-export([update_header/4,
         chunk_disk_msgs/3,
         smallest_raft_index/1]).
-endif.

-import(serial_number, [add/2, diff/2]).
-define(ENQ_V2, e).

%% command records representing all the protocol actions that are supported
-record(enqueue, {pid :: option(pid()),
                  seq :: option(msg_seqno()),
                  msg :: raw_msg()}).
-record(?ENQ_V2, {seq :: option(msg_seqno()),
                  msg :: raw_msg()}).
-record(requeue, {consumer_key :: consumer_key(),
                  msg_id :: msg_id(),
                  index :: ra:index(),
                  header :: msg_header(),
                  msg :: raw_msg()}).
-record(register_enqueuer, {pid :: pid()}).
-record(checkout, {consumer_id :: consumer_id(),
                   spec :: checkout_spec(),
                   meta :: consumer_meta()}).
-record(settle, {consumer_key :: consumer_key(),
                 msg_ids :: [msg_id()]}).
-record(return, {consumer_key :: consumer_key(),
                 msg_ids :: [msg_id()]}).
-record(discard, {consumer_key :: consumer_key(),
                  msg_ids :: [msg_id()]}).
-record(credit, {consumer_key :: consumer_key(),
                 credit :: non_neg_integer(),
                 delivery_count :: rabbit_queue_type:delivery_count(),
                 drain :: boolean()}).
-record(defer, {consumer_key :: consumer_key(),
                msg_ids :: [msg_id()]}).
-record(purge, {}).
-record(purge_nodes, {nodes :: [node()]}).
-record(update_config, {config :: config()}).
-record(garbage_collection, {}).
-record(eval_consumer_timeouts, {consumer_keys :: [consumer_key()]}).

-opaque protocol() ::
    #enqueue{} |
    #?ENQ_V2{} |
    #requeue{} |
    #register_enqueuer{} |
    #checkout{} |
    #settle{} |
    #return{} |
    #discard{} |
    #credit{} |
    #defer{} |
    #purge{} |
    #purge_nodes{} |
    #update_config{} |
    #garbage_collection{}.

-type command() :: protocol() |
                   rabbit_fifo_dlx:protocol() |
                   ra_machine:builtin_command().
%% all the command types supported by ra fifo

-type client_msg() :: delivery().
%% the messages `rabbit_fifo' can send to consumers.

-opaque state() :: #?STATE{}.

-export_type([protocol/0,
              delivery/0,
              command/0,
              credit_mode/0,
              consumer_meta/0,
              consumer_id/0,
              consumer_key/0,
              client_msg/0,
              msg/0,
              msg_id/0,
              msg_seqno/0,
              delivery_msg/0,
              state/0,
              config/0]).

%% This function is never called since only rabbit_fifo_v0:init/1 is called.
%% See https://github.com/rabbitmq/ra/blob/e0d1e6315a45f5d3c19875d66f9d7bfaf83a46e3/src/ra_machine.erl#L258-L265
-spec init(config()) -> state().
init(#{name := Name,
       queue_resource := Resource} = Conf) ->
    update_config(Conf, #?STATE{cfg = #cfg{name = Name,
                                           resource = Resource}}).

update_config(Conf, State) ->
    DLH = maps:get(dead_letter_handler, Conf, undefined),
    BLH = maps:get(become_leader_handler, Conf, undefined),
    RCI = maps:get(release_cursor_interval, Conf, ?RELEASE_CURSOR_EVERY),
    Overflow = maps:get(overflow_strategy, Conf, drop_head),
    MaxLength = maps:get(max_length, Conf, undefined),
    MaxBytes = maps:get(max_bytes, Conf, undefined),
    DeliveryLimit = maps:get(delivery_limit, Conf, undefined),
    Expires = maps:get(expires, Conf, undefined),
    MsgTTL = maps:get(msg_ttl, Conf, undefined),
    ConsumerStrategy = case maps:get(single_active_consumer_on, Conf, false) of
                           true ->
                               single_active;
                           false ->
                               competing
                       end,
    Cfg = State#?STATE.cfg,
    RCISpec = {RCI, RCI},

    LastActive = maps:get(created, Conf, undefined),
    State#?STATE{cfg = Cfg#cfg{release_cursor_interval = RCISpec,
                               dead_letter_handler = DLH,
                               become_leader_handler = BLH,
                               overflow_strategy = Overflow,
                               max_length = MaxLength,
                               max_bytes = MaxBytes,
                               consumer_strategy = ConsumerStrategy,
                               delivery_limit = DeliveryLimit,
                               expires = Expires,
                               msg_ttl = MsgTTL},
                 last_active = LastActive}.

% msg_ids are scoped per consumer
% ra_indexes holds all raft indexes for enqueues currently on queue
-spec apply(ra_machine:command_meta_data(), command(), state()) ->
    {state(), ra_machine:reply(), ra_machine:effects() | ra_machine:effect()} |
    {state(), ra_machine:reply()}.
apply(Meta, #enqueue{pid = From, seq = Seq,
                     msg = RawMsg}, State00) ->
    apply_enqueue(Meta, From, Seq, RawMsg, State00);
apply(#{reply_mode := {notify, _Corr, EnqPid}} = Meta,
      #?ENQ_V2{seq = Seq, msg = RawMsg}, State00) ->
    apply_enqueue(Meta, EnqPid, Seq, RawMsg, State00);
apply(_Meta, #register_enqueuer{pid = Pid},
      #?STATE{enqueuers = Enqueuers0,
              cfg = #cfg{overflow_strategy = Overflow}} = State0) ->
    State = case maps:is_key(Pid, Enqueuers0) of
                true ->
                    %% if the enqueuer exits just echo the overflow state
                    State0;
                false ->
                    State0#?STATE{enqueuers = Enqueuers0#{Pid => #enqueuer{}}}
            end,
    Res = case is_over_limit(State) of
              true when Overflow == reject_publish ->
                  reject_publish;
              _ ->
                  ok
          end,
    {State, Res, [{monitor, process, Pid}]};
apply(Meta, #settle{msg_ids = MsgIds,
                    consumer_key = Key},
      #?STATE{consumers = Consumers} = State) ->
    case find_consumer(Key, Consumers) of
        {ConsumerKey, Con0} ->
            %% find_consumer/2 returns the actual consumer key even if
            %% if id was passed instead for example
            complete_and_checkout(Meta, MsgIds, ConsumerKey,
                                  reactivate_timed_out(Con0),
                                  [], State);
        _ ->
            {State, {error, invalid_consumer_key}}
    end;
apply(#{index := Idx,
        system_time := Ts} = Meta, #defer{msg_ids = MsgIds,
                                          consumer_key = Key},
      #?STATE{consumers = Consumers} = State0) ->
    case find_consumer(Key, Consumers) of
        {ConsumerKey, #consumer{checked_out = Checked0} = Con0} ->
            Checked = maps:map(fun (MsgId, ?C_MSG(_At, Msg) = Orig) ->
                                       case lists:member(MsgId, MsgIds) of
                                           true ->
                                               ?C_MSG(Ts, Msg);
                                           false ->
                                               Orig
                                       end
                               end, Checked0),
            Con = reactivate_timed_out(Con0#consumer{checked_out = Checked}),
            State1 = State0#?STATE{consumers = Consumers#{ConsumerKey => Con}},
            {State, Ret, Effs} = checkout(Meta, State0, State1, []),
            update_smallest_raft_index(Idx, Ret, State, Effs);
        _ ->
            {State0, {error, invalid_consumer_key}}
    end;
apply(Meta, #discard{consumer_key = ConsumerKey,
                     msg_ids = MsgIds},
      #?STATE{consumers = Consumers,
              dlx = DlxState0,
              cfg = #cfg{dead_letter_handler = DLH}} = State0) ->
    case find_consumer(ConsumerKey, Consumers) of
        {ConsumerKey, #consumer{checked_out = Checked} = Con} ->
            % Publishing to dead-letter exchange must maintain same order as
            % messages got rejected.
            DiscardMsgs = lists:filtermap(
                            fun(Id) ->
                                    case maps:get(Id, Checked, undefined) of
                                        undefined ->
                                            false;
                                        ?C_MSG(_At, Msg) ->
                                            {true, Msg}
                                    end
                            end, MsgIds),
            {DlxState, Effects} = rabbit_fifo_dlx:discard(DiscardMsgs, rejected,
                                                          DLH, DlxState0),
            State = State0#?STATE{dlx = DlxState},
            complete_and_checkout(Meta, MsgIds, ConsumerKey,
                                  reactivate_timed_out(Con),
                                  Effects, State);
        _ ->
            {State0, {error, invalid_consumer_key}}
    end;
apply(Meta, #return{consumer_key = ConsumerKey,
                    msg_ids = MsgIds},
      #?STATE{consumers = Cons0} = State0) ->
    case find_consumer(ConsumerKey, Cons0) of
        {ActualConsumerKey, #consumer{checked_out = Checked0} = Con0} ->

            State = State0#?MODULE{consumers =
                                   Cons0#{ActualConsumerKey =>
                                          reactivate_timed_out(Con0)}},
            Returned = maps:with(MsgIds, Checked0),
            return(Meta, ActualConsumerKey, Returned, [], State);
        _ ->
            {State0, {error, invalid_consumer_key}}
    end;
apply(#{index := Idx} = Meta,
      #requeue{consumer_key = ConsumerKey,
               msg_id = MsgId,
               index = OldIdx,
               header = Header0},
      #?STATE{consumers = Cons0,
              messages = Messages,
              ra_indexes = Indexes0,
              enqueue_count = EnqCount} = State00) ->
    %% the actual consumer key was looked up in the aux handler so we
    %% dont need to use find_consumer/2 here
    case Cons0 of
        #{ConsumerKey := #consumer{checked_out = Checked0} = Con0}
          when is_map_key(MsgId, Checked0) ->
            %% construct a message with the current raft index
            %% and update delivery count before adding it to the message queue
            Header = update_header(delivery_count, fun incr/1, 1, Header0),
            State0 = add_bytes_return(Header, State00),
            Con = Con0#consumer{checked_out = maps:remove(MsgId, Checked0),
                                credit = increase_credit(Con0, 1)},
            State1 = State0#?STATE{ra_indexes = rabbit_fifo_index:delete(OldIdx,
                                                                         Indexes0),
                                   messages = lqueue:in(?MSG(Idx, Header), Messages),
                                   enqueue_count = EnqCount + 1},
            State2 = update_or_remove_con(Meta, ConsumerKey, Con, State1),
            {State, Ret, Effs} = checkout(Meta, State0, State2, []),
            update_smallest_raft_index(Idx, Ret,
                                       maybe_store_release_cursor(Idx,  State),
                                       Effs);
        _ ->
            {State00, ok, []}
    end;
apply(Meta, #credit{credit = LinkCreditRcv,
                    delivery_count = DeliveryCountRcv,
                    drain = Drain,
                    consumer_key = ConsumerKey},
      #?STATE{consumers = Cons0,
              service_queue = ServiceQueue0,
              waiting_consumers = Waiting0} = State0) ->
    case Cons0 of
        #{ConsumerKey := #consumer{delivery_count = DeliveryCountSnd,
                                   cfg = Cfg} = Con0} ->
            LinkCreditSnd = link_credit_snd(DeliveryCountRcv, LinkCreditRcv,
                                            DeliveryCountSnd, Cfg),
            %% grant the credit
            Con1 = Con0#consumer{credit = LinkCreditSnd},
            ServiceQueue = maybe_queue_consumer(ConsumerKey, Con1, ServiceQueue0),
            State1 = State0#?STATE{service_queue = ServiceQueue,
                                   consumers = maps:update(ConsumerKey, Con1, Cons0)},
            {State2, ok, Effects} = checkout(Meta, State0, State1, []),

            #?STATE{consumers = Cons1 = #{ConsumerKey := Con2}} = State2,
            #consumer{cfg = #consumer_cfg{pid = CPid,
                                          tag = CTag},
                      credit = PostCred,
                      delivery_count = PostDeliveryCount} = Con2,
            Available = messages_ready(State2),
            case credit_api_v2(Cfg) of
                true ->
                    {Credit, DeliveryCount, State} =
                        case Drain andalso PostCred > 0 of
                            true ->
                                AdvancedDeliveryCount = add(PostDeliveryCount, PostCred),
                                ZeroCredit = 0,
                                Con = Con2#consumer{delivery_count = AdvancedDeliveryCount,
                                                    credit = ZeroCredit},
                                Cons = maps:update(ConsumerKey, Con, Cons1),
                                State3 = State2#?STATE{consumers = Cons},
                                {ZeroCredit, AdvancedDeliveryCount, State3};
                            false ->
                                {PostCred, PostDeliveryCount, State2}
                        end,
                    %% We must send the delivery effects to the queue client
                    %% before credit_reply such that session process can send to
                    %% AMQP 1.0 client TRANSFERs before FLOW.
                    {State, ok, Effects ++ [{send_msg, CPid,
                                             {credit_reply, CTag, DeliveryCount,
                                              Credit, Available, Drain},
                                             ?DELIVERY_SEND_MSG_OPTS}]};
                false ->
                    %% We must always send a send_credit_reply because basic.credit
                    %% is synchronous.
                    %% Additionally, we keep the bug of credit API v1 that we
                    %% send to queue client the
                    %% send_drained reply before the delivery effects (resulting
                    %% in the wrong behaviour that the session process sends to
                    %% AMQP 1.0 client the FLOW before the TRANSFERs).
                    %% We have to keep this bug because old rabbit_fifo_client
                    %% implementations expect a send_drained Ra reply
                    %% (they can't handle such a Ra effect).
                    CreditReply = {send_credit_reply, Available},
                    case Drain of
                        true ->
                            AdvancedDeliveryCount = PostDeliveryCount + PostCred,
                            Con = Con2#consumer{delivery_count = AdvancedDeliveryCount,
                                                credit = 0},
                            Cons = maps:update(ConsumerKey, Con, Cons1),
                            State = State2#?STATE{consumers = Cons},
                            Reply = {multi, [CreditReply,
                                             {send_drained, {CTag, PostCred}}]},
                            {State, Reply, Effects};
                        false ->
                            {State2, CreditReply, Effects}
                    end
            end;
        _ when Waiting0 /= [] ->
            %% TODO next time when we bump the machine version:
            %% 1. Do not put consumer at head of waiting_consumers if
            %%    NewCredit == 0
            %%    to reduce likelihood of activating a 0 credit consumer.
            %% 2. Support Drain == true, i.e. advance delivery-count,
            %%    consuming all link-credit since there
            %%    are no messages available for an inactive consumer and
            %%    send credit_reply with Drain=true.
            case lists:keytake(ConsumerKey, 1, Waiting0) of
                {value, {_, Con0 = #consumer{delivery_count = DeliveryCountSnd,
                                             cfg = Cfg}}, Waiting} ->
                    LinkCreditSnd = link_credit_snd(DeliveryCountRcv, LinkCreditRcv,
                                                    DeliveryCountSnd, Cfg),
                    %% grant the credit
                    Con = Con0#consumer{credit = LinkCreditSnd},
                    State = State0#?STATE{waiting_consumers =
                                          add_waiting({ConsumerKey, Con}, Waiting)},
                    %% No messages are available for inactive consumers.
                    Available = 0,
                    case credit_api_v2(Cfg) of
                        true ->
                            {State, ok,
                             {send_msg, Cfg#consumer_cfg.pid,
                              {credit_reply, Cfg#consumer_cfg.tag,
                               DeliveryCountSnd, LinkCreditSnd,
                               Available, false},
                              ?DELIVERY_SEND_MSG_OPTS}};
                        false ->
                            {State, {send_credit_reply, Available}}
                    end;
                false ->
                    {State0, ok}
            end;
        _ ->
            %% credit for unknown consumer - just ignore
            {State0, ok}
    end;
apply(_, #checkout{spec = {dequeue, _}},
      #?STATE{cfg = #cfg{consumer_strategy = single_active}} = State0) ->
    {State0, {error, {unsupported, single_active_consumer}}};
apply(#{index := Index,
        system_time := Ts,
        from := From} = Meta, #checkout{spec = {dequeue, Settlement},
                                        meta = ConsumerMeta,
                                        consumer_id = ConsumerId},
      #?STATE{consumers = Consumers} = State00) ->
    %% dequeue always updates last_active
    State0 = State00#?STATE{last_active = Ts},
    %% all dequeue operations result in keeping the queue from expiring
    Exists = find_consumer(ConsumerId, Consumers) /= undefined,
    case messages_ready(State0) of
        0 ->
            update_smallest_raft_index(Index, {dequeue, empty}, State0, []);
        _ when Exists ->
            %% a dequeue using the same consumer_id isn't possible at this point
            {State0, {dequeue, empty}};
        _ ->
            {_, State1} = update_consumer(Meta, ConsumerId, ConsumerId, ConsumerMeta,
                                          {once, {simple_prefetch, 1}}, 0,
                                          State0),
            case checkout_one(Meta, false, State1, []) of
                {success, _, MsgId,
                 ?MSG(RaftIdx, Header), ExpiredMsg, State2, Effects0} ->
                    {State4, Effects1} =
                        case Settlement of
                            unsettled ->
                                {_, Pid} = ConsumerId,
                                {State2, [{monitor, process, Pid} | Effects0]};
                            settled ->
                                %% immediately settle the checkout
                                {State3, _, SettleEffects} =
                                apply(Meta, make_settle(ConsumerId, [MsgId]),
                                      State2),
                                {State3, SettleEffects ++ Effects0}
                        end,
                    Effects2 = [reply_log_effect(RaftIdx, MsgId, Header,
                                                 messages_ready(State4), From)
                                | Effects1],
                    {State, DroppedMsg, Effects} =
                        evaluate_limit(Index, false, State0, State4, Effects2),
                    Reply = '$ra_no_reply',
                    case {DroppedMsg, ExpiredMsg} of
                        {false, false} ->
                            {State, Reply, Effects};
                        _ ->
                            update_smallest_raft_index(Index, Reply, State, Effects)
                    end;
                {nochange, _ExpiredMsg = true, State2, Effects0} ->
                    %% All ready messages expired.
                    State3 = State2#?STATE{consumers =
                                           maps:remove(ConsumerId,
                                                       State2#?STATE.consumers)},
                    {State, _, Effects} = evaluate_limit(Index, false, State0,
                                                         State3, Effects0),
                    update_smallest_raft_index(Index, {dequeue, empty},
                                               State, Effects)
            end
    end;
apply(#{index := Idx} = Meta,
      #checkout{spec = Spec,
                consumer_id = ConsumerId}, State0)
  when Spec == cancel orelse
       Spec == remove ->
    case consumer_key_from_id(ConsumerId, State0) of
        {ok, ConsumerKey} ->
            {State1, Effects1} = activate_next_consumer(
                                   cancel_consumer(Meta, ConsumerKey, State0, [],
                                                   Spec)),
            Reply = {ok, consumer_cancel_info(ConsumerKey, State1)},
            {State, _, Effects} = checkout(Meta, State0, State1, Effects1),
            update_smallest_raft_index(Idx, Reply, State, Effects);
        error ->
            update_smallest_raft_index(Idx, {error, consumer_not_found},
                                       State0, [])
    end;
apply(#{index := Idx} = Meta,
      #checkout{spec = Spec0,
                meta = ConsumerMeta,
                consumer_id = {_, Pid} = ConsumerId}, State0) ->
    %% might be better to check machine_version
    IsV4 = tuple_size(Spec0) == 2,
    %% normalise spec format
    Spec = case Spec0 of
               {_, _} ->
                   Spec0;
               {Life, Prefetch, simple_prefetch} ->
                   {Life, {simple_prefetch, Prefetch}};
               {Life, _Credit, credited} ->
                   {Life, credited}
           end,
    Priority = get_priority(ConsumerMeta),
    ConsumerKey = case consumer_key_from_id(ConsumerId, State0) of
                      {ok, K} ->
                          K;
                      error when IsV4 ->
                          %% if the consumer does not already exist use the
                          %% raft index as it's unique identifier in future
                          %% settle, credit, return and discard operations
                          Idx;
                      error ->
                          ConsumerId
                  end,
    {Consumer, State1} = update_consumer(Meta, ConsumerKey, ConsumerId,
                                         ConsumerMeta, Spec, Priority, State0),
    {State2, Effs} = activate_next_consumer(State1, []),
    #consumer{checked_out = Checked,
              credit = Credit,
              delivery_count = DeliveryCount,
              next_msg_id = NextMsgId} = Consumer,

    %% reply with a consumer summary
    Reply = {ok, #{next_msg_id => NextMsgId,
                   credit => Credit,
                   key => ConsumerKey,
                   delivery_count => DeliveryCount,
                   is_active => is_active(ConsumerKey, State2),
                   num_checked_out => map_size(Checked)}},
    checkout(Meta, State0, State2, [{monitor, process, Pid} | Effs], Reply);
apply(#{index := Index}, #purge{},
      #?STATE{messages_total = Total,
              returns = Returns,
              ra_indexes = Indexes0
             } = State0) ->
    NumReady = messages_ready(State0),
    Indexes = case Total of
                  NumReady ->
                      %% All messages are either in 'messages' queue or
                      %% 'returns' queue.
                      %% No message is awaiting acknowledgement.
                      %% Optimization: empty all 'ra_indexes'.
                      rabbit_fifo_index:empty();
                  _ ->
                      %% Some messages are checked out to consumers
                      %% awaiting acknowledgement.
                      %% Therefore we cannot empty all 'ra_indexes'.
                      %% We only need to delete the indexes from the 'returns'
                      %% queue because messages of the 'messages' queue are
                      %% not part of the 'ra_indexes'.
                      lqueue:fold(fun(?MSG(I, _), Acc) ->
                                          rabbit_fifo_index:delete(I, Acc)
                                  end, Indexes0, Returns)
              end,
    State1 = State0#?STATE{ra_indexes = Indexes,
                           messages = lqueue:new(),
                           messages_total = Total - NumReady,
                           returns = lqueue:new(),
                           msg_bytes_enqueue = 0
                          },
    Effects0 = [garbage_collection],
    Reply = {purge, NumReady},
    {State, _, Effects} = evaluate_limit(Index, false, State0,
                                         State1, Effects0),
    update_smallest_raft_index(Index, Reply, State, Effects);
apply(#{index := Idx}, #garbage_collection{}, State) ->
    update_smallest_raft_index(Idx, ok, State, [{aux, garbage_collection}]);
apply(Meta, {timeout, expire_msgs}, State) ->
    checkout(Meta, State, State, []);
apply(#{system_time := Ts} = Meta,
      {down, Pid, noconnection},
      #?STATE{consumers = Cons0,
              cfg = #cfg{consumer_strategy = single_active},
              waiting_consumers = Waiting0,
              enqueuers = Enqs0} = State0) ->
    Node = node(Pid),
    %% if the pid refers to an active or cancelled consumer,
    %% mark it as suspected and return it to the waiting queue
    {State1, Effects0} =
        maps:fold(
          fun(CKey, ?CONSUMER_PID(P) = C0, {S0, E0})
                when node(P) =:= Node ->
                  %% the consumer should be returned to waiting
                  %% and checked out messages should be returned
                  Effs = consumer_update_active_effects(
                           S0, C0, false, suspected_down, E0),
                  {St, Effs1} = return_all(Meta, S0, Effs, CKey, C0),
                  %% if the consumer was cancelled there is a chance it got
                  %% removed when returning hence we need to be defensive here
                  Waiting = case St#?STATE.consumers of
                                #{CKey := C} ->
                                    Waiting0 ++ [{CKey, C}];
                                _ ->
                                    Waiting0
                            end,
                  {St#?STATE{consumers = maps:remove(CKey, St#?STATE.consumers),
                             waiting_consumers = Waiting,
                             last_active = Ts},
                   Effs1};
             (_, _, S) ->
                  S
          end, {State0, []}, Cons0),
    WaitingConsumers = update_waiting_consumer_status(Node, State1,
                                                      suspected_down),

    %% select a new consumer from the waiting queue and run a checkout
    State2 = State1#?STATE{waiting_consumers = WaitingConsumers},
    {State, Effects1} = activate_next_consumer(State2, Effects0),

    %% mark any enquers as suspected
    Enqs = maps:map(fun(P, E) when node(P) =:= Node ->
                            E#enqueuer{status = suspected_down};
                       (_, E) -> E
                    end, Enqs0),
    Effects = [{monitor, node, Node} | Effects1],
    checkout(Meta, State0, State#?STATE{enqueuers = Enqs}, Effects);
apply(#{system_time := Ts} = Meta,
      {down, Pid, noconnection},
      #?STATE{consumers = Cons0,
               enqueuers = Enqs0} = State0) ->
    %% A node has been disconnected. This doesn't necessarily mean that
    %% any processes on this node are down, they _may_ come back so here
    %% we just mark them as suspected (effectively deactivated)
    %% and return all checked out messages to the main queue for delivery to any
    %% live consumers
    %%
    %% all pids for the disconnected node will be marked as suspected not just
    %% the one we got the `down' command for
    Node = node(Pid),

    {State, Effects1} =
        maps:fold(
          fun(CKey, #consumer{cfg = #consumer_cfg{pid = P},
                              status = up} = C0,
              {St0, Eff}) when node(P) =:= Node ->
                  C = C0#consumer{status = suspected_down},
                  {St, Eff0} = return_all(Meta, St0, Eff, CKey, C),
                  Eff1 = consumer_update_active_effects(St, C, false,
                                                        suspected_down, Eff0),
                  {St, Eff1};
             (_, _, {St, Eff}) ->
                  {St, Eff}
          end, {State0, []}, Cons0),
    Enqs = maps:map(fun(P, E) when node(P) =:= Node ->
                            E#enqueuer{status = suspected_down};
                       (_, E) -> E
                    end, Enqs0),

    % Monitor the node so that we can "unsuspect" these processes when the node
    % comes back, then re-issue all monitors and discover the final fate of
    % these processes

    Effects = [{monitor, node, Node} | Effects1],
    checkout(Meta, State0, State#?STATE{enqueuers = Enqs,
                                        last_active = Ts}, Effects);
apply(#{index := Idx} = Meta, {down, Pid, _Info}, State0) ->
    {State1, Effects1} = activate_next_consumer(
                           handle_down(Meta, Pid, State0)),
    {State, Reply, Effects} = checkout(Meta, State0, State1, Effects1),
    update_smallest_raft_index(Idx, Reply, State, Effects);
apply(Meta, {nodeup, Node}, #?STATE{consumers = Cons0,
                                    enqueuers = Enqs0,
                                    service_queue = _SQ0} = State0) ->
    %% A node we are monitoring has come back.
    %% If we have suspected any processes of being
    %% down we should now re-issue the monitors for them to detect if they're
    %% actually down or not
    Monitors = [{monitor, process, P}
                || P <- suspected_pids_for(Node, State0)],

    Enqs1 = maps:map(fun(P, E) when node(P) =:= Node ->
                             E#enqueuer{status = up};
                        (_, E) -> E
                     end, Enqs0),
    ConsumerUpdateActiveFun = consumer_active_flag_update_function(State0),
    %% mark all consumers as up
    {State1, Effects1} =
        maps:fold(fun(ConsumerKey, ?CONSUMER_PID(P) = C, {SAcc, EAcc})
                        when (node(P) =:= Node) and
                             (C#consumer.status =/= cancelled) ->
                          EAcc1 = ConsumerUpdateActiveFun(SAcc, ConsumerKey,
                                                          C, true, up, EAcc),
                          {update_or_remove_con(Meta, ConsumerKey,
                                                C#consumer{status = up},
                                                SAcc), EAcc1};
                     (_, _, Acc) ->
                          Acc
                  end, {State0, Monitors}, Cons0),
    Waiting = update_waiting_consumer_status(Node, State1, up),
    State2 = State1#?STATE{enqueuers = Enqs1,
                           waiting_consumers = Waiting},
    {State, Effects} = activate_next_consumer(State2, Effects1),
    checkout(Meta, State0, State, Effects);
apply(_, {nodedown, _Node}, State) ->
    {State, ok};
apply(#{index := Idx} = Meta, #purge_nodes{nodes = Nodes}, State0) ->
    {State, Effects} = lists:foldl(fun(Node, {S, E}) ->
                                           purge_node(Meta, Node, S, E)
                                   end, {State0, []}, Nodes),
    update_smallest_raft_index(Idx, ok, State, Effects);
apply(#{index := Idx} = Meta,
      #update_config{config = #{dead_letter_handler := NewDLH} = Conf},
      #?STATE{cfg = #cfg{dead_letter_handler = OldDLH,
                         resource = QRes},
              dlx = DlxState0} = State0) ->
    {DlxState, Effects0} = rabbit_fifo_dlx:update_config(OldDLH, NewDLH, QRes,
                                                         DlxState0),
    State1 = update_config(Conf, State0#?STATE{dlx = DlxState}),
    {State, Reply, Effects} = checkout(Meta, State0, State1, Effects0),
    update_smallest_raft_index(Idx, Reply, State, Effects);
apply(Meta, {machine_version, FromVersion, ToVersion}, V0State) ->
    State = convert(Meta, FromVersion, ToVersion, V0State),
    {State, ok, [{aux, {dlx, setup}}]};
apply(#{index := IncomingRaftIdx} = Meta, {dlx, _} = Cmd,
      #?STATE{cfg = #cfg{dead_letter_handler = DLH},
               dlx = DlxState0} = State0) ->
    {DlxState, Effects0} = rabbit_fifo_dlx:apply(Meta, Cmd, DLH, DlxState0),
    State1 = State0#?STATE{dlx = DlxState},
    {State, ok, Effects} = checkout(Meta, State0, State1, Effects0),
    update_smallest_raft_index(IncomingRaftIdx, State, Effects);
apply(Meta, #eval_consumer_timeouts{consumer_keys = CKeys}, State) ->
    eval_consumer_timeouts(Meta, CKeys, State);
apply(_Meta, Cmd, State) ->
    %% handle unhandled commands gracefully
    rabbit_log:debug("rabbit_fifo: unhandled command ~W", [Cmd, 10]),
    {State, ok, []}.

eval_consumer_timeouts(#{system_time := Ts} = Meta, CKeys,
                       #?STATE{cfg = #cfg{consumer_strategy = competing},
                               consumers = Consumers0} = State0) ->
    ToCheck = maps:with(CKeys, Consumers0),
    {State, Effects} =
    maps:fold(
      fun (Ckey, #consumer{cfg = #consumer_cfg{},
                           status = up,
                           checked_out = Ch} = C0,
           {#?STATE{consumers = Cons} = S0, E0} = Acc) ->
              case maps:filter(fun (_MsgId, ?C_MSG(At, _)) ->
                                       (At + ?CONSUMER_LOCK_MS) < Ts
                               end, Ch) of
                  ?EMPTY_MAP ->
                      Acc;
                  ?NON_EMPTY_MAP(ToReturn) ->
                      %% there are timed out messages,
                      %% update consumer state to `timed_out'
                      %% TODO: only if current status us `up'
                      C1 = C0#consumer{status = timed_out},
                      S1 = S0#?STATE{consumers = Cons#{Ckey => C1}},
                      {S, E1} = maps:fold(
                                  fun(MsgId, ?C_MSG(_At, Msg), {S2, E1}) ->
                                          return_one(Meta, MsgId, Msg,
                                                     S2, E1, Ckey)
                                  end, {S1, E0}, ToReturn),
                      E = [{consumer_timeout, Ckey, maps:keys(ToReturn)} | E1],
                      C = maps:get(Ckey, S#?STATE.consumers),
                      {update_or_remove_con(Meta, Ckey, C, S), E}
              end;
          (_Ckey, _Con, Acc) ->
              Acc
      end, {State0, []}, ToCheck),

    {State, ok, Effects}.

convert_v3_to_v4(#{system_time := Ts},
                 #rabbit_fifo{consumers = Consumers0} = StateV3) ->
    Consumers = maps:map(
                  fun (_CKey, #consumer{checked_out = Ch0} = C) ->
                          Ch = maps:map(
                                 fun (_MsgId, ?MSG(_, _) = Msg) ->
                                         ?C_MSG(Ts, Msg)
                                 end, Ch0),
                          C#consumer{checked_out = Ch}
                  end, Consumers0),
    StateV3#?MODULE{consumers = Consumers}.

purge_node(Meta, Node, State, Effects) ->
    lists:foldl(fun(Pid, {S0, E0}) ->
                        {S, E} = handle_down(Meta, Pid, S0),
                        {S, E0 ++ E}
                end, {State, Effects},
                all_pids_for(Node, State)).

%% any downs that re not noconnection
handle_down(Meta, Pid, #?STATE{consumers = Cons0,
                               enqueuers = Enqs0} = State0) ->
    % Remove any enqueuer for the down pid
    State1 = State0#?STATE{enqueuers = maps:remove(Pid, Enqs0)},
    {Effects1, State2} = handle_waiting_consumer_down(Pid, State1),
    % return checked out messages to main queue
    % Find the consumers for the down pid
    DownConsumers = maps:keys(maps:filter(fun(_CKey, ?CONSUMER_PID(P)) ->
                                                  P =:= Pid
                                          end, Cons0)),
    lists:foldl(fun(ConsumerKey, {S, E}) ->
                        cancel_consumer(Meta, ConsumerKey, S, E, down)
                end, {State2, Effects1}, DownConsumers).

consumer_active_flag_update_function(
  #?STATE{cfg = #cfg{consumer_strategy = competing}}) ->
    fun(State, _ConsumerKey, Consumer, Active, ActivityStatus, Effects) ->
            consumer_update_active_effects(State, Consumer, Active,
                                           ActivityStatus, Effects)
    end;
consumer_active_flag_update_function(
  #?STATE{cfg = #cfg{consumer_strategy = single_active}}) ->
    fun(_, _, _, _, _, Effects) ->
            Effects
    end.

handle_waiting_consumer_down(_Pid,
                             #?STATE{cfg = #cfg{consumer_strategy = competing}}
                             = State) ->
    {[], State};
handle_waiting_consumer_down(_Pid,
                             #?STATE{cfg = #cfg{consumer_strategy = single_active},
                                     waiting_consumers = []} = State) ->
    {[], State};
handle_waiting_consumer_down(Pid,
                             #?STATE{cfg = #cfg{consumer_strategy = single_active},
                                     waiting_consumers = WaitingConsumers0}
                             = State0) ->
    % get cancel effects for down waiting consumers
    Down = lists:filter(fun({_, ?CONSUMER_PID(P)}) -> P =:= Pid end,
                        WaitingConsumers0),
    Effects = lists:foldl(fun ({_ConsumerKey, Consumer}, Effects) ->
                                  ConsumerId = consumer_id(Consumer),
                                  cancel_consumer_effects(ConsumerId, State0,
                                                          Effects)
                          end, [], Down),
    % update state to have only up waiting consumers
    StillUp = lists:filter(fun({_CKey, ?CONSUMER_PID(P)}) ->
                                   P =/= Pid
                           end,
                           WaitingConsumers0),
    State = State0#?STATE{waiting_consumers = StillUp},
    {Effects, State}.

update_waiting_consumer_status(Node,
                               #?STATE{waiting_consumers = WaitingConsumers},
                               Status) ->
    sort_waiting(
      [begin
           case node(Pid) of
               Node ->
                   {ConsumerKey, Consumer#consumer{status = Status}};
               _ ->
                   {ConsumerKey, Consumer}
           end
       end || {ConsumerKey, ?CONSUMER_PID(Pid) =  Consumer}
              <- WaitingConsumers, Consumer#consumer.status =/= cancelled]).

-spec state_enter(ra_server:ra_state() | eol, state()) ->
    ra_machine:effects().
state_enter(RaState, #?STATE{cfg = #cfg{dead_letter_handler = DLH,
                                        resource = QRes},
                             dlx = DlxState} = State) ->
    Effects = rabbit_fifo_dlx:state_enter(RaState, QRes, DLH, DlxState),
    state_enter0(RaState, State, Effects).

state_enter0(leader, #?STATE{consumers = Cons,
                             enqueuers = Enqs,
                             waiting_consumers = WaitingConsumers,
                             cfg = #cfg{name = Name,
                                        resource = Resource,
                                        become_leader_handler = BLH}
                            } = State,
             Effects0) ->
    TimerEffs = timer_effect(erlang:system_time(millisecond), State, Effects0),
    % return effects to monitor all current consumers and enqueuers
    Pids = lists:usort(maps:keys(Enqs)
        ++ [P || ?CONSUMER_PID(P) <- maps:values(Cons)]
        ++ [P || {_, ?CONSUMER_PID(P)} <- WaitingConsumers]),
    Mons = [{monitor, process, P} || P <- Pids],
    Nots = [{send_msg, P, leader_change, ra_event} || P <- Pids],
    NodeMons = lists:usort([{monitor, node, node(P)} || P <- Pids]),
    FHReservation = [{mod_call, rabbit_quorum_queue,
                      file_handle_leader_reservation, [Resource]}],
    NotifyDecs = notify_decorators_startup(Resource),
    Effects = TimerEffs ++ Mons ++ Nots ++ NodeMons ++ FHReservation ++ [NotifyDecs],
    case BLH of
        undefined ->
            Effects;
        {Mod, Fun, Args} ->
            [{mod_call, Mod, Fun, Args ++ [Name]} | Effects]
    end;
state_enter0(eol, #?STATE{enqueuers = Enqs,
                          consumers = Cons0,
                          waiting_consumers = WaitingConsumers0},
             Effects) ->
    Custs = maps:fold(fun(_K, ?CONSUMER_PID(P) = V, S) ->
                              S#{P => V}
                      end, #{}, Cons0),
    WaitingConsumers1 = lists:foldl(fun({_, ?CONSUMER_PID(P) = V}, Acc) ->
                                            Acc#{P => V}
                                    end, #{}, WaitingConsumers0),
    AllConsumers = maps:merge(Custs, WaitingConsumers1),
    [{send_msg, P, eol, ra_event}
     || P <- maps:keys(maps:merge(Enqs, AllConsumers))] ++
    [{aux, eol},
     {mod_call, rabbit_quorum_queue, file_handle_release_reservation, []}
     | Effects];
state_enter0(State, #?STATE{cfg = #cfg{resource = _Resource}}, Effects)
  when State =/= leader ->
    FHReservation = {mod_call, rabbit_quorum_queue,
                     file_handle_other_reservation, []},
    [FHReservation | Effects];
state_enter0(_, _, Effects) ->
    %% catch all as not handling all states
    Effects.

-spec tick(non_neg_integer(), state()) -> ra_machine:effects().
tick(Ts, #?STATE{cfg = #cfg{name = _Name,
                            resource = QName}} = State) ->
    case is_expired(Ts, State) of
        true ->
            [{mod_call, rabbit_quorum_queue, spawn_deleter, [QName]}];
        false ->
            [{aux, {handle_tick, [QName, overview(State), all_nodes(State)]}}]
    end.

-spec overview(state()) -> map().
overview(#?STATE{consumers = Cons,
                 enqueuers = Enqs,
                 release_cursors = Cursors,
                 enqueue_count = EnqCount,
                 msg_bytes_enqueue = EnqueueBytes,
                 msg_bytes_checkout = CheckoutBytes,
                 cfg = Cfg,
                 dlx = DlxState,
                 waiting_consumers = WaitingConsumers} = State) ->
    Conf = #{name => Cfg#cfg.name,
             resource => Cfg#cfg.resource,
             release_cursor_interval => Cfg#cfg.release_cursor_interval,
             dead_lettering_enabled => undefined =/= Cfg#cfg.dead_letter_handler,
             max_length => Cfg#cfg.max_length,
             max_bytes => Cfg#cfg.max_bytes,
             consumer_strategy => Cfg#cfg.consumer_strategy,
             expires => Cfg#cfg.expires,
             msg_ttl => Cfg#cfg.msg_ttl,
             delivery_limit => Cfg#cfg.delivery_limit
            },
    SacOverview = case active_consumer(Cons) of
                      {SacConsumerKey, SacCon} ->
                          SacConsumerId = consumer_id(SacCon),
                          NumWaiting = length(WaitingConsumers),
                          #{single_active_consumer_id => SacConsumerId,
                            single_active_consumer_key => SacConsumerKey,
                            single_active_num_waiting_consumers => NumWaiting};
                      _ ->
                          #{}
                  end,
    Overview = #{type => ?STATE,
                 config => Conf,
                 num_consumers => map_size(Cons),
                 num_active_consumers => query_consumer_count(State),
                 num_checked_out => num_checked_out(State),
                 num_enqueuers => maps:size(Enqs),
                 num_ready_messages => messages_ready(State),
                 num_in_memory_ready_messages => 0, %% backwards compat
                 num_messages => messages_total(State),
                 num_release_cursors => lqueue:len(Cursors),
                 release_cursors => [I || {_, I, _} <- lqueue:to_list(Cursors)],
                 release_cursor_enqueue_counter => EnqCount,
                 enqueue_message_bytes => EnqueueBytes,
                 checkout_message_bytes => CheckoutBytes,
                 in_memory_message_bytes => 0, %% backwards compat
                 smallest_raft_index => smallest_raft_index(State)
                 },
    DlxOverview = rabbit_fifo_dlx:overview(DlxState),
    maps:merge(maps:merge(Overview, DlxOverview), SacOverview).

-spec get_checked_out(consumer_key(), msg_id(), msg_id(), state()) ->
    [delivery_msg()].
get_checked_out(CKey, From, To, #?STATE{consumers = Consumers}) ->
    case find_consumer(CKey, Consumers) of
        {_CKey, #consumer{checked_out = Checked}} ->
            [begin
                 ?C_MSG(_At, I, H) = maps:get(K, Checked),
                 {K, {I, H}}
             end || K <- lists:seq(From, To), maps:is_key(K, Checked)];
        _ ->
            []
    end.

-spec version() -> pos_integer().
version() -> 4.

which_module(0) -> rabbit_fifo_v0;
which_module(1) -> rabbit_fifo_v1;
which_module(2) -> rabbit_fifo_v3;
which_module(3) -> rabbit_fifo_v3;
which_module(4) -> ?STATE.

-define(AUX, aux_v3).

-record(aux_gc, {last_raft_idx = 0 :: ra:index()}).
-record(aux, {name :: atom(),
              capacity :: term(),
              gc = #aux_gc{} :: #aux_gc{}}).
-record(aux_v2, {name :: atom(),
                 last_decorators_state :: term(),
                 capacity :: term(),
                 gc = #aux_gc{} :: #aux_gc{},
                 tick_pid :: undefined | pid(),
                 cache = #{} :: map()}).
-record(?AUX, {name :: atom(),
               last_decorators_state :: term(),
               capacity :: term(),
               gc = #aux_gc{} :: #aux_gc{},
               tick_pid :: undefined | pid(),
               cache = #{} :: map(),
               last_consumer_timeout_check :: milliseconds(),
               reserved_1,
               reserved_2}).

init_aux(Name) when is_atom(Name) ->
    %% TODO: catch specific exception throw if table already exists
    ok = ra_machine_ets:create_table(rabbit_fifo_usage,
                                     [named_table, set, public,
                                      {write_concurrency, true}]),
    Now = erlang:monotonic_time(micro_seconds),
    #?AUX{name = Name,
          last_consumer_timeout_check = erlang:system_time(millisecond),
          capacity = {inactive, Now, 1, 1.0}}.

handle_aux(RaftState, Tag, Cmd, #aux{name = Name,
                                     capacity = Cap,
                                     gc = Gc
                                    }, RaAux) ->
    %% convert aux state to new version
    Aux = #?AUX{name = Name,
                capacity = Cap,
                gc = Gc,
                last_consumer_timeout_check = erlang:system_time(millisecond)
               },
    handle_aux(RaftState, Tag, Cmd, Aux, RaAux);
handle_aux(RaftState, Tag, Cmd, #aux_v2{name = Name,
                                        last_decorators_state = LDS,
                                        capacity = Cap,
                                        gc = Gc,
                                        tick_pid = TickPid,
                                        cache = Cache
                                       }, RaAux) ->
    %% convert aux state to new version
    Aux = #?AUX{name = Name,
                last_decorators_state = LDS,
                capacity = Cap,
                gc = Gc,
                tick_pid = TickPid,
                cache = Cache,
                last_consumer_timeout_check = erlang:system_time(millisecond)
               },
    handle_aux(RaftState, Tag, Cmd, Aux, RaAux);
handle_aux(_RaftState, cast, {#return{msg_ids = MsgIds,
                                      consumer_key = Key} = Ret, Corr, Pid},
           Aux0, RaAux0) ->
    case ra_aux:machine_state(RaAux0) of
        #?STATE{cfg = #cfg{delivery_limit = undefined},
                consumers = Consumers} ->
            case find_consumer(Key, Consumers) of
                {ConsumerKey, #consumer{checked_out = Checked}} ->
                    {RaAux, ToReturn} =
                    maps:fold(
                      fun (MsgId, ?C_MSG(_, Idx, Header), {RA0, Acc}) ->
                              %% it is possible this is not found if the consumer
                              %% crashed and the message got removed
                              case ra_aux:log_fetch(Idx, RA0) of
                                  {{_Term, _Meta, Cmd}, RA} ->
                                      Msg = get_msg(Cmd),
                                      {RA, [{MsgId, Idx, Header, Msg} | Acc]};
                                  {undefined, RA} ->
                                      {RA, Acc}
                              end
                      end, {RaAux0, []}, maps:with(MsgIds, Checked)),

                    Appends = make_requeue(ConsumerKey, {notify, Corr, Pid},
                                           lists:sort(ToReturn), []),
                    {no_reply, Aux0, RaAux, Appends};
                _ ->
                    {no_reply, Aux0, RaAux0}
            end;
        _ ->
            %% for returns with a delivery limit set we can just return as before
            {no_reply, Aux0, RaAux0, [{append, Ret, {notify, Corr, Pid}}]}
    end;
handle_aux(leader, _, {handle_tick, [QName, Overview0, Nodes]},
           #?AUX{tick_pid = Pid,
                 last_consumer_timeout_check = LastCheck} = Aux, RaAux) ->
    Overview = Overview0#{members_info => ra_aux:members_info(RaAux)},
    NewPid =
        case process_is_alive(Pid) of
            false ->
                %% No active TICK pid
                %% this function spawns and returns the tick process pid
                rabbit_quorum_queue:handle_tick(QName, Overview, Nodes);
            true ->
                %% Active TICK pid, do nothing
                Pid
        end,
    %% check consumer timeouts
    Now = erlang:system_time(millisecond),
    case Now - LastCheck > 1000 of
        true ->
            %% check if there are any consumer checked out message that have
            %% timed out.
            {no_reply, Aux#?AUX{tick_pid = NewPid,
                                last_consumer_timeout_check = Now}, RaAux};
        false ->
            {no_reply, Aux#?AUX{tick_pid = NewPid}, RaAux}
    end;
handle_aux(_, _, {get_checked_out, ConsumerKey, MsgIds}, Aux0, RaAux0) ->
    #?STATE{cfg = #cfg{},
            consumers = Consumers} = ra_aux:machine_state(RaAux0),
    case Consumers of
        #{ConsumerKey := #consumer{checked_out = Checked}} ->
            {RaState, IdMsgs} =
                maps:fold(
                  fun (MsgId, ?C_MSG(_, Idx, Header), {S0, Acc}) ->
                          %% it is possible this is not found if the consumer
                          %% crashed and the message got removed
                          case ra_aux:log_fetch(Idx, S0) of
                              {{_Term, _Meta, Cmd}, S} ->
                                  Msg = get_msg(Cmd),
                                  {S, [{MsgId, {Header, Msg}} | Acc]};
                              {undefined, S} ->
                                  {S, Acc}
                          end
                  end, {RaAux0, []}, maps:with(MsgIds, Checked)),
            {reply, {ok,  IdMsgs}, Aux0, RaState};
        _ ->
            {reply, {error, consumer_not_found}, Aux0, RaAux0}
    end;
handle_aux(leader, cast, eval, #?AUX{last_decorators_state = LastDec} = Aux0,
           RaAux) ->
    #?STATE{cfg = #cfg{resource = QName}} = MacState =
        ra_aux:machine_state(RaAux),
    %% this is called after each batch of commands have been applied
    %% set timer for message expire
    %% should really be the last applied index ts but this will have to do
    Ts = erlang:system_time(millisecond),
    Effects0 = timer_effect(Ts, MacState, []),
    case query_notify_decorators_info(MacState) of
        LastDec ->
            {no_reply, Aux0, RaAux, Effects0};
        {MaxActivePriority, IsEmpty} = NewLast ->
            Effects = [notify_decorators_effect(QName, MaxActivePriority, IsEmpty)
                       | Effects0],
            {no_reply, Aux0#?AUX{last_decorators_state = NewLast}, RaAux, Effects}
    end;
handle_aux(_RaftState, cast, eval, Aux0, RaAux) ->
    {no_reply, Aux0, RaAux};
handle_aux(_RaState, cast, Cmd, #?AUX{capacity = Use0} = Aux0, RaAux)
  when Cmd == active orelse Cmd == inactive ->
    {no_reply, Aux0#?AUX{capacity = update_use(Use0, Cmd)}, RaAux};
handle_aux(_RaState, cast, tick, #?AUX{name = Name,
                                       capacity = Use0} = State0,
           RaAux) ->
    true = ets:insert(rabbit_fifo_usage,
                      {Name, capacity(Use0)}),
    Aux = eval_gc(RaAux, ra_aux:machine_state(RaAux), State0),
    {no_reply, Aux, RaAux};
handle_aux(_RaState, cast, eol, #?AUX{name = Name} = Aux, RaAux) ->
    ets:delete(rabbit_fifo_usage, Name),
    {no_reply, Aux, RaAux};
handle_aux(_RaState, {call, _From}, oldest_entry_timestamp,
           #?AUX{cache = Cache} = Aux0, RaAux0) ->
    {CachedIdx, CachedTs} = maps:get(oldest_entry, Cache,
                                     {undefined, undefined}),
    case smallest_raft_index(ra_aux:machine_state(RaAux0)) of
        %% if there are no entries, we return current timestamp
        %% so that any previously obtained entries are considered
        %% older than this
        undefined ->
            Aux1 = Aux0#?AUX{cache = maps:remove(oldest_entry, Cache)},
            {reply, {ok, erlang:system_time(millisecond)}, Aux1, RaAux0};
        CachedIdx ->
            %% cache hit
            {reply, {ok, CachedTs}, Aux0, RaAux0};
        Idx when is_integer(Idx) ->
            case ra_aux:log_fetch(Idx, RaAux0) of
                {{_Term, #{ts := Timestamp}, _Cmd}, RaAux} ->
                    Aux1 = Aux0#?AUX{cache = Cache#{oldest_entry =>
                                                    {Idx, Timestamp}}},
                    {reply, {ok, Timestamp}, Aux1, RaAux};
                {undefined, RaAux} ->
                    %% fetch failed
                    {reply, {error, failed_to_get_timestamp}, Aux0, RaAux}
            end
    end;
handle_aux(_RaState, {call, _From}, {peek, Pos}, Aux0,
           RaAux0) ->
    MacState = ra_aux:machine_state(RaAux0),
    case query_peek(Pos, MacState) of
        {ok, ?MSG(Idx, Header)} ->
            %% need to re-hydrate from the log
            {{_, _, Cmd}, RaAux} = ra_aux:log_fetch(Idx, RaAux0),
            Msg = get_msg(Cmd),
            {reply, {ok, {Header, Msg}}, Aux0, RaAux};
        Err ->
            {reply, Err, Aux0, RaAux0}
    end;
handle_aux(_, _, garbage_collection, Aux, RaAux) ->
    {no_reply, force_eval_gc(RaAux, Aux), RaAux};
handle_aux(RaState, _, {dlx, _} = Cmd, Aux0, RaAux) ->
    #?STATE{dlx = DlxState,
            cfg = #cfg{dead_letter_handler = DLH,
                       resource = QRes}} = ra_aux:machine_state(RaAux),
    Aux = rabbit_fifo_dlx:handle_aux(RaState, Cmd, Aux0, QRes, DLH, DlxState),
    {no_reply, Aux, RaAux}.

eval_gc(RaAux, MacState,
        #?AUX{gc = #aux_gc{last_raft_idx = LastGcIdx} = Gc} = AuxState) ->
    {Idx, _} = ra_aux:log_last_index_term(RaAux),
    #?STATE{cfg = #cfg{resource = QR}} = ra_aux:machine_state(RaAux),
    {memory, Mem} = erlang:process_info(self(), memory),
    case messages_total(MacState) of
        0 when Idx > LastGcIdx andalso
               Mem > ?GC_MEM_LIMIT_B ->
            garbage_collect(),
            {memory, MemAfter} = erlang:process_info(self(), memory),
            rabbit_log:debug("~ts: full GC sweep complete. "
                            "Process memory changed from ~.2fMB to ~.2fMB.",
                            [rabbit_misc:rs(QR), Mem/?MB, MemAfter/?MB]),
            AuxState#?AUX{gc = Gc#aux_gc{last_raft_idx = Idx}};
        _ ->
            AuxState
    end.

force_eval_gc(%Log,
              RaAux,
              #?AUX{gc = #aux_gc{last_raft_idx = LastGcIdx} = Gc} = AuxState) ->
    {Idx, _} = ra_aux:log_last_index_term(RaAux),
    #?STATE{cfg = #cfg{resource = QR}} = ra_aux:machine_state(RaAux),
    {memory, Mem} = erlang:process_info(self(), memory),
    case Idx > LastGcIdx of
        true ->
            garbage_collect(),
            {memory, MemAfter} = erlang:process_info(self(), memory),
            rabbit_log:debug("~ts: full GC sweep complete. "
                            "Process memory changed from ~.2fMB to ~.2fMB.",
                             [rabbit_misc:rs(QR), Mem/?MB, MemAfter/?MB]),
            AuxState#?AUX{gc = Gc#aux_gc{last_raft_idx = Idx}};
        false ->
            AuxState
    end.

process_is_alive(Pid) when is_pid(Pid) ->
    is_process_alive(Pid);
process_is_alive(_) ->
    false.
%%% Queries

query_messages_ready(State) ->
    messages_ready(State).

query_messages_checked_out(#?STATE{consumers = Consumers}) ->
    maps:fold(fun (_, #consumer{checked_out = C}, S) ->
                      maps:size(C) + S
              end, 0, Consumers).

query_messages_total(State) ->
    messages_total(State).

query_processes(#?STATE{enqueuers = Enqs, consumers = Cons0}) ->
    Cons = maps:fold(fun(_, ?CONSUMER_PID(P) = V, S) ->
                             S#{P => V}
                     end, #{}, Cons0),
    maps:keys(maps:merge(Enqs, Cons)).


query_ra_indexes(#?STATE{ra_indexes = RaIndexes}) ->
    RaIndexes.

query_waiting_consumers(#?STATE{waiting_consumers = WaitingConsumers}) ->
    WaitingConsumers.

query_consumer_count(#?STATE{consumers = Consumers,
                             waiting_consumers = WaitingConsumers}) ->
    Up = maps:filter(fun(_ConsumerKey, #consumer{status = Status}) ->
                             Status =/= suspected_down
                     end, Consumers),
    maps:size(Up) + length(WaitingConsumers).

query_consumers(#?STATE{consumers = Consumers,
                        waiting_consumers = WaitingConsumers,
                        cfg = #cfg{consumer_strategy = ConsumerStrategy}}
                = State) ->
    ActiveActivityStatusFun =
    case ConsumerStrategy of
            competing ->
                fun(_ConsumerKey, #consumer{status = Status}) ->
                        case Status of
                            suspected_down  ->
                                {false, Status};
                            _ ->
                                {true, Status}
                        end
                end;
            single_active ->
                SingleActiveConsumer = query_single_active_consumer(State),
                fun(_, ?CONSUMER_TAG_PID(Tag, Pid)) ->
                        case SingleActiveConsumer of
                            {value, {Tag, Pid}} ->
                                {true, single_active};
                            _ ->
                                {false, waiting}
                        end
                end
        end,
    FromConsumers =
        maps:fold(fun (_, #consumer{status = cancelled}, Acc) ->
                          Acc;
                      (Key,
                       #consumer{cfg = #consumer_cfg{tag = Tag,
                                                     pid = Pid,
                                                     meta = Meta}} = Consumer,
                       Acc) ->
                          {Active, ActivityStatus} =
                              ActiveActivityStatusFun(Key, Consumer),
                          maps:put(Key,
                                   {Pid, Tag,
                                    maps:get(ack, Meta, undefined),
                                    maps:get(prefetch, Meta, undefined),
                                    Active,
                                    ActivityStatus,
                                    maps:get(args, Meta, []),
                                    maps:get(username, Meta, undefined)},
                                   Acc)
                  end, #{}, Consumers),
        FromWaitingConsumers =
            lists:foldl(
              fun ({_, #consumer{status = cancelled}},
                   Acc) ->
                      Acc;
                  ({Key,
                    #consumer{cfg = #consumer_cfg{tag = Tag,
                                                  pid = Pid,
                                                  meta = Meta}} = Consumer},
                   Acc) ->
                      {Active, ActivityStatus} =
                          ActiveActivityStatusFun(Key, Consumer),
                      maps:put(Key,
                               {Pid, Tag,
                                maps:get(ack, Meta, undefined),
                                maps:get(prefetch, Meta, undefined),
                                Active,
                                ActivityStatus,
                                maps:get(args, Meta, []),
                                maps:get(username, Meta, undefined)},
                               Acc)
              end, #{}, WaitingConsumers),
        maps:merge(FromConsumers, FromWaitingConsumers).


query_single_active_consumer(#?STATE{cfg = #cfg{consumer_strategy = single_active},
                                     consumers = Consumers}) ->
    case active_consumer(Consumers) of
        undefined ->
            {error, no_value};
        {_CKey, ?CONSUMER_TAG_PID(Tag, Pid)} ->
            {value, {Tag, Pid}}
    end;
query_single_active_consumer(_) ->
    disabled.

query_stat(#?STATE{consumers = Consumers} = State) ->
    {messages_ready(State), maps:size(Consumers)}.

query_in_memory_usage(#?STATE{ }) ->
    {0, 0}.

query_stat_dlx(#?STATE{dlx = DlxState}) ->
    rabbit_fifo_dlx:stat(DlxState).

query_peek(Pos, State0) when Pos > 0 ->
    case take_next_msg(State0) of
        empty ->
            {error, no_message_at_pos};
        {Msg, _State}
          when Pos == 1 ->
            {ok, Msg};
        {_Msg, State} ->
            query_peek(Pos-1, State)
    end.

query_notify_decorators_info(#?STATE{consumers = Consumers} = State) ->
    MaxActivePriority = maps:fold(
                          fun(_, #consumer{credit = C,
                                           status = up,
                                           cfg = #consumer_cfg{priority = P}},
                              MaxP) when C > 0 ->
                                  case MaxP of
                                      empty -> P;
                                      MaxP when MaxP > P -> MaxP;
                                      _ -> P
                                  end;
                             (_, _, MaxP) ->
                                  MaxP
                          end, empty, Consumers),
    IsEmpty = (messages_ready(State) == 0),
    {MaxActivePriority, IsEmpty}.

-spec usage(atom()) -> float().
usage(Name) when is_atom(Name) ->
    case ets:lookup(rabbit_fifo_usage, Name) of
        [] -> 0.0;
        [{_, Use}] -> Use
    end.

is_v4() ->
    rabbit_feature_flags:is_enabled(quorum_queues_v4).

%%% Internal

messages_ready(#?STATE{messages = M,
                       returns = R}) ->
    lqueue:len(M) + lqueue:len(R).

messages_total(#?STATE{messages_total = Total,
                       dlx = DlxState}) ->
    {DlxTotal, _} = rabbit_fifo_dlx:stat(DlxState),
    Total + DlxTotal.

update_use({inactive, _, _, _} = CUInfo, inactive) ->
    CUInfo;
update_use({active, _, _} = CUInfo, active) ->
    CUInfo;
update_use({active, Since, Avg}, inactive) ->
    Now = erlang:monotonic_time(micro_seconds),
    {inactive, Now, Now - Since, Avg};
update_use({inactive, Since, Active, Avg},   active) ->
    Now = erlang:monotonic_time(micro_seconds),
    {active, Now, use_avg(Active, Now - Since, Avg)}.

capacity({active, Since, Avg}) ->
    use_avg(erlang:monotonic_time(micro_seconds) - Since, 0, Avg);
capacity({inactive, _, 1, 1.0}) ->
    1.0;
capacity({inactive, Since, Active, Avg}) ->
    use_avg(Active, erlang:monotonic_time(micro_seconds) - Since, Avg).

use_avg(0, 0, Avg) ->
    Avg;
use_avg(Active, Inactive, Avg) ->
    Time = Inactive + Active,
    moving_average(Time, ?USE_AVG_HALF_LIFE, Active / Time, Avg).

moving_average(_Time, _, Next, undefined) ->
    Next;
moving_average(Time, HalfLife, Next, Current) ->
    Weight = math:exp(Time * math:log(0.5) / HalfLife),
    Next * (1 - Weight) + Current * Weight.

num_checked_out(#?STATE{consumers = Cons}) ->
    maps:fold(fun (_, #consumer{checked_out = C}, Acc) ->
                      maps:size(C) + Acc
              end, 0, Cons).

cancel_consumer(Meta, ConsumerKey,
                #?STATE{cfg = #cfg{consumer_strategy = competing}} = State,
                Effects, Reason) ->
    cancel_consumer0(Meta, ConsumerKey, State, Effects, Reason);
cancel_consumer(Meta, ConsumerKey,
                #?STATE{cfg = #cfg{consumer_strategy = single_active},
                        waiting_consumers = []} = State,
                Effects, Reason) ->
    %% single active consumer on, no consumers are waiting
    cancel_consumer0(Meta, ConsumerKey, State, Effects, Reason);
cancel_consumer(Meta, ConsumerKey,
                #?STATE{consumers = Cons0,
                        cfg = #cfg{consumer_strategy = single_active},
                        waiting_consumers = Waiting0} = State0,
               Effects0, Reason) ->
    %% single active consumer on, consumers are waiting
    case Cons0 of
        #{ConsumerKey := #consumer{status = _}} ->
            % The active consumer is to be removed
            cancel_consumer0(Meta, ConsumerKey, State0,
                             Effects0, Reason);
        _ ->
            % The cancelled consumer is not active or cancelled
            % Just remove it from idle_consumers
            case lists:keyfind(ConsumerKey, 1, Waiting0) of
                {_, ?CONSUMER_TAG_PID(T, P)} ->
                    Waiting = lists:keydelete(ConsumerKey, 1, Waiting0),
                    Effects = cancel_consumer_effects({T, P}, State0, Effects0),
                    % A waiting consumer isn't supposed to have any checked out messages,
                    % so nothing special to do here
                    {State0#?STATE{waiting_consumers = Waiting}, Effects};
                _ ->
                    {State0, Effects0}
            end
    end.

consumer_update_active_effects(#?STATE{cfg = #cfg{resource = QName}},
                               #consumer{cfg = #consumer_cfg{pid = CPid,
                                                             tag = CTag,
                                                             meta = Meta}},
                               Active, ActivityStatus,
                               Effects) ->
    Ack = maps:get(ack, Meta, undefined),
    Prefetch = maps:get(prefetch, Meta, undefined),
    Args = maps:get(args, Meta, []),
    [{mod_call, rabbit_quorum_queue, update_consumer_handler,
      [QName, {CTag, CPid}, false, Ack, Prefetch, Active, ActivityStatus, Args]}
      | Effects].

cancel_consumer0(Meta, ConsumerKey,
                 #?STATE{consumers = C0} = S0, Effects0, Reason) ->
    case C0 of
        #{ConsumerKey := Consumer} ->
            {S, Effects2} = maybe_return_all(Meta, ConsumerKey, Consumer,
                                             S0, Effects0, Reason),

            %% The effects are emitted before the consumer is actually removed
            %% if the consumer has unacked messages. This is a bit weird but
            %% in line with what classic queues do (from an external point of
            %% view)
            Effects = cancel_consumer_effects(consumer_id(Consumer), S, Effects2),
            {S, Effects};
        _ ->
            %% already removed: do nothing
            {S0, Effects0}
    end.

activate_next_consumer({State, Effects}) ->
    activate_next_consumer(State, Effects).

activate_next_consumer(#?STATE{cfg = #cfg{consumer_strategy = competing}} = State0,
                       Effects0) ->
    {State0, Effects0};
activate_next_consumer(#?STATE{consumers = Cons,
                               waiting_consumers = Waiting0} = State0,
                       Effects0) ->
    %% invariant, the waiting list always need to be sorted by consumers that are
    %% up - then by priority
    NextConsumer =
        case Waiting0 of
            [{_, #consumer{status = up}} = Next | _] ->
                Next;
            _ ->
                undefined
        end,

    case {active_consumer(Cons), NextConsumer} of
        {undefined, {NextCKey, #consumer{cfg = NextCCfg} = NextC}} ->
            Remaining = tl(Waiting0),
            %% TODO: can this happen?
            Consumer = case maps:get(NextCKey, Cons, undefined) of
                           undefined ->
                               NextC;
                           Existing ->
                               %% there was an exisiting non-active consumer
                               %% just update the existing cancelled consumer
                               %% with the new config
                               Existing#consumer{cfg =  NextCCfg}
                       end,
            #?STATE{service_queue = ServiceQueue} = State0,
            ServiceQueue1 = maybe_queue_consumer(NextCKey,
                                                 Consumer,
                                                 ServiceQueue),
            State = State0#?STATE{consumers = Cons#{NextCKey => Consumer},
                                  service_queue = ServiceQueue1,
                                  waiting_consumers = Remaining},
            Effects = consumer_update_active_effects(State, Consumer,
                                                     true, single_active,
                                                     Effects0),
            {State, Effects};
        {{ActiveCKey, ?CONSUMER_PRIORITY(ActivePriority) =
                      #consumer{checked_out = ActiveChecked} = Active},
         {NextCKey, ?CONSUMER_PRIORITY(WaitingPriority) = Consumer}}
          when WaitingPriority > ActivePriority andalso
               map_size(ActiveChecked) == 0 ->
            Remaining = tl(Waiting0),
            %% the next consumer is a higher priority and should take over
            %% and this consumer does not have any pending messages
            #?STATE{service_queue = ServiceQueue} = State0,
            ServiceQueue1 = maybe_queue_consumer(NextCKey,
                                                 Consumer,
                                                 ServiceQueue),
            State = State0#?STATE{consumers = maps:remove(ActiveCKey,
                                                          Cons#{NextCKey => Consumer}),
                                  service_queue = ServiceQueue1,
                                  waiting_consumers =
                                      add_waiting({ActiveCKey, Active}, Remaining)},
            Effects = consumer_update_active_effects(State, Consumer,
                                                     true, single_active,
                                                     Effects0),
            {State, Effects};
        {{ActiveCKey, ?CONSUMER_PRIORITY(ActivePriority) = Active},
         {_NextCKey, ?CONSUMER_PRIORITY(WaitingPriority)}}
          when WaitingPriority > ActivePriority ->
            %% A higher priority consumer has attached but the current one has
            %% pending messages
            {State0#?STATE{consumers =
                           Cons#{ActiveCKey => Active#consumer{status = fading}}},
             Effects0};
        _ ->
            %% no activation
            {State0, Effects0}
    end.

active_consumer({CKey, #consumer{status = Status} = Consumer, _I})
  when Status == up orelse Status == fading ->
    {CKey, Consumer};
active_consumer({_CKey, #consumer{status = _}, I}) ->
    active_consumer(maps:next(I));
active_consumer(none) ->
    undefined;
active_consumer(M) when is_map(M) ->
    I = maps:iterator(M),
    active_consumer(maps:next(I)).

is_active(_ConsumerKey, #?STATE{cfg = #cfg{consumer_strategy = competing}}) ->
    %% all competing consumers are potentially active
    true;
is_active(ConsumerKey, #?STATE{cfg = #cfg{consumer_strategy = single_active},
                               consumers = Consumers}) ->
    ConsumerKey == active_consumer(Consumers).

maybe_return_all(#{system_time := Ts} = Meta, ConsumerKey,
                 #consumer{cfg = CCfg} = Consumer, S0,
                 Effects0, Reason) ->
    case Reason of
        cancel ->
            {update_or_remove_con(
               Meta, ConsumerKey,
               Consumer#consumer{cfg = CCfg#consumer_cfg{lifetime = once},
                                 credit = 0,
                                 status = cancelled},
               S0), Effects0};
        _ ->
            {S1, Effects1} = return_all(Meta, S0, Effects0, ConsumerKey, Consumer),
            {S1#?STATE{consumers = maps:remove(ConsumerKey, S1#?STATE.consumers),
                       last_active = Ts},
             Effects1}
    end.

apply_enqueue(#{index := RaftIdx,
                system_time := Ts} = Meta, From, Seq, RawMsg, State0) ->
    case maybe_enqueue(RaftIdx, Ts, From, Seq, RawMsg, [], State0) of
        {ok, State1, Effects1} ->
            {State, ok, Effects} = checkout(Meta, State0, State1, Effects1),
            {maybe_store_release_cursor(RaftIdx, State), ok, Effects};
        {out_of_sequence, State, Effects} ->
            {State, not_enqueued, Effects};
        {duplicate, State, Effects} ->
            {State, ok, Effects}
    end.

decr_total(#?STATE{messages_total = Tot} = State) ->
    State#?STATE{messages_total = Tot - 1}.

drop_head(#?STATE{ra_indexes = Indexes0} = State0, Effects) ->
    case take_next_msg(State0) of
        {?MSG(Idx, Header) = Msg, State1} ->
            Indexes = rabbit_fifo_index:delete(Idx, Indexes0),
            State2 = State1#?STATE{ra_indexes = Indexes},
            State3 = decr_total(add_bytes_drop(Header, State2)),
            #?STATE{cfg = #cfg{dead_letter_handler = DLH},
                    dlx = DlxState} = State = State3,
            {_, DlxEffects} = rabbit_fifo_dlx:discard([Msg], maxlen, DLH, DlxState),
            {State, DlxEffects ++ Effects};
        empty ->
            {State0, Effects}
    end.

maybe_set_msg_ttl(#basic_message{content = #content{properties = none}},
                  RaCmdTs, Header,
                  #?STATE{cfg = #cfg{msg_ttl = PerQueueMsgTTL}}) ->
    update_expiry_header(RaCmdTs, PerQueueMsgTTL, Header);
maybe_set_msg_ttl(#basic_message{content = #content{properties = Props}},
                  RaCmdTs, Header,
                  #?STATE{cfg = #cfg{msg_ttl = PerQueueMsgTTL}}) ->
    %% rabbit_quorum_queue will leave the properties decoded if and only if
    %% per message message TTL is set.
    %% We already check in the channel that expiration must be valid.
    {ok, PerMsgMsgTTL} = rabbit_basic:parse_expiration(Props),
    TTL = min(PerMsgMsgTTL, PerQueueMsgTTL),
    update_expiry_header(RaCmdTs, TTL, Header);
maybe_set_msg_ttl(Msg, RaCmdTs, Header,
                  #?STATE{cfg = #cfg{msg_ttl = MsgTTL}}) ->
    case mc:is(Msg) of
        true ->
            TTL = min(MsgTTL, mc:ttl(Msg)),
            update_expiry_header(RaCmdTs, TTL, Header);
        false ->
            Header
    end.

update_expiry_header(_, undefined, Header) ->
    Header;
update_expiry_header(RaCmdTs, 0, Header) ->
    %% We do not comply exactly with the "TTL=0 models AMQP immediate flag" semantics
    %% as done for classic queues where the message is discarded if it cannot be
    %% consumed immediately.
    %% Instead, we discard the message if it cannot be consumed within the same millisecond
    %% when it got enqueued. This behaviour should be good enough.
    update_expiry_header(RaCmdTs + 1, Header);
update_expiry_header(RaCmdTs, TTL, Header) ->
    update_expiry_header(RaCmdTs + TTL, Header).

update_expiry_header(ExpiryTs, Header) ->
    update_header(expiry, fun(Ts) -> Ts end, ExpiryTs, Header).

maybe_store_release_cursor(RaftIdx,
                           #?STATE{cfg = #cfg{release_cursor_interval =
                                              {Base, C}} = Cfg,
                                   enqueue_count = EC,
                                   release_cursors = Cursors0} = State0)
  when EC >= C ->
    case messages_total(State0) of
        0 ->
            %% message must have been immediately dropped
            State0#?STATE{enqueue_count = 0};
        Total ->
            Interval = case Base of
                           0 -> 0;
                           _ ->
                               min(max(Total, Base), ?RELEASE_CURSOR_EVERY_MAX)
                       end,
            State = State0#?STATE{cfg = Cfg#cfg{release_cursor_interval =
                                                 {Base, Interval}}},
            Dehydrated = dehydrate_state(State),
            Cursor = {release_cursor, RaftIdx, Dehydrated},
            Cursors = lqueue:in(Cursor, Cursors0),
            State#?STATE{enqueue_count = 0,
                         release_cursors = Cursors}
    end;
maybe_store_release_cursor(_RaftIdx, State) ->
    State.

maybe_enqueue(RaftIdx, Ts, undefined, undefined, RawMsg, Effects,
              #?STATE{msg_bytes_enqueue = Enqueue,
                      enqueue_count = EnqCount,
                      messages = Messages,
                      messages_total = Total} = State0) ->
    % direct enqueue without tracking
    Size = message_size(RawMsg),
    Header = maybe_set_msg_ttl(RawMsg, Ts, Size, State0),
    Msg = ?MSG(RaftIdx, Header),
    State = State0#?STATE{msg_bytes_enqueue = Enqueue + Size,
                          enqueue_count = EnqCount + 1,
                          messages_total = Total + 1,
                          messages = lqueue:in(Msg, Messages)
                         },
    {ok, State, Effects};
maybe_enqueue(RaftIdx, Ts, From, MsgSeqNo, RawMsg, Effects0,
              #?STATE{msg_bytes_enqueue = Enqueue,
                      enqueue_count = EnqCount,
                      enqueuers = Enqueuers0,
                      messages = Messages,
                      messages_total = Total} = State0) ->

    case maps:get(From, Enqueuers0, undefined) of
        undefined ->
            State1 = State0#?STATE{enqueuers = Enqueuers0#{From => #enqueuer{}}},
            {Res, State, Effects} = maybe_enqueue(RaftIdx, Ts, From, MsgSeqNo,
                                                  RawMsg, Effects0, State1),
            {Res, State, [{monitor, process, From} | Effects]};
        #enqueuer{next_seqno = MsgSeqNo} = Enq0 ->
            % it is the next expected seqno
            Size = message_size(RawMsg),
            Header = maybe_set_msg_ttl(RawMsg, Ts, Size, State0),
            Msg = ?MSG(RaftIdx, Header),
            Enq = Enq0#enqueuer{next_seqno = MsgSeqNo + 1},
            MsgCache = case can_immediately_deliver(State0) of
                           true ->
                               {RaftIdx, RawMsg};
                           false ->
                               undefined
                       end,
            State = State0#?STATE{msg_bytes_enqueue = Enqueue + Size,
                                  enqueue_count = EnqCount + 1,
                                  messages_total = Total + 1,
                                  messages = lqueue:in(Msg, Messages),
                                  enqueuers = Enqueuers0#{From => Enq},
                                  msg_cache = MsgCache
                                 },
            {ok, State, Effects0};
        #enqueuer{next_seqno = Next}
          when MsgSeqNo > Next ->
            %% TODO: when can this happen?
            {out_of_sequence, State0, Effects0};
        #enqueuer{next_seqno = Next} when MsgSeqNo =< Next ->
            % duplicate delivery
            {duplicate, State0, Effects0}
    end.

return(#{index := IncomingRaftIdx} = Meta,
       ConsumerKey, Returned, Effects0, State0) ->
    {State1, Effects1} = maps:fold(
                           fun(MsgId, ?C_MSG(_At, Msg), {S0, E0}) ->
                                   return_one(Meta, MsgId, Msg,
                                              S0, E0, ConsumerKey)
                           end, {State0, Effects0}, Returned),
    State2 = case State1#?STATE.consumers of
                 #{ConsumerKey := Con} ->
                     update_or_remove_con(Meta, ConsumerKey,
                                          Con, State1);
                 _ ->
                     State1
             end,
    {State, ok, Effects} = checkout(Meta, State0, State2, Effects1),
    update_smallest_raft_index(IncomingRaftIdx, State, Effects).

% used to process messages that are finished
complete(Meta, ConsumerKey, MsgIds,
         #consumer{checked_out = Checked0} = Con0,
         #?STATE{ra_indexes = Indexes0,
                 msg_bytes_checkout = BytesCheckout,
                 messages_total = Tot} = State0) ->
    {SettledSize, Checked, Indexes}
        = lists:foldl(
            fun (MsgId, {S0, Ch0, Idxs}) ->
                    case maps:take(MsgId, Ch0) of
                        {?C_MSG(_, Idx, Hdr), Ch} ->
                            S = get_header(size, Hdr) + S0,
                            {S, Ch, rabbit_fifo_index:delete(Idx, Idxs)};
                        error ->
                            {S0, Ch0, Idxs}
                    end
            end, {0, Checked0, Indexes0}, MsgIds),
    Len = map_size(Checked0) - map_size(Checked),
    Con = Con0#consumer{checked_out = Checked,
                        credit = increase_credit(Con0, Len)},
    State1 = update_or_remove_con(Meta, ConsumerKey, Con, State0),
    State1#?STATE{ra_indexes = Indexes,
                  msg_bytes_checkout = BytesCheckout - SettledSize,
                  messages_total = Tot - Len}.

increase_credit(#consumer{cfg = #consumer_cfg{lifetime = once},
                          credit = Credit}, _) ->
    %% once consumers cannot increment credit
    Credit;
increase_credit(#consumer{cfg = #consumer_cfg{lifetime = auto,
                                              credit_mode = credited},
                          credit = Credit}, _) ->
    %% credit_mode: `credited' also doesn't automatically increment credit
    Credit;
increase_credit(#consumer{cfg = #consumer_cfg{lifetime = auto,
                                              credit_mode = {credited, _}},
                          credit = Credit}, _) ->
    %% credit_mode: `credited' also doesn't automatically increment credit
    Credit;
increase_credit(#consumer{cfg = #consumer_cfg{credit_mode =
                                              {simple_prefetch, MaxCredit}},
                          credit = Current}, Credit)
  when MaxCredit > 0 ->
    min(MaxCredit, Current + Credit);
increase_credit(#consumer{credit = Current}, Credit) ->
    Current + Credit.

complete_and_checkout(#{index := IncomingRaftIdx} = Meta, MsgIds, ConsumerKey,
                      #consumer{} = Con0,
                      Effects0, State0) ->
    State1 = complete(Meta, ConsumerKey, MsgIds, Con0, State0),
    %% a completion could have removed the active/fading consumer
    {State2, Effects1} = activate_next_consumer(State1, Effects0),
    {State, ok, Effects} = checkout(Meta, State0, State2, Effects1),
    update_smallest_raft_index(IncomingRaftIdx, State, Effects).

cancel_consumer_effects(ConsumerId,
                        #?STATE{cfg = #cfg{resource = QName}},
                        Effects) when is_tuple(ConsumerId) ->
    [{mod_call, rabbit_quorum_queue,
      cancel_consumer_handler, [QName, ConsumerId]} | Effects].

update_smallest_raft_index(Idx, State, Effects) ->
    update_smallest_raft_index(Idx, ok, State, Effects).

update_smallest_raft_index(IncomingRaftIdx, Reply,
                           #?STATE{cfg = Cfg,
                                   release_cursors = Cursors0} = State0,
                           Effects) ->
    Total = messages_total(State0),
    %% TODO: optimise
    case smallest_raft_index(State0) of
        undefined when Total == 0 ->
            % there are no messages on queue anymore and no pending enqueues
            % we can forward release_cursor all the way until
            % the last received command, hooray
            %% reset the release cursor interval
            #cfg{release_cursor_interval = {Base, _}} = Cfg,
            RCI = {Base, Base},
            State = State0#?STATE{cfg = Cfg#cfg{release_cursor_interval = RCI},
                                  release_cursors = lqueue:new(),
                                  enqueue_count = 0},
            {State, Reply, Effects ++ [{release_cursor, IncomingRaftIdx, State}]};
        undefined ->
            {State0, Reply, Effects};
        Smallest when is_integer(Smallest) ->
            case find_next_cursor(Smallest, Cursors0) of
                empty ->
                    {State0, Reply, Effects};
                {Cursor, Cursors} ->
                    %% we can emit a release cursor when we've passed the smallest
                    %% release cursor available.
                    {State0#?STATE{release_cursors = Cursors}, Reply,
                     Effects ++ [Cursor]}
            end
    end.

find_next_cursor(Idx, Cursors) ->
    find_next_cursor(Idx, Cursors, empty).

find_next_cursor(Smallest, Cursors0, Potential) ->
    case lqueue:out(Cursors0) of
        {{value, {_, Idx, _} = Cursor}, Cursors} when Idx < Smallest ->
            %% we found one but it may not be the largest one
            find_next_cursor(Smallest, Cursors, Cursor);
        _ when Potential == empty ->
            empty;
        _ ->
            {Potential, Cursors0}
    end.

update_msg_header(Key, Fun, Def, ?MSG(Idx, Header)) ->
    ?MSG(Idx, update_header(Key, Fun, Def, Header)).

update_header(expiry, _, Expiry, Size)
  when is_integer(Size) ->
    ?TUPLE(Size, Expiry);
update_header(Key, UpdateFun, Default, Size)
  when is_integer(Size) ->
    update_header(Key, UpdateFun, Default, #{size => Size});
update_header(Key, UpdateFun, Default, ?TUPLE(Size, Expiry))
  when is_integer(Size), is_integer(Expiry) ->
    update_header(Key, UpdateFun, Default, #{size => Size,
                                             expiry => Expiry});
update_header(Key, UpdateFun, Default, Header)
  when is_map(Header), is_map_key(size, Header) ->
    maps:update_with(Key, UpdateFun, Default, Header).

get_msg_header(?MSG(_Idx, Header)) ->
    Header.

get_header(size, Size)
  when is_integer(Size) ->
    Size;
get_header(_Key, Size)
  when is_integer(Size) ->
    undefined;
get_header(size, ?TUPLE(Size, Expiry))
  when is_integer(Size), is_integer(Expiry) ->
    Size;
get_header(expiry, ?TUPLE(Size, Expiry))
  when is_integer(Size), is_integer(Expiry) ->
    Expiry;
get_header(_Key, ?TUPLE(Size, Expiry))
  when is_integer(Size), is_integer(Expiry) ->
    undefined;
get_header(Key, Header)
  when is_map(Header) andalso is_map_key(size, Header) ->
    maps:get(Key, Header, undefined).

return_one(Meta, MsgId, ?MSG(_, _) = Msg0,
           #?STATE{returns = Returns,
                   consumers = Consumers,
                   dlx = DlxState0,
                   cfg = #cfg{delivery_limit = DeliveryLimit,
                              dead_letter_handler = DLH}} = State0,
           Effects0, ConsumerKey) ->
    #consumer{checked_out = Checked0} = Con0 = maps:get(ConsumerKey, Consumers),
    Msg = update_msg_header(delivery_count, fun incr/1, 1, Msg0),
    Header = get_msg_header(Msg),
    case get_header(delivery_count, Header) of
        DeliveryCount when DeliveryCount > DeliveryLimit ->
            {DlxState, DlxEffects} =
                rabbit_fifo_dlx:discard([Msg], delivery_limit, DLH, DlxState0),
            State1 = State0#?STATE{dlx = DlxState},
            State = complete(Meta, ConsumerKey, [MsgId], Con0, State1),
            {State, DlxEffects ++ Effects0};
        _ ->
            Checked = maps:remove(MsgId, Checked0),
            Con = Con0#consumer{checked_out = Checked,
                                credit = increase_credit(Con0, 1)},
            {add_bytes_return(
               Header,
               State0#?STATE{consumers = Consumers#{ConsumerKey => Con},
                             returns = lqueue:in(Msg, Returns)}),
             Effects0}
    end.

return_all(Meta, #?STATE{consumers = Cons} = State0, Effects0, ConsumerKey,
           #consumer{checked_out = Checked} = Con) ->
    State = State0#?STATE{consumers = Cons#{ConsumerKey => Con}},
    lists:foldl(fun ({MsgId, ?C_MSG(_At, Msg)}, {S, E}) ->
                        return_one(Meta, MsgId, Msg, S, E, ConsumerKey)
                end, {State, Effects0}, lists:sort(maps:to_list(Checked))).

checkout(Meta, OldState, State0, Effects0) ->
    checkout(Meta, OldState, State0, Effects0, ok).

checkout(#{index := Index} = Meta,
         #?STATE{} = OldState,
         State0, Effects0, Reply) ->
    {#?STATE{cfg = #cfg{dead_letter_handler = DLH},
             dlx = DlxState0} = State1, ExpiredMsg, Effects1} =
        checkout0(Meta, checkout_one(Meta, false, State0, Effects0), #{}),
    {DlxState, DlxDeliveryEffects} = rabbit_fifo_dlx:checkout(DLH, DlxState0),
    %% TODO: only update dlx state if it has changed?
    %% by this time the cache should be used
    State2 = State1#?STATE{msg_cache = undefined,
                           dlx = DlxState},
    Effects2 = DlxDeliveryEffects ++ Effects1,
    case evaluate_limit(Index, false, OldState, State2, Effects2) of
        {State, false, Effects} when ExpiredMsg == false ->
            {State, Reply, Effects};
        {State, _, Effects} ->
            update_smallest_raft_index(Index, Reply, State, Effects)
    end.

checkout0(Meta, {success, ConsumerKey, MsgId,
                 ?MSG(_, _) = Msg, ExpiredMsg, State, Effects},
          SendAcc0) ->
    DelMsg = {MsgId, Msg},
    SendAcc = case maps:get(ConsumerKey, SendAcc0, undefined) of
                  undefined ->
                      SendAcc0#{ConsumerKey => [DelMsg]};
                  LogMsgs ->
                      SendAcc0#{ConsumerKey => [DelMsg | LogMsgs]}
              end,
    checkout0(Meta, checkout_one(Meta, ExpiredMsg, State, Effects), SendAcc);
checkout0(_Meta, {_Activity, ExpiredMsg, State0, Effects0}, SendAcc) ->
    Effects = add_delivery_effects(Effects0, SendAcc, State0),
    {State0, ExpiredMsg, lists:reverse(Effects)}.

evaluate_limit(_Index, Result, _BeforeState,
               #?STATE{cfg = #cfg{max_length = undefined,
                                  max_bytes = undefined}} = State,
               Effects) ->
    {State, Result, Effects};
evaluate_limit(Index, Result, BeforeState,
               #?STATE{cfg = #cfg{overflow_strategy = Strategy},
                       enqueuers = Enqs0} = State0,
               Effects0) ->
    case is_over_limit(State0) of
        true when Strategy == drop_head ->
            {State, Effects} = drop_head(State0, Effects0),
            evaluate_limit(Index, true, BeforeState, State, Effects);
        true when Strategy == reject_publish ->
            %% generate send_msg effect for each enqueuer to let them know
            %% they need to block
            {Enqs, Effects} =
                maps:fold(
                  fun (P, #enqueuer{blocked = undefined} = E0, {Enqs, Acc}) ->
                          E = E0#enqueuer{blocked = Index},
                          {Enqs#{P => E},
                           [{send_msg, P, {queue_status, reject_publish},
                             [ra_event]} | Acc]};
                      (_P, _E, Acc) ->
                          Acc
                  end, {Enqs0, Effects0}, Enqs0),
            {State0#?STATE{enqueuers = Enqs}, Result, Effects};
        false when Strategy == reject_publish ->
            %% TODO: optimise as this case gets called for every command
            %% pretty much
            Before = is_below_soft_limit(BeforeState),
            case {Before, is_below_soft_limit(State0)} of
                {false, true} ->
                    %% we have moved below the lower limit
                    {Enqs, Effects} =
                        maps:fold(
                          fun (P, #enqueuer{} = E0, {Enqs, Acc})  ->
                                  E = E0#enqueuer{blocked = undefined},
                                  {Enqs#{P => E},
                                   [{send_msg, P, {queue_status, go}, [ra_event]}
                                    | Acc]};
                              (_P, _E, Acc) ->
                                  Acc
                          end, {Enqs0, Effects0}, Enqs0),
                    {State0#?STATE{enqueuers = Enqs}, Result, Effects};
                _ ->
                    {State0, Result, Effects0}
            end;
        false ->
            {State0, Result, Effects0}
    end.


%% [6,5,4,3,2,1] -> [[1,2],[3,4],[5,6]]
chunk_disk_msgs([], _Bytes, [[] | Chunks]) ->
    Chunks;
chunk_disk_msgs([], _Bytes, Chunks) ->
    Chunks;
chunk_disk_msgs([{_MsgId, ?MSG(_RaftIdx, Header)} = Msg | Rem],
                Bytes, Chunks)
  when Bytes >= ?DELIVERY_CHUNK_LIMIT_B ->
    Size = get_header(size, Header),
    chunk_disk_msgs(Rem, Size, [[Msg] | Chunks]);
chunk_disk_msgs([{_MsgId, ?MSG(_RaftIdx, Header)} = Msg | Rem], Bytes,
                [CurChunk | Chunks]) ->
    Size = get_header(size, Header),
    chunk_disk_msgs(Rem, Bytes + Size, [[Msg | CurChunk] | Chunks]).

add_delivery_effects(Effects0, AccMap, _State)
  when map_size(AccMap) == 0 ->
    %% does this ever happen?
    Effects0;
add_delivery_effects(Effects0, AccMap, State) ->
     maps:fold(fun (C, DiskMsgs, Efs)
                     when is_list(DiskMsgs) ->
                       lists:foldl(
                         fun (Msgs, E) ->
                                 [delivery_effect(C, Msgs, State) | E]
                         end, Efs, chunk_disk_msgs(DiskMsgs, 0, [[]]))
               end, Effects0, AccMap).

take_next_msg(#?STATE{returns = Returns0,
                      messages = Messages0,
                      ra_indexes = Indexes0
                     } = State) ->
    case lqueue:out(Returns0) of
        {{value, NextMsg}, Returns} ->
            {NextMsg, State#?STATE{returns = Returns}};
        {empty, _} ->
            case lqueue:out(Messages0) of
                {empty, _} ->
                    empty;
                {{value, ?MSG(RaftIdx, _) = Msg}, Messages} ->
                    %% add index here
                    Indexes = rabbit_fifo_index:append(RaftIdx, Indexes0),
                    {Msg, State#?STATE{messages = Messages,
                                       ra_indexes = Indexes}}
            end
    end.

get_next_msg(#?STATE{returns = Returns0,
                     messages = Messages0}) ->
    case lqueue:get(Returns0, empty) of
        empty ->
            lqueue:get(Messages0, empty);
        Msg ->
            Msg
    end.

delivery_effect(ConsumerKey, [{MsgId, ?MSG(Idx,  Header)}],
                #?STATE{msg_cache = {Idx, RawMsg}} = State) ->
    {CTag, CPid} = consumer_id(ConsumerKey, State),
    {send_msg, CPid, {delivery, CTag, [{MsgId, {Header, RawMsg}}]},
     ?DELIVERY_SEND_MSG_OPTS};
delivery_effect(ConsumerKey, Msgs, State) ->
    {CTag, CPid} = consumer_id(ConsumerKey, State),
    RaftIdxs = lists:foldr(fun ({_, ?MSG(I, _)}, Acc) ->
                                   [I | Acc]
                           end, [], Msgs),
    {log, RaftIdxs,
     fun(Log) ->
             DelMsgs = lists:zipwith(
                         fun (Cmd, {MsgId, ?MSG(_Idx,  Header)}) ->
                                 {MsgId, {Header, get_msg(Cmd)}}
                         end, Log, Msgs),
             [{send_msg, CPid, {delivery, CTag, DelMsgs},
               ?DELIVERY_SEND_MSG_OPTS}]
     end,
     {local, node(CPid)}}.

reply_log_effect(RaftIdx, MsgId, Header, Ready, From) ->
    {log, [RaftIdx],
     fun ([Cmd]) ->
             [{reply, From, {wrap_reply,
                             {dequeue, {MsgId, {Header, get_msg(Cmd)}}, Ready}}}]
     end}.

checkout_one(#{system_time := Ts} = Meta, ExpiredMsg0, InitState0, Effects0) ->
    %% Before checking out any messsage to any consumer,
    %% first remove all expired messages from the head of the queue.
    {ExpiredMsg, #?STATE{service_queue = SQ0,
                         messages = Messages0,
                         msg_bytes_checkout = BytesCheckout,
                         msg_bytes_enqueue = BytesEnqueue,
                         consumers = Cons0} = InitState, Effects1} =
        expire_msgs(Ts, ExpiredMsg0, InitState0, Effects0),

    case priority_queue:out(SQ0) of
        {{value, ConsumerKey}, SQ1}
          when is_map_key(ConsumerKey, Cons0) ->
            case take_next_msg(InitState) of
                {Msg, State0} ->
                    %% there are consumers waiting to be serviced
                    %% process consumer checkout
                    case maps:get(ConsumerKey, Cons0) of
                        #consumer{credit = Credit,
                                  status = Status}
                          when Credit =:= 0 orelse
                               Status =/= up ->
                            %% not an active consumer but still in the consumers
                            %% map - this can happen when draining
                            %% or when higher priority single active consumers
                            %% take over, recurse without consumer in service
                            %% queue
                            checkout_one(Meta, ExpiredMsg,
                                         InitState#?STATE{service_queue = SQ1},
                                         Effects1);
                        #consumer{checked_out = Checked0,
                                  next_msg_id = Next,
                                  credit = Credit,
                                  delivery_count = DelCnt0,
                                  cfg = Cfg} = Con0 ->
                            Checked = maps:put(Next, ?C_MSG(Ts, Msg), Checked0),
                            DelCnt = case credit_api_v2(Cfg) of
                                         true -> add(DelCnt0, 1);
                                         false -> DelCnt0 + 1
                                     end,
                            Con = Con0#consumer{checked_out = Checked,
                                                next_msg_id = Next + 1,
                                                credit = Credit - 1,
                                                delivery_count = DelCnt},
                            Size = get_header(size, get_msg_header(Msg)),
                            State1 =
                                State0#?STATE{service_queue = SQ1,
                                              msg_bytes_checkout = BytesCheckout + Size,
                                              msg_bytes_enqueue = BytesEnqueue - Size},
                            State = update_or_remove_con(
                                       Meta, ConsumerKey, Con, State1),
                            {success, ConsumerKey, Next, Msg, ExpiredMsg,
                             State, Effects1}
                    end;
                empty ->
                    {nochange, ExpiredMsg, InitState, Effects1}
            end;
        {{value, _ConsumerId}, SQ1} ->
            %% consumer was not active but was queued, recurse
            checkout_one(Meta, ExpiredMsg,
                         InitState#?STATE{service_queue = SQ1}, Effects1);
        {empty, _} ->
            case lqueue:len(Messages0) of
                0 ->
                    {nochange, ExpiredMsg, InitState, Effects1};
                _ ->
                    {inactive, ExpiredMsg, InitState, Effects1}
            end
    end.

%% dequeue all expired messages
expire_msgs(RaCmdTs, Result, State, Effects) ->
    %% In the normal case, there are no expired messages.
    %% Therefore, first lqueue:get/2 to check whether we need to lqueue:out/1
    %% because the latter can be much slower than the former.
    case get_next_msg(State) of
        ?MSG(_, ?TUPLE(Size, Expiry))
          when is_integer(Size), is_integer(Expiry), RaCmdTs >= Expiry ->
            expire(RaCmdTs, State, Effects);
        ?MSG(_, #{expiry := Expiry})
          when is_integer(Expiry), RaCmdTs >= Expiry ->
            expire(RaCmdTs, State, Effects);
        _ ->
            {Result, State, Effects}
    end.

expire(RaCmdTs, State0, Effects) ->
    {?MSG(Idx, Header) = Msg,
     #?STATE{cfg = #cfg{dead_letter_handler = DLH},
             dlx = DlxState0,
             ra_indexes = Indexes0,
             messages_total = Tot,
             msg_bytes_enqueue = MsgBytesEnqueue} = State1} =
        take_next_msg(State0),
    {DlxState, DlxEffects} = rabbit_fifo_dlx:discard([Msg], expired,
                                                     DLH, DlxState0),
    Indexes = rabbit_fifo_index:delete(Idx, Indexes0),
    State = State1#?STATE{dlx = DlxState,
                          ra_indexes = Indexes,
                          messages_total = Tot - 1,
                          msg_bytes_enqueue =
                              MsgBytesEnqueue - get_header(size, Header)},
    expire_msgs(RaCmdTs, true, State, DlxEffects ++ Effects).

timer_effect(RaCmdTs, State, Effects) ->
    T = case get_next_msg(State) of
            ?MSG(_, ?TUPLE(Size, Expiry))
              when is_integer(Size) andalso
                   is_integer(Expiry) ->
                %% Next message contains 'expiry' header.
                %% (Re)set timer so that message will be dropped or
                %% dead-lettered on time.
                max(0, Expiry - RaCmdTs);
            ?MSG(_, #{expiry := Expiry})
              when is_integer(Expiry) ->
                max(0, Expiry - RaCmdTs);
            _ ->
                %% Next message does not contain 'expiry' header.
                %% Therefore, do not set timer or cancel timer if it was set.
                infinity
        end,
    [{timer, expire_msgs, T} | Effects].

update_or_remove_con(Meta, ConsumerKey,
                     #consumer{cfg = #consumer_cfg{lifetime = once},
                               checked_out = Checked,
                               credit = 0} = Con,
                     #?STATE{consumers = Cons} = State) ->
    case map_size(Checked) of
        0 ->
            #{system_time := Ts} = Meta,
            % we're done with this consumer
            State#?STATE{consumers = maps:remove(ConsumerKey, Cons),
                         last_active = Ts};
        _ ->
            % there are unsettled items so need to keep around
            State#?STATE{consumers = maps:put(ConsumerKey, Con, Cons)}
    end;
update_or_remove_con(_Meta, ConsumerKey,
                     #consumer{status = fading,
                               checked_out = Checked} = Con0,
                     #?STATE{consumers = Cons,
                             waiting_consumers = Waiting} = State)
  when map_size(Checked) == 0 ->
    Con = Con0#consumer{status = up},
    State#?STATE{consumers = maps:remove(ConsumerKey, Cons),
                 waiting_consumers = add_waiting({ConsumerKey, Con}, Waiting)};
update_or_remove_con(_Meta, ConsumerKey,
                     #consumer{} = Con,
                     #?STATE{consumers = Cons,
                             service_queue = ServiceQueue} = State) ->
    State#?STATE{consumers = maps:put(ConsumerKey, Con, Cons),
                 service_queue = maybe_queue_consumer(ConsumerKey, Con,
                                                      ServiceQueue)}.

maybe_queue_consumer(Key, #consumer{credit = Credit,
                                    status = up,
                                    cfg = #consumer_cfg{priority = P}},
                     ServiceQueue)
  when Credit > 0 ->
    % TODO: queue:member could surely be quite expensive, however the practical
    % number of unique consumers may not be large enough for it to matter
    case priority_queue:member(Key, ServiceQueue) of
        true ->
            ServiceQueue;
        false ->
            priority_queue:in(Key, P, ServiceQueue)
    end;
maybe_queue_consumer(_Key, _Consumer, ServiceQueue) ->
    ServiceQueue.

update_consumer(Meta, ConsumerKey, {Tag, Pid}, ConsumerMeta,
                {Life, Mode} = Spec, Priority,
                #?STATE{cfg = #cfg{consumer_strategy = competing},
                        consumers = Cons0} = State0) ->
    Consumer = case Cons0 of
                   #{ConsumerKey := #consumer{} = Consumer0} ->
                       merge_consumer(Meta, Consumer0, ConsumerMeta,
                                      Spec, Priority);
                   _ ->
                       Credit = included_credit(Mode),
                       DeliveryCount = initial_delivery_count(Mode),
                       #consumer{cfg = #consumer_cfg{tag = Tag,
                                                     pid = Pid,
                                                     lifetime = Life,
                                                     meta = ConsumerMeta,
                                                     priority = Priority,
                                                     credit_mode = Mode},
                                 credit = Credit,
                                 delivery_count = DeliveryCount}
               end,
    {Consumer, update_or_remove_con(Meta, ConsumerKey, Consumer, State0)};
update_consumer(Meta, ConsumerKey, {Tag, Pid}, ConsumerMeta,
                {Life, Mode} = Spec, Priority,
                #?STATE{cfg = #cfg{consumer_strategy = single_active},
                        consumers = Cons0,
                        waiting_consumers = Waiting,
                        service_queue = _ServiceQueue0} = State0) ->
    %% if it is the current active consumer, just update
    %% if it is a cancelled active consumer, add to waiting unless it is the only
    %% one, then merge
    case active_consumer(Cons0) of
        {ConsumerKey, #consumer{status = up} = Consumer0} ->
            Consumer = merge_consumer(Meta, Consumer0, ConsumerMeta,
                                      Spec, Priority),
            {Consumer, update_or_remove_con(Meta, ConsumerKey, Consumer, State0)};
        undefined when is_map_key(ConsumerKey, Cons0) ->
            %% there is no active consumer and the current consumer is in the
            %% consumers map and thus must be cancelled, in this case we can just
            %% merge and effectively make this the current active one
            Consumer0 = maps:get(ConsumerKey, Cons0),
            Consumer = merge_consumer(Meta, Consumer0, ConsumerMeta,
                                      Spec, Priority),
            {Consumer, update_or_remove_con(Meta, ConsumerKey, Consumer, State0)};
        _ ->
            %% add as a new waiting consumer
            Credit = included_credit(Mode),
            DeliveryCount = initial_delivery_count(Mode),
            Consumer = #consumer{cfg = #consumer_cfg{tag = Tag,
                                                     pid = Pid,
                                                     lifetime = Life,
                                                     meta = ConsumerMeta,
                                                     priority = Priority,
                                                     credit_mode = Mode},
                                 credit = Credit,
                                 delivery_count = DeliveryCount},
            {Consumer,
             State0#?STATE{waiting_consumers =
                           add_waiting({ConsumerKey, Consumer}, Waiting)}}
    end.

add_waiting({Key, _} = New, Waiting) ->
    sort_waiting(lists:keystore(Key, 1, Waiting, New)).

sort_waiting(Waiting) ->
    lists:sort(fun
                   ({_, ?CONSUMER_PRIORITY(P1) = #consumer{status = up}},
                    {_, ?CONSUMER_PRIORITY(P2) = #consumer{status = up}})
                     when P1 =/= P2 ->
                       P2 =< P1;
                   ({C1, #consumer{status = up,
                                   credit = Cr1}},
                    {C2, #consumer{status = up,
                                   credit = Cr2}}) ->
                       %% both are up, priority the same
                       if Cr1 == Cr2 ->
                              %% same credit
                              %% sort by key, first attached priority
                              C1 =< C2;
                          true ->
                              %% else sort by credit
                              Cr2 =< Cr1
                       end;
                   (_, {_, #consumer{status = Status}}) ->
                       %% not up
                       Status /= up
               end, Waiting).


merge_consumer(_Meta, #consumer{cfg = CCfg, checked_out = Checked} = Consumer,
               ConsumerMeta, {Life, Mode}, Priority) ->
    Credit = included_credit(Mode),
    NumChecked = map_size(Checked),
    NewCredit = max(0, Credit - NumChecked),
    Consumer#consumer{cfg = CCfg#consumer_cfg{priority = Priority,
                                              meta = ConsumerMeta,
                                              credit_mode = Mode,
                                              lifetime = Life},
                      status = up,
                      credit = NewCredit}.

included_credit({simple_prefetch, Credit}) ->
    Credit;
included_credit({credited, _}) ->
    0;
included_credit(credited) ->
    0.
%% creates a dehydrated version of the current state to be cached and
%% potentially used to for a snaphot at a later point
dehydrate_state(#?STATE{cfg = #cfg{},
                         dlx = DlxState} = State) ->
    % no messages are kept in memory, no need to
    % overly mutate the current state apart from removing indexes and cursors
    State#?STATE{ra_indexes = rabbit_fifo_index:empty(),
                  release_cursors = lqueue:new(),
                  enqueue_count = 0,
                  msg_cache = undefined,
                  dlx = rabbit_fifo_dlx:dehydrate(DlxState)}.

%% make the state suitable for equality comparison
normalize(#?STATE{ra_indexes = _Indexes,
                   returns = Returns,
                   messages = Messages,
                   release_cursors = Cursors,
                   dlx = DlxState} = State) ->
    State#?STATE{returns = lqueue:from_list(lqueue:to_list(Returns)),
                  messages = lqueue:from_list(lqueue:to_list(Messages)),
                  release_cursors = lqueue:from_list(lqueue:to_list(Cursors)),
                  dlx = rabbit_fifo_dlx:normalize(DlxState)}.

is_over_limit(#?STATE{cfg = #cfg{max_length = undefined,
                                  max_bytes = undefined}}) ->
    false;
is_over_limit(#?STATE{cfg = #cfg{max_length = MaxLength,
                                  max_bytes = MaxBytes},
                       msg_bytes_enqueue = BytesEnq,
                       dlx = DlxState} = State) ->
    {NumDlx, BytesDlx} = rabbit_fifo_dlx:stat(DlxState),
    (messages_ready(State) + NumDlx > MaxLength) orelse
    (BytesEnq + BytesDlx > MaxBytes).

is_below_soft_limit(#?STATE{cfg = #cfg{max_length = undefined,
                                        max_bytes = undefined}}) ->
    false;
is_below_soft_limit(#?STATE{cfg = #cfg{max_length = MaxLength,
                                        max_bytes = MaxBytes},
                             msg_bytes_enqueue = BytesEnq,
                             dlx = DlxState} = State) ->
    {NumDlx, BytesDlx} = rabbit_fifo_dlx:stat(DlxState),
    is_below(MaxLength, messages_ready(State) + NumDlx) andalso
    is_below(MaxBytes, BytesEnq + BytesDlx).

is_below(undefined, _Num) ->
    true;
is_below(Val, Num) when is_integer(Val) andalso is_integer(Num) ->
    Num =< trunc(Val * ?LOW_LIMIT).

-spec make_enqueue(option(pid()), option(msg_seqno()), raw_msg()) -> protocol().
make_enqueue(Pid, Seq, Msg) ->
    case is_v4() of
        true when is_pid(Pid) andalso
                  is_integer(Seq) ->
            %% more compact format
            #?ENQ_V2{seq = Seq, msg = Msg};
        _ ->
            #enqueue{pid = Pid, seq = Seq, msg = Msg}
    end.

-spec make_register_enqueuer(pid()) -> protocol().
make_register_enqueuer(Pid) ->
    #register_enqueuer{pid = Pid}.

-spec make_checkout(consumer_id(), checkout_spec(), consumer_meta()) ->
    protocol().
make_checkout({_, _} = ConsumerId, Spec0, Meta) ->
    Spec = case is_v4() of
               false when Spec0 == remove ->
                   %% if v4 is not active, fall back to cancel spec
                   make_checkout(ConsumerId, cancel, Meta);
               _ ->
                   Spec0
           end,
    #checkout{consumer_id = ConsumerId,
              spec = Spec, meta = Meta}.

-spec make_settle(consumer_key(), [msg_id()]) -> protocol().
make_settle(ConsumerKey, MsgIds) when is_list(MsgIds) ->
    #settle{consumer_key = ConsumerKey, msg_ids = MsgIds}.

-spec make_return(consumer_id(), [msg_id()]) -> protocol().
make_return(ConsumerKey, MsgIds) ->
    #return{consumer_key = ConsumerKey, msg_ids = MsgIds}.

-spec make_discard(consumer_id(), [msg_id()]) -> protocol().
make_discard(ConsumerKey, MsgIds) ->
    #discard{consumer_key = ConsumerKey, msg_ids = MsgIds}.

-spec make_credit(consumer_key(), rabbit_queue_type:credit(),
                  non_neg_integer(), boolean()) -> protocol().
make_credit(Key, Credit, DeliveryCount, Drain) ->
    #credit{consumer_key = Key,
            credit = Credit,
            delivery_count = DeliveryCount,
            drain = Drain}.

-spec make_defer(consumer_key(), [msg_id()]) -> protocol().
make_defer(ConsumerKey, MsgIds) when is_list(MsgIds) ->
    #defer{consumer_key = ConsumerKey, msg_ids = MsgIds}.

-spec make_purge() -> protocol().
make_purge() -> #purge{}.

-spec make_garbage_collection() -> protocol().
make_garbage_collection() -> #garbage_collection{}.

-spec make_purge_nodes([node()]) -> protocol().
make_purge_nodes(Nodes) ->
    #purge_nodes{nodes = Nodes}.

-spec make_update_config(config()) -> protocol().
make_update_config(Config) ->
    #update_config{config = Config}.

-spec make_eval_consumer_timeouts([consumer_key()]) -> protocol().
make_eval_consumer_timeouts(Keys) when is_list(Keys) ->
    #eval_consumer_timeouts{consumer_keys = Keys}.

add_bytes_drop(Header,
               #?STATE{msg_bytes_enqueue = Enqueue} = State) ->
    Size = get_header(size, Header),
    State#?STATE{msg_bytes_enqueue = Enqueue - Size}.


add_bytes_return(Header,
                 #?STATE{msg_bytes_checkout = Checkout,
                          msg_bytes_enqueue = Enqueue} = State) ->
    Size = get_header(size, Header),
    State#?STATE{msg_bytes_checkout = Checkout - Size,
                  msg_bytes_enqueue = Enqueue + Size}.

message_size(#basic_message{content = Content}) ->
    #content{payload_fragments_rev = PFR} = Content,
    iolist_size(PFR);
message_size(B) when is_binary(B) ->
    byte_size(B);
message_size(Msg) ->
    case mc:is(Msg) of
        true ->
            {_, PayloadSize} = mc:size(Msg),
            PayloadSize;
        false ->
            %% probably only hit this for testing so ok to use erts_debug
            erts_debug:size(Msg)
    end.


all_nodes(#?STATE{consumers = Cons0,
                  enqueuers = Enqs0,
                  waiting_consumers = WaitingConsumers0}) ->
    Nodes0 = maps:fold(fun(_, ?CONSUMER_PID(P), Acc) ->
                               Acc#{node(P) => ok}
                       end, #{}, Cons0),
    Nodes1 = maps:fold(fun(P, _, Acc) ->
                               Acc#{node(P) => ok}
                       end, Nodes0, Enqs0),
    maps:keys(
      lists:foldl(fun({_, ?CONSUMER_PID(P)}, Acc) ->
                          Acc#{node(P) => ok}
                  end, Nodes1, WaitingConsumers0)).

all_pids_for(Node, #?STATE{consumers = Cons0,
                           enqueuers = Enqs0,
                           waiting_consumers = WaitingConsumers0}) ->
    Cons = maps:fold(fun(_, ?CONSUMER_PID(P), Acc)
                           when node(P) =:= Node ->
                             [P | Acc];
                        (_, _, Acc) -> Acc
                     end, [], Cons0),
    Enqs = maps:fold(fun(P, _, Acc)
                           when node(P) =:= Node ->
                             [P | Acc];
                        (_, _, Acc) -> Acc
                     end, Cons, Enqs0),
    lists:foldl(fun({_, ?CONSUMER_PID(P)}, Acc)
                      when node(P) =:= Node ->
                        [P | Acc];
                   (_, Acc) -> Acc
                end, Enqs, WaitingConsumers0).

suspected_pids_for(Node, #?STATE{consumers = Cons0,
                                 enqueuers = Enqs0,
                                 waiting_consumers = WaitingConsumers0}) ->
    Cons = maps:fold(fun(_Key,
                         #consumer{cfg = #consumer_cfg{pid = P},
                                   status = suspected_down},
                         Acc)
                           when node(P) =:= Node ->
                             [P | Acc];
                        (_, _, Acc) -> Acc
                     end, [], Cons0),
    Enqs = maps:fold(fun(P, #enqueuer{status = suspected_down}, Acc)
                           when node(P) =:= Node ->
                             [P | Acc];
                        (_, _, Acc) -> Acc
                     end, Cons, Enqs0),
    lists:foldl(fun({_Key,
                     #consumer{cfg = #consumer_cfg{pid = P},
                               status = suspected_down}}, Acc)
                      when node(P) =:= Node ->
                        [P | Acc];
                   (_, Acc) -> Acc
                end, Enqs, WaitingConsumers0).

is_expired(Ts, #?STATE{cfg = #cfg{expires = Expires},
                        last_active = LastActive,
                        consumers = Consumers})
  when is_number(LastActive) andalso is_number(Expires) ->
    %% TODO: should it be active consumers?
    Active = maps:filter(fun (_, #consumer{status = suspected_down}) ->
                                 false;
                             (_, _) ->
                                 true
                         end, Consumers),

    Ts > (LastActive + Expires) andalso maps:size(Active) == 0;
is_expired(_Ts, _State) ->
    false.

%%TODO: provide first class means of configuring
get_priority(#{priority := Priority}) ->
    Priority;
get_priority(#{args := Args}) ->
    %% fallback, v3 option
    case rabbit_misc:table_lookup(Args, <<"x-priority">>) of
        {_Key, Value} ->
            Value;
        _ -> 0
    end;
get_priority(_) ->
    0.

notify_decorators_effect(QName, MaxActivePriority, IsEmpty) ->
    {mod_call, rabbit_quorum_queue, spawn_notify_decorators,
     [QName, consumer_state_changed, [MaxActivePriority, IsEmpty]]}.

notify_decorators_startup(QName) ->
    {mod_call, rabbit_quorum_queue, spawn_notify_decorators,
     [QName, startup, []]}.

convert(_Meta, To, To, State) ->
    State;
convert(Meta, 0, To, State) ->
    convert(Meta, 1, To, rabbit_fifo_v1:convert_v0_to_v1(State));
convert(Meta, 1, To, State) ->
    convert(Meta, 2, To, rabbit_fifo_v3:convert_v1_to_v2(State));
convert(Meta, 2, To, State) ->
    convert(Meta, 3, To, rabbit_fifo_v3:convert_v2_to_v3(State));
convert(Meta, 3, To, State) ->
    convert(Meta, 4, To, convert_v3_to_v4(Meta, State)).

smallest_raft_index(#?STATE{messages = Messages,
                            ra_indexes = Indexes,
                            dlx = DlxState}) ->
    SmallestDlxRaIdx = rabbit_fifo_dlx:smallest_raft_index(DlxState),
    SmallestMsgsRaIdx = case lqueue:get(Messages, undefined) of
                            ?MSG(I, _) when is_integer(I) ->
                                I;
                            _ ->
                                undefined
                        end,
    SmallestRaIdx = rabbit_fifo_index:smallest(Indexes),
    lists:min([SmallestDlxRaIdx, SmallestMsgsRaIdx, SmallestRaIdx]).

make_requeue(ConsumerKey, Notify, [{MsgId, Idx, Header, Msg}], Acc) ->
    lists:reverse([{append,
                    #requeue{consumer_key = ConsumerKey,
                             index = Idx,
                             header = Header,
                             msg_id = MsgId,
                             msg = Msg},
                    Notify}
                   | Acc]);
make_requeue(ConsumerKey, Notify, [{MsgId, Idx, Header, Msg} | Rem], Acc) ->
    make_requeue(ConsumerKey, Notify, Rem,
                 [{append,
                   #requeue{consumer_key = ConsumerKey,
                            index = Idx,
                            header = Header,
                            msg_id = MsgId,
                            msg = Msg},
                   noreply}
                  | Acc]);
make_requeue(_ConsumerId, _Notify, [], []) ->
    [].

can_immediately_deliver(#?STATE{service_queue = SQ,
                                consumers = Consumers} = State) ->
    case messages_ready(State) of
        0 when map_size(Consumers) > 0 ->
            %% TODO: is is probably good enough but to be 100% we'd need to
            %% scan all consumers and ensure at least one has credit
            priority_queue:is_empty(SQ) == false;
        _ ->
            false
    end.

incr(I) ->
   I + 1.

get_msg(#?ENQ_V2{msg = M}) ->
    M;
get_msg(#enqueue{msg = M}) ->
    M;
get_msg(#requeue{msg = M}) ->
    M.

initial_delivery_count({credited, Count}) ->
    %% credit API v2
    Count;
initial_delivery_count(_) ->
    %% credit API v1
    0.

credit_api_v2(#consumer_cfg{credit_mode = {credited, _}}) ->
    true;
credit_api_v2(_) ->
    false.

link_credit_snd(DeliveryCountRcv, LinkCreditRcv, DeliveryCountSnd, ConsumerCfg) ->
    case credit_api_v2(ConsumerCfg) of
        true ->
            amqp10_util:link_credit_snd(DeliveryCountRcv, LinkCreditRcv, DeliveryCountSnd);
        false ->
            C = DeliveryCountRcv + LinkCreditRcv - DeliveryCountSnd,
            %% C can be negative when receiver decreases credits while messages are in flight.
            max(0, C)
    end.

consumer_id(#consumer{cfg = Cfg}) ->
    {Cfg#consumer_cfg.tag, Cfg#consumer_cfg.pid}.

consumer_id(Key, #?STATE{consumers = Consumers})
  when is_integer(Key) ->
    consumer_id(maps:get(Key, Consumers));
consumer_id({_, _} = ConsumerId, _State) ->
    ConsumerId.


consumer_key_from_id(ConsumerId, #?STATE{consumers = Consumers})
  when is_map_key(ConsumerId, Consumers) ->
    {ok, ConsumerId};
consumer_key_from_id(ConsumerId, #?STATE{consumers = Consumers,
                                         waiting_consumers = Waiting}) ->
    case consumer_key_from_id(ConsumerId, maps:next(maps:iterator(Consumers))) of
        {ok, _} = Res ->
            Res;
        error ->
            %% scan the waiting consumers
            case lists:search(fun ({_K, ?CONSUMER_TAG_PID(T, P)}) ->
                                      {T, P} == ConsumerId
                              end, Waiting) of
                {value, {K, _}} ->
                    {ok, K};
                false ->
                    error
            end
    end;
consumer_key_from_id({CTag, CPid}, {Key, ?CONSUMER_TAG_PID(T, P), _I})
  when T == CTag andalso P == CPid ->
    {ok, Key};
consumer_key_from_id(ConsumerId, {_, _, I}) ->
    consumer_key_from_id(ConsumerId, maps:next(I));
consumer_key_from_id(_ConsumerId, none) ->
    error.


consumer_cancel_info(ConsumerKey, #?STATE{consumers = Consumers}) ->
    case Consumers of
        #{ConsumerKey := #consumer{checked_out = Checked}} ->
            #{key => ConsumerKey,
              num_checked_out => map_size(Checked)};
        _ ->
            #{}
    end.

find_consumer(Key, Consumers) ->
    case Consumers of
        #{Key := Con} ->
            {Key, Con};
        _ when is_tuple(Key) ->
            %% sometimes rabbit_fifo_client may send a settle, return etc
            %% by it's ConsumerId even if it was created with an integer key
            %% as it may have lost it's state after a consumer cancel
            maps_search(fun (_K, ?CONSUMER_TAG_PID(Tag, Pid)) ->
                                Key == {Tag, Pid}
                        end, Consumers);
        _ ->
            undefined
    end.

maps_search(_Pred, none) ->
    undefined;
maps_search(Pred, {K, V, I}) ->
    case Pred(K, V) of
        true ->
            {K, V};
        false ->
            maps_search(Pred, maps:next(I))
    end;
maps_search(Pred, Map) when is_map(Map) ->
    maps_search(Pred, maps:next(maps:iterator(Map))).

reactivate_timed_out(#consumer{status = timed_out} = C) ->
    C#consumer{status = up};
reactivate_timed_out(C) ->
    C.

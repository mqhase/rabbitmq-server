%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2022 VMware, Inc. or its affiliates.  All rights reserved.
%%

-module(exchange_SUITE).

-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("rabbitmq_ct_helpers/include/rabbit_assert.hrl").
-include_lib("amqp_client/include/amqp_client.hrl").

-include("rabbit_federation.hrl").

-compile(export_all).

-import(rabbit_federation_test_util,
        [expect/3, expect/4, expect_empty/2,
         set_upstream/4, set_upstream/5, set_upstream_in_vhost/5, set_upstream_in_vhost/6,
         clear_upstream/3, set_upstream_set/4,
         set_policy/5, set_policy_pattern/5, clear_policy/3,
         set_policy_upstream/5, set_policy_upstreams/4,
         all_federation_links/2, federation_links_in_vhost/3, status_fields/2]).

-import(rabbit_ct_broker_helpers,
        [set_policy_in_vhost/7]).

all() ->
    [
      {group, essential}
      %% {group, cycle_detection},
      %% {group, channel_use_mode_single}
    ].

groups() ->
  [
    {essential, [], [
      single_upstream,
      multiple_upstreams
    ]},
    {cycle_detection, [], [

    ]},
    {channel_use_mod_single, [], [

    ]}
  ].


%% -------------------------------------------------------------------
%% Setup/teardown.
%% -------------------------------------------------------------------

init_per_suite(Config) ->
  rabbit_ct_helpers:log_environment(),
  rabbit_ct_helpers:run_setup_steps(Config).

end_per_suite(Config) ->
  rabbit_ct_helpers:run_teardown_steps(Config).

%% Some of the "regular" tests but in the single channel mode.
init_per_group(channel_use_mode_single, Config) ->
  SetupFederation = [
      fun(Config1) ->
          rabbit_federation_test_util:setup_federation_with_upstream_params(Config1, [
              {<<"channel-use-mode">>, <<"single">>}
          ])
      end
  ],
  Suffix = rabbit_ct_helpers:testcase_absname(Config, "", "-"),
  Config1 = rabbit_ct_helpers:set_config(Config, [
      {rmq_nodename_suffix, Suffix},
      {rmq_nodes_clustered, false}
    ]),
  rabbit_ct_helpers:run_steps(Config1,
    rabbit_ct_broker_helpers:setup_steps() ++
    rabbit_ct_client_helpers:setup_steps() ++
    SetupFederation);
init_per_group(cycle_detection, Config) ->
  Suffix = rabbit_ct_helpers:testcase_absname(Config, "", "-"),
  Config1 = rabbit_ct_helpers:set_config(Config, [
      {rmq_nodename_suffix, Suffix},
      {rmq_nodes_clustered, false},
      {rmq_nodes_count, 1}
    ]),
  rabbit_ct_helpers:run_steps(Config1,
    rabbit_ct_broker_helpers:setup_steps() ++
    rabbit_ct_client_helpers:setup_steps());
init_per_group(without_plugins, Config) ->
  rabbit_ct_helpers:set_config(Config,
    {broker_with_plugins, [true, false]});
init_per_group(cluster_size_1 = Group, Config) ->
  Config1 = rabbit_ct_helpers:set_config(Config, [
      {rmq_nodes_count, 1}
    ]),
  init_per_group1(Group, Config1);
init_per_group(cluster_size_2 = Group, Config) ->
  Config1 = rabbit_ct_helpers:set_config(Config, [
      {rmq_nodes_count, 2}
    ]),
  init_per_group1(Group, Config1);
init_per_group(cluster_size_3 = Group, Config) ->
  Config1 = rabbit_ct_helpers:set_config(Config, [
      {rmq_nodes_count, 3}
    ]),
  init_per_group1(Group, Config1);
init_per_group(Group, Config) ->
  init_per_group1(Group, Config).


init_per_group1(_Group, Config) ->
  Suffix = rabbit_ct_helpers:testcase_absname(Config, "", "-"),
  Config1 = rabbit_ct_helpers:set_config(Config, [
      {rmq_nodename_suffix, Suffix},
      {rmq_nodes_clustered, false}
    ]),
  rabbit_ct_helpers:run_steps(Config1,
    rabbit_ct_broker_helpers:setup_steps() ++
    rabbit_ct_client_helpers:setup_steps()).

end_per_group(without_plugins, Config) ->
  Config;
end_per_group(_, Config) ->
  rabbit_ct_helpers:run_steps(Config,
    rabbit_ct_client_helpers:teardown_steps() ++
    rabbit_ct_broker_helpers:teardown_steps()
  ).

init_per_testcase(Testcase, Config) ->
  rabbit_ct_helpers:testcase_started(Config, Testcase).

end_per_testcase(Testcase, Config) ->
  rabbit_ct_helpers:testcase_finished(Config, Testcase).


%%
%% Test cases
%%

single_upstream(Config) ->
  FedX = <<"single_upstream.federated">>,
  UpX = <<"single_upstream.upstream.x">>,
  rabbit_ct_broker_helpers:set_parameter(
    Config, 0, <<"federation-upstream">>, <<"localhost">>,
    [
      {<<"uri">>,      rabbit_ct_broker_helpers:node_uri(Config, 0)},
      {<<"exchange">>, UpX}
    ]),
  rabbit_ct_broker_helpers:set_policy(
    Config, 0,
    <<"fed.x">>, <<"^single_upstream.federated">>, <<"exchanges">>,
    [
      {<<"federation-upstream">>, <<"localhost">>}
    ]),

  Ch = rabbit_ct_client_helpers:open_channel(Config, 0),

  Xs = [
    exchange_declare_method(FedX)
  ],
  declare_exchanges(Ch, Xs),

  RK = <<"key">>,
  Q = declare_and_bind_queue(Ch, FedX, RK),
  await_binding(Config, 0, UpX, RK),
  publish_expect(Ch, UpX, RK, Q, <<"single_upstream payload">>),

  rabbit_ct_client_helpers:close_channel(Ch),
  clean_up_federation_related_bits(Config).


multiple_upstreams(Config) ->
  FedX = <<"multiple_upstreams.federated">>,
  UpX1 = <<"upstream.x.1">>,
  UpX2 = <<"upstream.x.2">>,
  set_up_upstreams(Config),
  rabbit_ct_broker_helpers:set_policy(
    Config, 0,
    <<"fed.x">>, <<"^multiple_upstreams.federated">>, <<"exchanges">>,
    [
      {<<"federation-upstream-set">>, <<"all">>}
    ]),

  Ch = rabbit_ct_client_helpers:open_channel(Config, 0),
  Xs = [
    exchange_declare_method(FedX)
  ],
  declare_exchanges(Ch, Xs),

  RK = <<"multiple_upstreams.key">>,
  Q = declare_and_bind_queue(Ch, FedX, RK),
  await_binding(Config, 0, UpX1, RK),
  await_binding(Config, 0, UpX2, RK),
  publish_expect(Ch, UpX1, RK, Q, <<"multiple_upstreams payload">>),
  publish_expect(Ch, UpX2, RK, Q, <<"multiple_upstreams payload">>),

  rabbit_ct_client_helpers:close_channel(Ch),
  clean_up_federation_related_bits(Config).

multiple_upstreams_pattern(_Config) ->
  ok.


%%
%% Test helpers
%%

clean_up_federation_related_bits(Config) ->
  delete_all_queues_on(Config, 0),
  delete_all_exchanges_on(Config, 0),
  delete_all_policies_on(Config, 0).

set_up_upstream(Config) ->
  rabbit_ct_broker_helpers:set_parameter(
    Config, 0, <<"federation-upstream">>, <<"localhost">>,
    [
      {<<"uri">>,      rabbit_ct_broker_helpers:node_uri(Config, 0)},
      {<<"exchange">>, <<"upstream">>}
    ]).

set_up_upstreams(Config) ->
  rabbit_ct_broker_helpers:set_parameter(
    Config, 0, <<"federation-upstream">>, <<"localhost1">>,
    [
      {<<"uri">>,      rabbit_ct_broker_helpers:node_uri(Config, 0)},
      {<<"exchange">>, <<"upstream.x.1">>}
    ]),
  rabbit_ct_broker_helpers:set_parameter(
    Config, 0, <<"federation-upstream">>, <<"localhost2">>,
    [
      {<<"uri">>,      rabbit_ct_broker_helpers:node_uri(Config, 0)},
      {<<"exchange">>, <<"upstream.x.2">>}
    ]).

set_up_upstreams_including_unavailable(Config) ->
  rabbit_ct_broker_helpers:set_parameter(
    Config, 0, <<"federation-upstream">>, <<"unavailable-node">>,
    [
      {<<"uri">>, <<"amqp://unavailable-node">>},
      {<<"reconnect-delay">>, 600000}
    ]),

  rabbit_ct_broker_helpers:set_parameter(
    Config, 0, <<"federation-upstream">>, <<"localhost">>,
    [
      {<<"uri">>, rabbit_ct_broker_helpers:node_uri(Config, 0)}
    ]).

declare_exchanges(Ch, Frames) ->
  [declare_exchange(Ch, F) || F <- Frames].
delete_exchanges(Ch, Frames) ->
    [delete_exchange(Ch, X) || #'exchange.declare'{exchange = X} <- Frames].

declare_exchange(Ch, X) ->
    amqp_channel:call(Ch, X).

declare_queue(Ch) ->
  #'queue.declare_ok'{queue = Q} =
      amqp_channel:call(Ch, #'queue.declare'{exclusive = true}),
  Q.

declare_queue(Ch, Q) ->
  amqp_channel:call(Ch, Q).

bind_queue(Ch, Q, X, Key) ->
    amqp_channel:call(Ch, #'queue.bind'{queue       = Q,
                                        exchange    = X,
                                        routing_key = Key}).

unbind_queue(Ch, Q, X, Key) ->
    amqp_channel:call(Ch, #'queue.unbind'{queue       = Q,
                                          exchange    = X,
                                          routing_key = Key}).

bind_exchange(Ch, D, S, Key) ->
    amqp_channel:call(Ch, #'exchange.bind'{destination = D,
                                           source      = S,
                                           routing_key = Key}).

declare_and_bind_queue(Ch, X, Key) ->
    Q = declare_queue(Ch),
    bind_queue(Ch, Q, X, Key),
    Q.


delete_exchange(Ch, XName) ->
  amqp_channel:call(Ch, #'exchange.delete'{exchange = XName}).

delete_queue(Ch, QName) ->
  amqp_channel:call(Ch, #'queue.delete'{queue = QName}).

exchange_declare_method(Name) ->
  exchange_declare_method(Name, <<"topic">>).

exchange_declare_method(Name, Type) ->
  #'exchange.declare'{exchange = Name,
                      type     = Type,
                      durable  = true}.

delete_all_queues_on(Config, Node) ->
  [rabbit_ct_broker_helpers:rpc(
     Config, Node, rabbit_amqqueue, delete, [Q, false, false,
                                             <<"acting-user">>]) ||
      Q <- all_queues_on(Config, Node)].

delete_all_exchanges_on(Config, Node) ->
  [rabbit_ct_broker_helpers:rpc(
    Config, Node, rabbit_exchange, delete, [X, false,
                                            <<"acting-user">>]) ||
     #exchange{name = X} <- all_exchanges_on(Config, Node)].

delete_all_policies_on(Config, Node) ->
  [rabbit_ct_broker_helpers:rpc(
    Config, Node, rabbit_policy, delete, [V, Name, <<"acting-user">>]) ||
      #{name := Name, vhost := V} <- all_policies_on(Config, Node)].

all_queues_on(Config, Node) ->
  Ret = rabbit_ct_broker_helpers:rpc(Config, Node,
    rabbit_amqqueue, list, [<<"/">>]),
  case Ret of
      {badrpc, _} -> [];
      Qs          -> Qs
  end.

all_exchanges_on(Config, Node) ->
  Ret = rabbit_ct_broker_helpers:rpc(Config, Node,
    rabbit_exchange, list, [<<"/">>]),
  case Ret of
      {badrpc, _} -> [];
      Xs          -> Xs
  end.

all_policies_on(Config, Node) ->
  Ret = rabbit_ct_broker_helpers:rpc(Config, Node,
    rabbit_policy, list, [<<"/">>]),
  case Ret of
      {badrpc, _} -> [];
      Xs          -> [maps:from_list(PList) || PList <- Xs]
  end.

await_binding(Config, Node, X, Key) ->
  await_binding(Config, Node, X, Key, 1).

await_binding(Config, Node, X, Key, ExpectedBindingCount) when is_integer(ExpectedBindingCount) ->
  await_binding(Config, Node, <<"/">>, X, Key, ExpectedBindingCount).

await_binding(Config, Node, Vhost, X, Key, ExpectedBindingCount) when is_integer(ExpectedBindingCount) ->
  Attempts = 100,
  await_binding(Config, Node, Vhost, X, Key, ExpectedBindingCount, Attempts).

await_binding(_Config, _Node, _Vhost, _X, _Key, ExpectedBindingCount, 0) ->
  {error, rabbit_misc:format("expected ~b bindings but they did not materialize in time", [ExpectedBindingCount])};
await_binding(Config, Node, Vhost, X, Key, ExpectedBindingCount, AttemptsLeft) when is_integer(ExpectedBindingCount) ->
  case bound_keys_from(Config, Node, Vhost, X, Key) of
      Bs when length(Bs) < ExpectedBindingCount ->
          timer:sleep(100),
          await_binding(Config, Node, Vhost, X, Key, ExpectedBindingCount, AttemptsLeft - 1);
      Bs when length(Bs) =:= ExpectedBindingCount ->
          ok;
      Bs ->
          {error, rabbit_misc:format("expected ~b bindings, got ~b", [ExpectedBindingCount, length(Bs)])}
  end.

await_bindings(Config, Node, X, Keys) ->
  [await_binding(Config, Node, X, Key) || Key <- Keys].

await_binding_absent(Config, Node, X, Key) ->
  case bound_keys_from(Config, Node, <<"/">>, X, Key) of
      [] -> ok;
      _  -> timer:sleep(100),
            await_binding_absent(Config, Node, X, Key)
  end.

bound_keys_from(Config, Node, Vhost, X, Key) ->
  Res = rabbit_misc:r(Vhost, exchange, X),
  List = rabbit_ct_broker_helpers:rpc(Config, Node,
                                      rabbit_binding, list_for_source, [Res]),
  [K || #binding{key = K} <- List, K =:= Key].

publish_expect(Ch, X, Key, Q, Payload) ->
  publish(Ch, X, Key, Payload),
  expect(Ch, Q, [Payload]).

publish(Ch, X, Key, Payload) when is_binary(Payload) ->
  publish(Ch, X, Key, #amqp_msg{payload = Payload});

publish(Ch, X, Key, Msg = #amqp_msg{}) ->
  amqp_channel:call(Ch, #'basic.publish'{exchange    = X,
                                         routing_key = Key}, Msg).

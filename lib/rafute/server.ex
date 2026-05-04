defmodule Rafute.Server do
  @behaviour :gen_fsm

  require Logger

  alias Rafute.{
    RequestVoteRPC,
    RequestVoteRPCReply,
    AppendEntriesRPC,
    AppendEntriesRPCReply,
    Entry,
    Command
  }

  def start_link(name, servers, mode) do
    :gen_fsm.start_link({:local, name}, __MODULE__, [name, servers, mode], [])
  end

  def init([me, servers, mode]) do
    ## TODO: other backends
    ## TODO: backend_sup
    {backend, backend_state} = Rafute.Backend.Agent.start_link
    state = %{
      me: {me, node()},
      servers: servers,
      new_servers: [],

      joint_started: false,
      c_old_new: false,
      c_old_new_index: nil,
      copy_index: 0,
      new_copy_index: 0,

      ## TODO: persist
      current_term: 0,
      voted_for: nil,
      logs: [],

      log_info: %{last_index: 0, last_term: 0},
      commit_index: 0,

      next_index: %{},
      match_index: %{},

      votes: MapSet.new(),
      votes_new: MapSet.new(),
      election_timer_ref: nil,
      heartbeat_timer_ref: nil,
      leader: nil,

      backend: backend,
      backend_state: backend_state,

      client_index: %{},
    }
    state = set_election_timer(state)
    case mode do
      :normal ->
        {:ok, :follower, state}
      :learner ->
        {:ok, :learner, state}
    end
  end

  def learner(:election_timeout, state) do
    Logger.debug("#{elem(state.me, 0)}: turn off because leader is down")
    {:stop, :leader_down, state}
  end
  def learner(%AppendEntriesRPC{} = rpc, state) do
    handle_append_entries(:learner, rpc, state, :learner)
  end
  def learner(_message, state) do
    {:next_state, :learner, state}
  end

  def follower(:election_timeout, state) do
    state = become_candidate(state)
    {:next_state, :candidate, state}
  end
  def follower(%RequestVoteRPC{} = rpc, state) do
    handle_request_vote(:follower, rpc, state)
  end
  def follower(%AppendEntriesRPC{} = rpc, state) do
    handle_append_entries(:follower, rpc, state, :follower)
  end
  def follower(_message, state) do
    {:next_state, :follower, state}
  end

  def follower(%Command{}, _from, state) do
    reply = {:error, {:redirect, state.leader}}
    {:reply, reply, :follower, state}
  end

  def follower({:add_servers,_servers},_from,state) do
    reply = {:error, {:redirect, state.leader}}
    {:reply, reply, :follower, state}
  end

  def candidate(:election_timeout, state) do
    ## for a case of single node
    if (MapSet.size(state.votes) + 1) > (state.servers |> length() |> div(2)) do
      state = become_leader(state)
      {:next_state, :leader, state}
    else
      state = become_candidate(state)
      {:next_state, :candidate, state}
    end
  end
  def candidate(%RequestVoteRPC{term: term} = rpc, %{current_term: current_term} = state) when term > current_term do
    handle_request_vote(:candidate, rpc, state)
  end
  def candidate(%RequestVoteRPC{} = rpc, state) do
    reject_vote(rpc.from, state.me, state.current_term)
    {:next_state, :candidate, state}
  end
  def candidate(%RequestVoteRPCReply{term: term}, %{current_term: current_term} = state) when term < current_term do
    {:next_state, :candidate, state}
  end
  def candidate(%RequestVoteRPCReply{vote_granted: false, term: term}, %{current_term: current_term} = state) when term == current_term do
    {:next_state, :candidate, state}
  end
  def candidate(%RequestVoteRPCReply{vote_granted: false, term: term}, %{current_term: current_term} = state) when term > current_term do
    state = become_follower(term, state)
    {:next_state, :follower, state}
  end
  def candidate(%RequestVoteRPCReply{vote_granted: true, from: from}, state) do
    if state.c_old_new do
      new = Enum.member?(state.new_servers, from)
      if new do
        votes = MapSet.put(state.votes_new, from)
        ## including me
        count_old = MapSet.size(state.votes) + 1
        count_new = count_old + MapSet.size(votes)
        if count_old > (state.servers |> length() |> div(2)) and count_new > (Enum.concat(state.servers, state.new_servers) |> length() |> div(2)) do
          state = become_leader(state)
          {:next_state, :leader, state}
        else
          {:next_state, :candidate, %{state|votes_new: votes}}
        end
      else
        votes = MapSet.put(state.votes, from)
        ## including me
        count_old = MapSet.size(votes) + 1
        count_new = count_old + MapSet.size(state.votes_new)
        if count_old > (state.servers |> length() |> div(2)) and count_new > (Enum.concat(state.servers, state.new_servers) |> length() |> div(2)) do
          state = become_leader(state)
          {:next_state, :leader, state}
        else
          {:next_state, :candidate, %{state|votes: votes}}
        end
      end
    else
      votes = MapSet.put(state.votes, from)
      ## including me
      if (MapSet.size(votes) + 1) > (state.servers |> length() |> div(2)) do
        state = become_leader(state)
        {:next_state, :leader, state}
      else
        {:next_state, :candidate, %{state|votes: votes}}
      end
    end
  end
  def candidate(%AppendEntriesRPC{} = rpc, state) do
    handle_append_entries(:candidate, rpc, state, :follower)
  end
  def candidate(_message, state) do
    {:next_state, :candidate, state}
  end

  def candidate(%Command{}, _from, state) do
    {:reply, {:error, {:redirect, state.leader}}, :candidate, state}
  end

  def leader(:heartbeat_timeout, state) do
    heartbeat = %AppendEntriesRPC{
      term: state.current_term,
      leader_id: state.me,
      prev_log_index: state.log_info.last_index,
      prev_log_term: state.log_info.last_term,
      entries: [],
      leader_commit: state.commit_index,
      from: state.me,
    }
    broadcast(heartbeat, state)
    state = set_heartbeat_timer(state)
    {:next_state, :leader, state}
  end

  def leader({:add_servers, servers},_from, state) do
    exists = Enum.any?(servers, &(&1 in state.servers))
    if exists do
      {:reply, {:error, {:server_already_exists}}, :leader, state}
    else
      new_next_index = for server <- servers, server != state.me, into: %{}, do: {server, 1}
      new_match_index = for server <- servers, server != state.me, into: %{}, do: {server, 0}

      state = %{state | new_servers: Enum.concat(state.new_servers,servers), next_index: Map.merge(state.next_index, new_next_index), match_index: Map.merge(state.match_index, new_match_index)}
      rpc = {:copy_log, servers}
      :gen_fsm.send_event_after(0, rpc)
      {:reply, :ok, :leader, state}
    end
  end

  def leader({:copy_log, servers}, state) do
    Logger.debug("#{elem(state.me, 0)}: start copying logs to new servers")
    state = %{state | copy_index: state.commit_index}
    rpc = %AppendEntriesRPC{
      term: state.current_term,
      leader_id: state.me,
      leader_commit: state.commit_index,
      from: state.me
    }
    for server <- servers, server != state.me do
      next_index = state.next_index[server]
      {entries, prev_log_index, prev_log_term} = get_entries_from(next_index, state)
      rpc = %{rpc | entries: entries, prev_log_index: prev_log_index, prev_log_term: prev_log_term}
      send_rpc(server, rpc)
    end
    state = set_heartbeat_timer(state)
    {:next_state, :leader, state}
  end

  def leader({:joint_consensus, index}, state) do
    if index >= state.copy_index do
      new_copy_index = state.new_copy_index + 1
      if new_copy_index == length(state.new_servers) do
        Logger.debug("#{elem(state.me, 0)}: start joint consensus")
        index = state.log_info.last_index + 1
        entry = %Entry{command: %Command{type: :c_old_new, args: {state.servers, state.new_servers}}, index: index, term: state.current_term}
        state =
          state
          |> put_in([:log_info, :last_index], index)
          |> put_in([:client_index, index], nil)
        state = append_entries([entry], state, entry, nil)
        rpc = %AppendEntriesRPC{
          term: state.current_term,
          leader_id: state.me,
          leader_commit: state.commit_index,
          from: state.me
        }
        for server <- state.servers, server != state.me do
          next_index = state.next_index[server]
          {entries, prev_log_index, prev_log_term} = get_entries_from(next_index, state)
          rpc = %{rpc | entries: entries, prev_log_index: prev_log_index, prev_log_term: prev_log_term}
          send_rpc(server, rpc)
        end
        for server <- state.new_servers, server != state.me do
          next_index = state.next_index[server]
          {entries, prev_log_index, prev_log_term} = get_entries_from(next_index, state)
          rpc = %{rpc | entries: entries, prev_log_index: prev_log_index, prev_log_term: prev_log_term}
          send_rpc(server, rpc)
        end
        state = %{state | copy_index: 0, new_copy_index: 0}
        state = set_heartbeat_timer(state)
        {:next_state, :leader, state}
      else
        state = %{state | new_copy_index: new_copy_index}
        state = set_heartbeat_timer(state)
        {:next_state, :leader, state}
      end
    else
      state = set_heartbeat_timer(state)
      {:next_state, :leader, state}
    end
  end

  def leader({:finish_joint_consensus}, state) do
    Logger.debug("#{elem(state.me, 0)}: finish joint consensus")
    index = state.log_info.last_index + 1
    entry = %Entry{command: %Command{type: :c_new, args: {state.servers, state.new_servers}}, index: index, term: state.current_term}
    state =
      state
        |> put_in([:log_info, :last_index], index)
        |> put_in([:client_index, index], nil)
    state = append_entries([entry], state, nil, entry)
    rpc = %AppendEntriesRPC{
      term: state.current_term,
      leader_id: state.me,
      leader_commit: state.commit_index,
      from: state.me
    }
    state = %{state | joint_started: false}
    for server <- state.servers, server != state.me do
      next_index = state.next_index[server]
      Logger.debug("#{next_index}")
      {entries, prev_log_index, prev_log_term} = get_entries_from(next_index, state)
      rpc = %{rpc | entries: entries, prev_log_index: prev_log_index, prev_log_term: prev_log_term}
      send_rpc(server, rpc)
    end
    for server <- state.new_servers, server != state.me do
      next_index = state.next_index[server]
      Logger.debug("#{next_index}")
      {entries, prev_log_index, prev_log_term} = get_entries_from(next_index, state)
      rpc = %{rpc | entries: entries, prev_log_index: prev_log_index, prev_log_term: prev_log_term}
      send_rpc(server, rpc)
    end
    state = set_heartbeat_timer(state)
    {:next_state, :leader, state}
  end

  def leader(%RequestVoteRPC{term: term} = rpc, %{current_term: current_term} = state) when term > current_term do
    handle_request_vote(:leader, rpc, state)
  end
  def leader(%RequestVoteRPC{} = rpc, state) do
    reject_vote(rpc.from, state.me, state.current_term)
    {:next_state, :leader, state}
  end
  def leader(%AppendEntriesRPC{term: term, from: from}, %{current_term: current_term, leader: leader}) when term == current_term and from != leader do
    raise "Duplicated leader #{from} and #{leader}"
  end
  def leader(%AppendEntriesRPC{} = rpc, state) do
    handle_append_entries(:leader, rpc, state, :follower)
  end
  def leader(%AppendEntriesRPCReply{term: term}, %{current_term: current_term} = state) when term > current_term do
    state = become_follower(term, state)
    {:next_state, :follower, state}
  end
  def leader(%AppendEntriesRPCReply{term: term}, %{current_term: current_term} = state) when term < current_term do
    {:next_state, :leader, state}
  end
  def leader(%AppendEntriesRPCReply{from: from, success: false}, state) do
    next_index = state.next_index[from] - 1
    {entries, prev_log_index, prev_log_term} = get_entries_from(next_index, state)
    rpc = %AppendEntriesRPC{
      term: state.current_term,
      leader_id: state.me,
      leader_commit: state.commit_index,
      entries: entries,
      prev_log_index: prev_log_index,
      prev_log_term: prev_log_term,
      from: state.me,
    }
    send_rpc(from, rpc)
    {:next_state, :leader, state}
  end
  def leader(%AppendEntriesRPCReply{from: from, index: index, success: true}, state) do
    from_learner = Enum.member?(state.new_servers,from)
    if from_learner and length(state.new_servers) > 0 and not state.c_old_new do
      state =
        state
        |> put_in([:match_index, from], index)
        |> put_in([:next_index, from], index + 1)
      {:next_state, :leader, state}
    else
      state =
        state
        |> put_in([:match_index, from], index)
        |> put_in([:next_index, from], index + 1)
      commitable_index =
        state.commit_index
        |> Stream.iterate(&(&1 + 1))
        |> Enum.find_value(fn(index) ->
              if state.c_old_new do
                ## including me
                count_old = Enum.count(state.match_index, fn({s, mi}) -> Enum.member?(state.servers, s) and mi >= index end) + 1
                count_new = count_old + Enum.count(state.match_index, fn({s, mi}) -> Enum.member?(state.new_servers, s) and mi >= index end)
                count_old <= (state.servers |> length() |> div(2)) && count_new <= (Enum.concat(state.servers, state.new_servers) |> length() |> div(2)) && index
              else
                ## including me
                count = Enum.count(state.match_index, fn({s, mi}) -> Enum.member?(state.servers, s) and mi >= index end) + 1
                count <= (state.servers |> length() |> div(2)) && index
              end
          end)
        |> (&(&1 - 1)).()
      state = commit_logs(:leader, commitable_index, state)
      {:next_state, :leader, state}
    end
  end
  def leader(_message, state) do
    {:next_state, :leader, state}
  end

  def leader(%Command{type: :read} = command, _from, state) do
    value = state.backend.exec(command, state.backend_state)
    {:reply, {:ok, value}, :leader, state}
  end

  def leader(%Command{} = command, from, state) do
    index = state.log_info.last_index + 1
    entry = %Entry{command: command, index: index, term: state.current_term}
    state =
      state
      |> put_in([:log_info, :last_index], index)
      |> put_in([:client_index, index], from)
    state = append_entries([entry], state, nil, nil)
    rpc = %AppendEntriesRPC{
      term: state.current_term,
      leader_id: state.me,
      leader_commit: state.commit_index,
      from: state.me
    }
    for server <- state.servers, server != state.me do
      next_index = state.next_index[server]
      {entries, prev_log_index, prev_log_term} = get_entries_from(next_index, state)
      rpc = %{rpc | entries: entries, prev_log_index: prev_log_index, prev_log_term: prev_log_term}
      send_rpc(server, rpc)
    end
    if state.c_old_new do
      for server <- state.new_servers, server != state.me do
        next_index = state.next_index[server]
        {entries, prev_log_index, prev_log_term} = get_entries_from(next_index, state)
        rpc = %{rpc | entries: entries, prev_log_index: prev_log_index, prev_log_term: prev_log_term}
        send_rpc(server, rpc)
      end
    end
    state = set_heartbeat_timer(state)
    {:next_state, :leader, state}
  end

  def handle_event(_event, state_name, state) do
    {:next_state, state_name, state}
  end

  def handle_sync_event(_event, state_name, state) do
    {:next_state, state_name, state}
  end

  def handle_sync_event(_event, _from, state_name, state) do
    {:next_state, state_name, state}
  end

  def handle_info(_info, state_name, state) do
    {:next_state, state_name, state}
  end

  def terminate(_reason, _state_name, _state) do
  end

  def code_change(_old, state_name, state, _extra) do
    {:ok, state_name, state}
  end

  defp handle_request_vote(state_name, %RequestVoteRPC{} = rpc, state) do
    up_to_date = rpc.last_log_term > state.log_info.last_term or
                 (rpc.last_log_term == state.log_info.last_term and rpc.last_log_index >= state.log_info.last_index)
    cond do
      rpc.term > state.current_term && up_to_date ->
        state = become_follower(rpc.term, state)
        grant_vote(rpc.from, state.me, state.current_term)
        {:next_state, state_name, %{state|voted_for: rpc.from}}
      rpc.term == state.current_term && up_to_date ->
        if state.voted_for do
          reject_vote(rpc.from, state.me, state.current_term)
          {:next_state, state_name, state}
        else
          grant_vote(rpc.from, state.me, state.current_term)
          {:next_state, state_name, %{state|voted_for: rpc.from}}
        end
      true ->
        reject_vote(rpc.from, state.me, state.current_term)
        {:next_state, state_name, state}
    end
  end

  defp handle_append_entries(state_name, %AppendEntriesRPC{term: term} = rpc,
                             %{current_term: current_term} = state, _mode) when term < current_term do
    send_rpc(rpc.from, %AppendEntriesRPCReply{term: state.current_term, success: false, from: state.me})
    {:next_state, state_name, state}
  end
  defp handle_append_entries(_, rpc, state, mode) do
    state = become_follower(rpc.term, state)
    state = %{state | leader: rpc.from}
    if check_log(rpc.prev_log_index, rpc.prev_log_term, state) do
      entry1 = Enum.find(rpc.entries, fn(entry)-> entry.command.type == :c_old_new end)
      entry2 = Enum.find(rpc.entries, fn(entry)-> entry.command.type == :c_new end)
      state = append_entries(rpc.entries, state, entry1, entry2)
      state = commit_logs(mode, rpc.leader_commit, state)
      send_rpc(rpc.from, %AppendEntriesRPCReply{term: state.current_term, success: true, index:
                                                state.log_info.last_index, from: state.me})
      if entry1 do
        {:next_state, :follower, state}
      else
        {:next_state, mode, state}
      end
    else
      send_rpc(rpc.from, %AppendEntriesRPCReply{term: state.current_term, success: false, from: state.me})
      {:next_state, mode, state}
    end
  end

  ## TODO: Rafute.Log.check/3
  defp check_log(_, _, %{logs: []}) do
    true
  end
  defp check_log(prev_log_index, prev_log_term, state) do
    Enum.any?(state.logs, &(&1.index == prev_log_index and &1.term == prev_log_term))
  end

  ## TODO: Ragute.Log.append_entries/2
  defp append_entries([], state,_entry1,_entry2) do
    state
  end
  defp append_entries([%Entry{index: index}|_] = entries, state, entry1, entry2) do
    if entry1 do
      {old_servers, new_servers} = entry1.command.args
      state = %{state | servers: old_servers, new_servers: new_servers, c_old_new: true, c_old_new_index: entry1.index}
      logs = Enum.drop_while(state.logs, &(&1.index >= index))
      [%Entry{index: index, term: term}|_] = logs = entries ++ logs
      %{state | logs: logs, log_info: %{last_index: index, last_term: term}}
    else
      if entry2 do
        {old_servers, new_servers} = entry2.command.args
        state = %{state | servers: Enum.concat(old_servers, new_servers), new_servers: [], c_old_new: false, c_old_new_index: nil}
        logs = Enum.drop_while(state.logs, &(&1.index >= index))
        [%Entry{index: index, term: term}|_] = logs = entries ++ logs
        %{state | logs: logs, log_info: %{last_index: index, last_term: term}}
      else
        logs = Enum.drop_while(state.logs, &(&1.index >= index))
        [%Entry{index: index, term: term}|_] = logs = entries ++ logs
        %{state | logs: logs, log_info: %{last_index: index, last_term: term}}
      end
    end
  end

  ## TODO: Ragute.Log.get_entries_from
  defp get_entries_from(index, state) do
    case Enum.split_while(state.logs, &(&1.index >= index)) do
      {entries, []} ->
        {entries, 0, 0}
      {entries, [%Entry{index: index, term: term}|_]} ->
        {entries, index, term}
    end
  end

  defp commit_logs(_, index, %{commit_index: commit_index} = state) when index <= commit_index do
    state
  end
  defp commit_logs(:leader, index, state) do
    Logger.debug("#{elem(state.me, 0)}: commit logs #{index}")
    indexes =
      state.logs
      |> Enum.drop_while(&(&1.index > index))
      |> Enum.take_while(&(&1.index > state.commit_index))
      |> Enum.reverse
      |> Enum.map(fn(entry) ->
           state.backend.exec(entry.command, state.backend_state)
           if state.client_index[entry.index] do
            :gen_fsm.reply(state.client_index[entry.index], :ok)
           end
           entry.index
         end)
    client_index = Enum.reduce(indexes, state.client_index, fn(index, acc) -> Map.delete(acc, index) end)
    if state.c_old_new_index do
      if index >= state.c_old_new_index do
        rpc = {:finish_joint_consensus}
        :gen_fsm.send_event_after(0, rpc)
      end
    end
    %{state | commit_index: index, client_index: client_index}
  end
  defp commit_logs(:learner, index, state) do
    Logger.debug("#{elem(state.me, 0)}: commit logs #{index}")
    state.logs
    |> Enum.drop_while(&(&1.index > index))
    |> Enum.take_while(&(&1.index >= state.commit_index))
    |> Enum.reverse
    |> Enum.each(&state.backend.exec(&1.command, state.backend_state))
    rpc = {:joint_consensus, index}
    send_rpc(state.leader, rpc)
    %{state | commit_index: index}
  end
  defp commit_logs(_, index, state) do
    Logger.debug("#{elem(state.me, 0)}: commit logs #{index}")
    state.logs
    |> Enum.drop_while(&(&1.index > index))
    |> Enum.take_while(&(&1.index >= state.commit_index))
    |> Enum.reverse
    |> Enum.each(&state.backend.exec(&1.command, state.backend_state))
    %{state | commit_index: index}
  end

  defp become_follower(term, state) do
    state = %{state|current_term: term, voted_for: nil}
    state = set_election_timer(state)
    state
  end

  defp become_candidate(state) do
    state = %{state|current_term: state.current_term + 1, votes: MapSet.new(), votes: MapSet.new()}
    rpc = %RequestVoteRPC{
      term: state.current_term,
      candidate_id: state.me,
      last_log_index: state.log_info.last_index,
      last_log_term: state.log_info.last_term,
      from: state.me,
    }
    broadcast(rpc, state)
    state = set_election_timer(state)
    state
  end

  defp become_leader(state) do
    state = stop_election_timer(state)
    next_index = for server <- state.servers, server != state.me, into: %{}, do: {server, state.log_info.last_index + 1}
    match_index = for server <- state.servers, server != state.me, into: %{}, do: {server, 0}
    if state.c_old_new do
      new_next_index = for server <- state.new_servers, server != state.me, into: %{}, do: {server, state.log_info.last_index + 1}
      new_match_index = for server <- state.new_servers, server != state.me, into: %{}, do: {server, 0}
      state = %{state | next_index: Map.merge(next_index, new_next_index), match_index: Map.merge(match_index, new_match_index)}
      state = set_heartbeat_timer(state)
      Logger.debug("#{elem(state.me, 0)}: become leader")
      %{state | leader: state.me, next_index: next_index, match_index: match_index, client_index: %{}}
    else
      state = set_heartbeat_timer(state)
      Logger.debug("#{elem(state.me, 0)}: become leader")
      %{state | leader: state.me, next_index: next_index, match_index: match_index, client_index: %{}}
    end
  end

  defp grant_vote(to, from, term) do
    send_rpc(to, %RequestVoteRPCReply{term: term, vote_granted: true, from: from})
  end

  defp reject_vote(to, from, term) do
    send_rpc(to, %RequestVoteRPCReply{term: term, vote_granted: false, from: from})
  end

  defp broadcast(%AppendEntriesRPC{} =rpc, state) do
    for server <- state.servers, server != state.me, do: send_rpc(server, rpc)
    for server <- state.new_servers, server != state.me, do: send_rpc(server, rpc)
  end
  defp broadcast(%RequestVoteRPC{} =rpc, state) do
    for server <- state.servers, server != state.me, do: send_rpc(server, rpc)
    if state.c_old_new do
      for server <- state.new_servers, server != state.me, do: send_rpc(server, rpc)
    end
  end

  defp send_rpc(to, message) do
    :gen_fsm.send_event(to, message)
  end

  defp stop_election_timer(state) do
    stop_timer(:election_timeout, state)
  end

  defp set_election_timer(state) do
    set_timer(:election_timeout, :rand.uniform(500) + 500, state)
  end

  defp set_heartbeat_timer(state) do
    set_timer(:heartbeat_timeout, 200, state)
  end

  @timer_ref_name %{election_timeout: :election_timer_ref,
                    heartbeat_timeout: :heartbeat_timer_ref}

  defp stop_timer(name, state) do
    ref_name = @timer_ref_name[name]
    ref = state[ref_name]
    if ref, do: :gen_fsm.cancel_timer(ref)
    %{state | ref_name => nil}
  end

  defp set_timer(name, duration, state) do
    ref_name = @timer_ref_name[name]
    ref = state[ref_name]
    if ref, do: :gen_fsm.cancel_timer(ref)
    stop_timer(name, state)
    ref = :gen_fsm.send_event_after(duration, name)
    %{state | ref_name => ref}
  end
end

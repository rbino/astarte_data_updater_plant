#
# This file is part of Astarte.
#
# Astarte is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Astarte is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Astarte.  If not, see <http://www.gnu.org/licenses/>.
#
# Copyright (C) 2018 Ispirata Srl
#

defmodule Astarte.DataUpdaterPlant.DataUpdater.Queries do
  alias Astarte.Core.CQLUtils
  alias CQEx.Client, as: DatabaseClient
  alias CQEx.Query, as: DatabaseQuery
  alias CQEx.Result, as: DatabaseResult
  require Logger

  def insert_value_into_db(
        db_client,
        :multi_interface_individual_properties_dbtable,
        device_id,
        interface_descriptor,
        endpoint_id,
        endpoint,
        path,
        nil,
        _value_timestamp,
        _reception_timestamp
      ) do
    if endpoint.allow_unset == false do
      Logger.warn("Tried to unset value on allow_unset=false mapping.")
      # TODO: should we handle this situation?
    end

    # TODO: :reception_timestamp_submillis is just a place holder right now
    unset_query =
      DatabaseQuery.new()
      |> DatabaseQuery.statement(
        "DELETE FROM #{interface_descriptor.storage} WHERE device_id=:device_id AND interface_id=:interface_id AND endpoint_id=:endpoint_id AND path=:path"
      )
      |> DatabaseQuery.put(:device_id, device_id)
      |> DatabaseQuery.put(:interface_id, interface_descriptor.interface_id)
      |> DatabaseQuery.put(:endpoint_id, endpoint_id)
      |> DatabaseQuery.put(:path, path)

    DatabaseQuery.call!(db_client, unset_query)

    :ok
  end

  def insert_value_into_db(
        db_client,
        :multi_interface_individual_properties_dbtable,
        device_id,
        interface_descriptor,
        endpoint_id,
        endpoint,
        path,
        value,
        _value_timestamp,
        reception_timestamp
      ) do
    # TODO: :reception_timestamp_submillis is just a place holder right now
    insert_query =
      DatabaseQuery.new()
      |> DatabaseQuery.statement(
        "INSERT INTO #{interface_descriptor.storage} " <>
          "(device_id, interface_id, endpoint_id, path, reception_timestamp, #{
            CQLUtils.type_to_db_column_name(endpoint.value_type)
          }) " <>
          "VALUES (:device_id, :interface_id, :endpoint_id, :path, :reception_timestamp, :value);"
      )
      |> DatabaseQuery.put(:device_id, device_id)
      |> DatabaseQuery.put(:interface_id, interface_descriptor.interface_id)
      |> DatabaseQuery.put(:endpoint_id, endpoint_id)
      |> DatabaseQuery.put(:path, path)
      |> DatabaseQuery.put(:reception_timestamp, div(reception_timestamp, 10000))
      |> DatabaseQuery.put(:reception_timestamp_submillis, rem(reception_timestamp, 10000))
      |> DatabaseQuery.put(:value, to_db_friendly_type(value))

    DatabaseQuery.call!(db_client, insert_query)

    :ok
  end

  def insert_value_into_db(
        db_client,
        :multi_interface_individual_datastream_dbtable,
        device_id,
        interface_descriptor,
        endpoint_id,
        endpoint,
        path,
        value,
        value_timestamp,
        reception_timestamp
      ) do
    # TODO: use received value_timestamp when needed
    # TODO: :reception_timestamp_submillis is just a place holder right now
    insert_query =
      DatabaseQuery.new()
      |> DatabaseQuery.statement(
        "INSERT INTO #{interface_descriptor.storage} " <>
          "(device_id, interface_id, endpoint_id, path, value_timestamp, reception_timestamp, reception_timestamp_submillis, #{
            CQLUtils.type_to_db_column_name(endpoint.value_type)
          }) " <>
          "VALUES (:device_id, :interface_id, :endpoint_id, :path, :value_timestamp, :reception_timestamp, :reception_timestamp_submillis, :value);"
      )
      |> DatabaseQuery.put(:device_id, device_id)
      |> DatabaseQuery.put(:interface_id, interface_descriptor.interface_id)
      |> DatabaseQuery.put(:endpoint_id, endpoint_id)
      |> DatabaseQuery.put(:path, path)
      |> DatabaseQuery.put(:value_timestamp, value_timestamp)
      |> DatabaseQuery.put(:reception_timestamp, div(reception_timestamp, 10000))
      |> DatabaseQuery.put(:reception_timestamp_submillis, rem(reception_timestamp, 10000))
      |> DatabaseQuery.put(:value, to_db_friendly_type(value))

    DatabaseQuery.call!(db_client, insert_query)

    :ok
  end

  def insert_value_into_db(
        db_client,
        :one_object_datastream_dbtable,
        device_id,
        interface_descriptor,
        _endpoint_id,
        _endpoint,
        _path,
        value,
        value_timestamp,
        reception_timestamp
      ) do
    # TODO: we should cache endpoints by interface_id
    endpoint_query =
      DatabaseQuery.new()
      |> DatabaseQuery.statement(
        "SELECT endpoint, value_type FROM endpoints WHERE interface_id=:interface_id;"
      )
      |> DatabaseQuery.put(:interface_id, interface_descriptor.interface_id)

    endpoint_rows = DatabaseQuery.call!(db_client, endpoint_query)

    # FIXME: new atoms are created here, we should avoid this. We need to fix our BSON decoder before, and to understand better CQEx code.
    column_atoms =
      Enum.reduce(endpoint_rows, %{}, fn endpoint, column_atoms_acc ->
        [endpoint_name] =
          endpoint[:endpoint]
          |> String.split("/")
          |> tl()

        column_name = CQLUtils.endpoint_to_db_column_name(endpoint_name)

        Map.put(column_atoms_acc, String.to_atom(endpoint_name), String.to_atom(column_name))
      end)

    {query_values, placeholders, query_columns} =
      Enum.reduce(value, {%{}, "", ""}, fn {obj_key, obj_value},
                                           {query_values_acc, placeholders_acc, query_acc} ->
        if column_atoms[obj_key] != nil do
          column_name = CQLUtils.endpoint_to_db_column_name(to_string(obj_key))

          next_query_values_acc = Map.put(query_values_acc, column_atoms[obj_key], obj_value)
          next_placeholders_acc = "#{placeholders_acc} :#{to_string(column_atoms[obj_key])},"
          next_query_acc = "#{query_acc} #{column_name}, "

          {next_query_values_acc, next_placeholders_acc, next_query_acc}
        else
          Logger.warn(
            "Unexpected object key #{inspect(obj_key)} with value #{inspect(obj_value)}"
          )

          query_values_acc
        end
      end)

    # TODO: use received value_timestamp when needed
    # TODO: :reception_timestamp_submillis is just a place holder right now
    insert_query =
      DatabaseQuery.new()
      |> DatabaseQuery.statement(
        "INSERT INTO #{interface_descriptor.storage} (device_id, #{query_columns} reception_timestamp, reception_timestamp_submillis) " <>
          "VALUES (:device_id, #{placeholders} :reception_timestamp, :reception_timestamp_submillis);"
      )
      |> DatabaseQuery.put(:device_id, device_id)
      |> DatabaseQuery.put(:value_timestamp, value_timestamp)
      |> DatabaseQuery.put(:reception_timestamp, div(reception_timestamp, 10000))
      |> DatabaseQuery.put(:reception_timestamp_submillis, rem(reception_timestamp, 10000))
      |> DatabaseQuery.merge(query_values)

    DatabaseQuery.call!(db_client, insert_query)

    :ok
  end

  def delete_property_from_db(state, db_client, interface_descriptor, endpoint_id, path) do
    delete_query =
      DatabaseQuery.new()
      |> DatabaseQuery.statement(
        "DELETE FROM #{interface_descriptor.storage} WHERE device_id=:device_id AND interface_id=:interface_id AND endpoint_id=:endpoint_id AND path=:path;"
      )
      |> DatabaseQuery.put(:device_id, state.device_id)
      |> DatabaseQuery.put(:interface_id, interface_descriptor.interface_id)
      |> DatabaseQuery.put(:endpoint_id, endpoint_id)
      |> DatabaseQuery.put(:path, path)

    DatabaseQuery.call!(db_client, delete_query)
    :ok
  end

  # TODO: copied from AppEngine, make it an api
  def retrieve_interface_row!(client, interface, major_version) do
    interface_query =
      DatabaseQuery.new()
      |> DatabaseQuery.statement(
        "SELECT name, major_version, minor_version, interface_id, type, quality, flags, storage, storage_type, automaton_transitions, automaton_accepting_states FROM interfaces" <>
          " WHERE name=:name AND major_version=:major_version"
      )
      |> DatabaseQuery.put(:name, interface)
      |> DatabaseQuery.put(:major_version, major_version)

    interface_row =
      DatabaseQuery.call!(client, interface_query)
      |> DatabaseResult.head()

    # if interface_row == :empty_dataset do
    #  Logger.warn "Device.retrieve_interface_row: interface not found. This error here means that the device has an interface that is not installed."
    #  raise InterfaceNotFoundError
    # end

    interface_row
  end

  # TODO: copied from AppEngine, make it an api
  def interface_version!(client, device_id, interface) do
    device_introspection_query =
      DatabaseQuery.new()
      |> DatabaseQuery.statement("SELECT introspection FROM devices WHERE device_id=:device_id")
      |> DatabaseQuery.put(:device_id, device_id)

    device_row =
      DatabaseQuery.call!(client, device_introspection_query)
      |> DatabaseResult.head()

    # if device_row == :empty_dataset do
    #  raise DeviceNotFoundError
    # end

    introspection =
      case device_row[:introspection] do
        :null ->
          []

        nil ->
          []

        result ->
          result
      end

    interface_tuple =
      introspection
      |> List.keyfind(interface, 0)

    case interface_tuple do
      {_interface_name, interface_major} ->
        interface_major

      nil ->
        # TODO: report device introspection here for debug purposes
        # raise InterfaceNotFoundError
        {:error, :interface_not_found}
    end
  end

  def query_previous_value(
        _db_client,
        :individual,
        :properties,
        _device_id,
        _interface_descriptor,
        _endpoint_id,
        _endpoint,
        _path
      ) do
    # TODO: implement me
    nil
  end

  def set_device_connected!(db_client, device_id, timestamp_ms, ip_address) do
    device_update_statement = """
    UPDATE devices
    SET connected=true, last_connection=:last_connection, last_seen_ip=:last_seen_ip
    WHERE device_id=:device_id
    """

    device_update_query =
      DatabaseQuery.new()
      |> DatabaseQuery.statement(device_update_statement)
      |> DatabaseQuery.put(:device_id, device_id)
      |> DatabaseQuery.put(:last_connection, timestamp_ms)
      |> DatabaseQuery.put(:last_seen_ip, ip_address)

    DatabaseQuery.call!(db_client, device_update_query)
  end

  def set_device_disconnected!(
        db_client,
        device_id,
        timestamp_ms,
        total_received_msgs,
        total_received_bytes
      ) do
    device_update_statement = """
    UPDATE devices
    SET connected=false,
        last_disconnection=:last_disconnection,
        total_received_msgs=:total_received_msgs,
        total_received_bytes=:total_received_bytes
    WHERE device_id=:device_id
    """

    device_update_query =
      DatabaseQuery.new()
      |> DatabaseQuery.statement(device_update_statement)
      |> DatabaseQuery.put(:device_id, device_id)
      |> DatabaseQuery.put(:last_disconnection, timestamp_ms)
      |> DatabaseQuery.put(:total_received_msgs, total_received_msgs)
      |> DatabaseQuery.put(:total_received_bytes, total_received_bytes)

    DatabaseQuery.call!(db_client, device_update_query)
  end

  def connect_to_db(state) do
    DatabaseClient.new!(
      List.first(Application.get_env(:cqerl, :cassandra_nodes)),
      keyspace: state.realm
    )
  end

  defp to_db_friendly_type(%Bson.UTC{ms: ms}) do
    ms
  end

  defp to_db_friendly_type(value) do
    value
  end
end

# SPDX-FileCopyrightText: 2019 ash contributors <https://github.com/ash-project/ash/graphs/contributors>
#
# SPDX-License-Identifier: MIT

defmodule Ash.Query.Operator.In do
  @moduledoc """
  left in [1, 2, 3]

  this predicate matches if the left is in the list on the right

  For comparison, this simplifies to a set of "or equals", e.g
  `{:or, {:or, {:or, left == 1}, left == 2}, left == 3}`
  """
  use Ash.Query.Operator,
    operator: :in,
    predicate?: true,
    types: [[:any, {:array, :same}]],
    # Holds the one primitive kind every member of the set shares, or nil when they don't.
    # Replacing the set has to go through the setter so that it stays true.
    struct_fields: [primitive_members: nil]

  @inspect_items_limit 10
  @dialyzer {:nowarn_function, compare: 2}

  def new(%Ash.Query.Ref{} = left, right) when is_list(right) do
    {:ok, with_right(%__MODULE__{left: left}, MapSet.new(right))}
  end

  def new(left, right), do: {:ok, %__MODULE__{left: left, right: right}}

  def can_return_nil?(%{left: left}), do: Ash.Expr.can_return_nil?(left)

  def evaluate(%{left: nil}), do: {:known, nil}
  def evaluate(%{right: nil}), do: {:known, nil}

  def evaluate(%{left: left, right: %MapSet{} = right} = op) do
    # `Comp.equal?/2` is semantic rather than structural equality — `1` equals
    # `1.0`, a `Decimal` equals the integer and the string spelling the same
    # number, an `Ash.CiString` equals a binary differing only in case — so a
    # set miss does not imply the value is absent. A set hit does imply a match,
    # though, so take it directly and only walk the members when it misses.
    # Two binaries, two atoms or two integers compare as plain terms, so when
    # the value and every member share one of those kinds a miss is final.
    {:known,
     MapSet.member?(right, left) or
       (not same_primitive?(left, Map.get(op, :primitive_members)) and
          Enum.any?(right, &Comp.equal?(&1, left)))}
  end

  def evaluate(%{left: left, right: right}) do
    {:known, Enum.any?(right, &Comp.equal?(&1, left))}
  end

  @impl Ash.Filter.Predicate
  def compare(
        %__MODULE__{left: left, right: %MapSet{} = mapset_left},
        %__MODULE__{left: left, right: %MapSet{} = mapset_right}
      ) do
    cond do
      MapSet.equal?(mapset_left, mapset_right) -> :mutually_inclusive
      semantically_disjoint?(mapset_left, mapset_right) -> :mutually_exclusive
      true -> :unknown
    end
  end

  def compare(%__MODULE__{}, %Ash.Query.Operator.Eq{right: %Ref{}}) do
    :unknown
  end

  def compare(
        %__MODULE__{left: left, right: %MapSet{} = mapset},
        %Ash.Query.Operator.Eq{left: left, right: value}
      ) do
    if semantic_member?(mapset, value) do
      :left_includes_right
    else
      :mutually_exclusive
    end
  end

  def compare(_, _) do
    :unknown
  end

  @doc false
  def with_right(%__MODULE__{} = op, %MapSet{} = right) do
    %{op | right: right, primitive_members: primitive_members(right)}
  end

  def with_right(%__MODULE__{} = op, right), do: %{op | right: right, primitive_members: nil}

  @doc false
  def primitive_members(%MapSet{} = mapset) do
    Enum.reduce_while(mapset, nil, fn member, kind ->
      case {primitive_kind(member), kind} do
        {nil, _} -> {:halt, nil}
        {member_kind, nil} -> {:cont, member_kind}
        {kind, kind} -> {:cont, kind}
        _ -> {:halt, nil}
      end
    end)
  end

  defp primitive_kind(value) when is_binary(value), do: :binary
  defp primitive_kind(value) when is_atom(value), do: :atom
  defp primitive_kind(value) when is_integer(value), do: :integer
  defp primitive_kind(_), do: nil

  defp same_primitive?(_, nil), do: false
  defp same_primitive?(value, kind), do: primitive_kind(value) == kind

  defp semantic_member?(mapset, value) do
    MapSet.member?(mapset, value) or Enum.any?(mapset, &Comp.equal?(&1, value))
  end

  defp semantically_disjoint?(mapset_left, mapset_right) do
    not Enum.any?(mapset_left, fn left ->
      Enum.any?(mapset_right, &Comp.equal?(left, &1))
    end)
  end

  def to_string(%{left: left, right: %MapSet{} = mapset}, opts) do
    import Inspect.Algebra

    list_doc =
      case Enum.split(mapset, @inspect_items_limit) do
        {left, []} -> to_doc(left, opts)
        {left, _} -> concat(to_doc(left, opts), "...")
      end

    concat([
      to_doc(left, opts),
      " in ",
      list_doc
    ])
  end

  def to_string(op, opts), do: super(op, opts)
end

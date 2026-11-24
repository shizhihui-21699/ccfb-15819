defmodule PrivacyMail.Srcset do
  @moduledoc false

  @doc """
  Maps every URL in an HTML srcset while preserving width/pixel descriptors.
  """
  def map(srcset, fun) when is_binary(srcset) and is_function(fun, 1) do
    srcset
    |> split_candidates()
    |> Enum.map(fn candidate ->
      case String.split(candidate, ~r/\s+/, trim: true) do
        [url | descriptors] ->
          mapped = fun.(url)
          Enum.join([mapped | descriptors], " ")

        [] ->
          ""
      end
    end)
    |> Enum.reject(&(&1 == ""))
    |> Enum.join(", ")
  end

  def map(other, _fun), do: other

  def map_reduce(srcset, acc, fun) when is_binary(srcset) and is_function(fun, 2) do
    candidates = split_candidates(srcset)

    {mapped, acc} =
      Enum.reduce(candidates, {[], acc}, fn candidate, {list, acc} ->
        case String.split(candidate, ~r/\s+/, trim: true) do
          [url | descriptors] ->
            {mapped_url, acc} = fun.(url, acc)
            {[Enum.join([mapped_url | descriptors], " ") | list], acc}

          [] ->
            {list, acc}
        end
      end)

    {mapped |> Enum.reverse() |> Enum.join(", "), acc}
  end

  def map_reduce(other, acc, _fun), do: {other, acc}

  defp split_candidates(srcset) do
    # Candidate URLs cannot contain unescaped whitespace; commas followed by
    # whitespace delimit candidates. This is adequate for email markup.
    srcset
    |> String.split(~r/,\s+/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end
end

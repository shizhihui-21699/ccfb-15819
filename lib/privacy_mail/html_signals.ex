defmodule PrivacyMail.HTMLSignals do
  @moduledoc """
  Extracts rendering signals from HTML attributes and inline CSS.
  """

  @tiny_max 2

  def parse_style(nil), do: %{}

  def parse_style(style) when is_binary(style) do
    style
    |> String.split(";")
    |> Enum.reduce(%{}, fn declaration, acc ->
      case String.split(declaration, ":", parts: 2) do
        [name, value] ->
          Map.put(acc, name |> String.trim() |> String.downcase(), String.trim(value))

        _ ->
          acc
      end
    end)
  end

  def parse_style(_), do: %{}

  @doc "True when width/height attributes or inline style describe a tracking-sized box."
  def tiny_box?(attrs, style_map \\ nil) do
    style_map = style_map || parse_style(attr(attrs, "style"))

    width = dimension(attr(attrs, "width")) || css_dimension(style_map["width"])
    height = dimension(attr(attrs, "height")) || css_dimension(style_map["height"])

    cond do
      width == 0 or height == 0 -> true
      width != nil and height != nil and width <= @tiny_max and height <= @tiny_max -> true
      true -> false
    end
  end

  @doc "Hidden with display:none, visibility:hidden or opacity:0."
  def hidden?(attrs, style_map \\ nil) do
    style_map = style_map || parse_style(attr(attrs, "style"))

    style_map["display"] == "none" or
      style_map["visibility"] in ["hidden", "collapse"] or
      opacity_zero?(style_map["opacity"]) or
      aria_hidden?(attrs)
  end

  @doc "Positioned far outside the viewport, a common beacon technique."
  def offscreen?(attrs, style_map \\ nil) do
    style_map = style_map || parse_style(attr(attrs, "style"))

    position = style_map["position"] in ["absolute", "fixed"]

    negative? =
      Enum.any?(["left", "top", "right", "bottom", "text-indent"], fn prop ->
        case css_dimension(style_map[prop]) do
          n when is_number(n) and n <= -999 -> true
          _ -> false
        end
      end)

    clip? = String.contains?(style_map["clip"] || "", "rect(0") or style_map["clip-path"] != nil

    position and (negative? or clip?)
  end

  def transparent_image_name?(url) when is_binary(url) do
    name = url |> URI.parse() |> Map.get(:path, "") |> Path.basename() |> String.downcase()
    name in PrivacyMail.Tracking.Rules.tracking_file_names()
  end

  def transparent_image_name?(_), do: false

  def attr(attrs, name) when is_list(attrs) do
    case List.keyfind(attrs, name, 0) do
      {^name, value} -> value
      _ -> nil
    end
  end

  def attr(_, _), do: nil

  defp aria_hidden?(attrs) do
    attr(attrs, "aria-hidden") in ["true", ""]
  end

  defp opacity_zero?(nil), do: false

  defp opacity_zero?(value) do
    case Float.parse(value) do
      {n, _} when n <= 0.01 -> true
      _ -> false
    end
  end

  defp dimension(nil), do: nil

  defp dimension(value) when is_binary(value) do
    value = value |> String.trim() |> String.trim_trailing("%")

    case Integer.parse(value) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp dimension(value) when is_integer(value), do: value
  defp dimension(_), do: nil

  defp css_dimension(nil), do: nil

  defp css_dimension(value) do
    value = String.downcase(value)

    cond do
      String.ends_with?(value, "px") -> value |> String.trim_trailing("px") |> dimension()
      Regex.match?(~r/^-?\d+$/, value) -> dimension(value)
      true -> nil
    end
  end
end

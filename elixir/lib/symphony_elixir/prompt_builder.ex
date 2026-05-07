defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from Linear issue data.
  """

  alias SymphonyElixir.{Config, PathSafety, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.Linear.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    case prompt_override(opts) do
      {:ok, prompt} ->
        prompt

      :missing ->
        render_workflow_prompt(issue, opts)

      {:error, reason} ->
        raise RuntimeError, "prompt_override_unavailable: #{inspect(reason)}"
    end
  end

  defp render_workflow_prompt(issue, opts) do
    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    template
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "issue" => issue |> Map.from_struct() |> to_solid_map()
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
  end

  defp prompt_override(opts) do
    case Config.settings() do
      {:ok, settings} -> prompt_override(opts, settings)
      {:error, _reason} -> :missing
    end
  end

  defp prompt_override(opts, settings) do
    with override_path when is_binary(override_path) <- settings.codex.prompt_override_path,
         override_path <- String.trim(override_path),
         true <- override_path != "",
         workspace when is_binary(workspace) <- Keyword.get(opts, :workspace),
         {:ok, path} <- resolve_override_path(workspace, override_path) do
      case File.read(path) do
        {:ok, body} ->
          if String.trim(body) == "", do: :missing, else: {:ok, body}

        {:error, :enoent} ->
          :missing

        {:error, reason} ->
          {:error, {:read_failed, path, reason}}
      end
    else
      false -> :missing
      nil -> :missing
      {:error, reason} -> {:error, reason}
      _other -> :missing
    end
  end

  defp resolve_override_path(workspace, override_path) do
    expanded_workspace = Path.expand(workspace)
    expanded_path = Path.expand(override_path, expanded_workspace)

    with :ok <- reject_relative_escape(expanded_path, expanded_workspace),
         {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace) do
      case PathSafety.canonicalize(expanded_path) do
        {:ok, canonical_path} ->
          if inside_workspace?(canonical_path, canonical_workspace) do
            {:ok, canonical_path}
          else
            {:error, {:prompt_override_outside_workspace, expanded_path, canonical_workspace}}
          end

        {:error, {:path_canonicalize_failed, ^expanded_path, :enoent}} ->
          {:ok, expanded_path}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp reject_relative_escape(expanded_path, expanded_workspace) do
    if inside_workspace?(expanded_path, expanded_workspace) do
      :ok
    else
      {:error, {:prompt_override_outside_workspace, expanded_path, expanded_workspace}}
    end
  end

  defp inside_workspace?(path, workspace) do
    path == workspace or String.starts_with?(path, workspace <> "/")
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end

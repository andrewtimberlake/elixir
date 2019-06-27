defmodule Module.Checker do
  def verify(module_map, _binary) do
    state = %{
      file: module_map.file,
      module: module_map.module,
      compile_opts: module_map.compile_opts,
      function: nil
    }

    module_map.definitions
    |> Enum.reverse()
    |> check_definitions(state)
    |> List.flatten()
  end

  defp check_definitions(definitions, state) do
    Enum.map(definitions, &check_definition(&1, state))
  end

  defp check_definition({function, _kind, meta, clauses}, state) do
    state = put_file_meta(%{state | function: function}, meta)
    Enum.map(clauses, &check_clause(&1, state))
  end

  defp put_file_meta(state, meta) do
    case Keyword.fetch(meta, :file) do
      {:ok, {file, _}} -> %{state | file: file}
      :error -> state
    end
  end

  defp check_clause({_meta, _args, _guards, body}, state) do
    check_body(body, state)
  end

  defp check_body({:&, _, [{:/, _, [{{:., meta, [module, fun]}, _, []}, arity]}]}, state)
       when is_atom(module) and is_atom(fun) do
    check_remote(module, fun, arity, meta, state)
  end

  defp check_body({{:., meta, [module, fun]}, _, args}, state)
       when is_atom(module) and is_atom(fun) do
    check_remote(module, fun, length(args), meta, state)
  end

  defp check_body({left, _meta, right}, state) when is_list(right) do
    [check_body(right, state), check_body(left, state)]
  end

  defp check_body({left, right}, state) do
    [check_body(right, state), check_body(left, state)]
  end

  defp check_body(list, state) when is_list(list) do
    Enum.map(list, &check_body(&1, state))
  end

  defp check_body(_other, _state) do
    []
  end

  defp check_remote(module, fun, arity, meta, state) do
    cond do
      not should_warn_undefined?(module, fun, arity, state) ->
        []

      # TODO: In the future we may want to warn for modules defined
      # in the local context
      Keyword.get(meta, :context_module, false) and state.module != module ->
        []

      # TODO: Add no_autoload
      not Code.ensure_loaded?(module) ->
        warn(meta, state, {:undefined_module, module, fun, arity})

      not function_exported?(module, fun, arity) ->
        exports = exports_for(module)
        warn(meta, state, {:undefined_function, module, fun, arity, exports})

      true ->
        []
    end
  end

  # TODO: Do not warn inside guards
  # TODO: Properly handle protocols
  defp should_warn_undefined?(_module, :__impl__, 1, _state), do: false
  defp should_warn_undefined?(:erlang, :orelse, 2, _state), do: false
  defp should_warn_undefined?(:erlang, :andalso, 2, _state), do: false

  defp should_warn_undefined?(module, fun, arity, state) do
    for(
      {:no_warn_undefined, values} <- state.compile_opts,
      value <- List.wrap(values),
      value == module or value == {module, fun, arity},
      do: :skip
    ) == []
  end

  defp exports_for(module) do
    try do
      module.__info__(:macros) ++ module.__info__(:functions)
    rescue
      _ -> module.module_info(:exports)
    end
  end

  defp warn(meta, env, message) do
    {line, file, _warning, message} =
      :elixir_errors.format_form_warn(meta, env, __MODULE__, message)

    :elixir_errors.print_warning(message)
    {file, line, message}
  end

  def format_error({:undefined_module, module, fun, arity}) do
    [
      Exception.format_mfa(module, fun, arity),
      " is undefined (module ",
      inspect(module),
      " is not available or is yet to be defined)"
    ]
  end

  def format_error({:undefined_function, module, fun, arity, exports}) do
    [
      Exception.format_mfa(module, fun, arity),
      " is undefined or private",
      UndefinedFunctionError.hint_for_loaded_module(module, fun, arity, exports)
    ]
  end
end

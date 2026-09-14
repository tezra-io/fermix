defmodule FermixChannels.ReqTestOwnershipInvariantTest do
  @moduledoc """
  `Req.Test.set_req_test_to_shared/1` may only be called from an `async: false`
  module.

  Shared mode is VM-global: `Req.Test.Ownership` records one owner pid, and every
  `Req.Test.stub/2` from any other process is then refused with
  `{:not_shared_owner, pid}`. It reverts when the owner exits, so the damage
  window is one test long — which is precisely why this is a concurrency bug and
  not a leak you can find by reading the file. An `async: false` module cannot
  overlap an `async: true` one, so confining shared mode to sync modules removes
  the window entirely.

  Written as a whole-surface invariant rather than a fix to one file: the
  offending call was a single vestigial line in `dispatcher_test.exs`
  (`async: true`), and it turned eight unrelated `media_download` tests red on
  linux-x64 while arm64 and macOS passed the same commit — same code, green five
  minutes earlier. A file added later either joins this invariant or fails it.

  Scope is the whole umbrella, not this app: shared mode is one VM-global
  setting and the suite runs every child app in one VM, so a call from
  fermix_core or fermix_web reaches the same owner slot. It is read per MODULE
  off the AST rather than per file, because a file may hold one async and one
  sync module and only the async one is a defect — a file-level text match
  cannot tell them apart, and would miss the async module sitting under a sync
  one in the same file.
  """
  use ExUnit.Case, async: true

  @shared_call "set_req_test_to_shared"

  test "shared Req.Test ownership is confined to async: false modules" do
    files = test_files()

    # Assert the corpus before asserting about it: this glob is anchored on
    # __DIR__ because `mix test` runs each child app from its own directory,
    # where a cwd-relative pattern matches nothing and the gate would pass by
    # scanning zero files.
    refute files == [], "test-file glob matched nothing — the gate would pass vacuously"

    offenders = Enum.flat_map(files, &offending_modules/1)

    assert offenders == [],
           """
           These test modules put Req.Test into VM-global shared mode while running
           concurrently, so any other async test that stubs is refused with
           {:not_shared_owner, _}:

           #{Enum.map_join(offenders, "\n", &"  - #{&1}")}

           Either drop the call (it is often vestigial — a private-mode stub already
           covers a request issued in the test process), grant the specific spawned
           process with Req.Test.allow/3, or make the module async: false.
           """
  end

  defp test_files do
    "../../../../apps/*/test/**/*_test.exs"
    |> Path.expand(__DIR__)
    |> Path.wildcard()
    |> Enum.reject(&(&1 == Path.expand(__ENV__.file)))
  end

  defp offending_modules(file) do
    file
    |> File.read!()
    |> Code.string_to_quoted!(file: file)
    |> modules()
    |> Enum.filter(fn {_name, body} -> async_module?(body) and calls_shared_mode?(body) end)
    |> Enum.map(fn {name, _body} -> "#{Path.relative_to(file, umbrella_root())} (#{name})" end)
  end

  defp modules(ast) do
    {_ast, found} =
      Macro.prewalk(ast, [], fn
        {:defmodule, _meta, [name, [{{:__block__, _, [:do]}, body}]]} = node, acc ->
          {node, [{module_name(name), body} | acc]}

        {:defmodule, _meta, [name, [do: body]]} = node, acc ->
          {node, [{module_name(name), body} | acc]}

        node, acc ->
          {node, acc}
      end)

    found
  end

  defp module_name({:__aliases__, _meta, parts}) when is_list(parts) do
    Enum.map_join(parts, ".", &to_string/1)
  end

  defp module_name(other), do: Macro.to_string(other)

  # `use ExUnit.Case` defaults to async: false, so only an explicit `async: true`
  # makes a module concurrent — and the case template may be a wrapper such as
  # ConnCase, so key on the option rather than on the module being used.
  defp async_module?(body) do
    {_ast, async?} =
      Macro.prewalk(body, false, fn
        {:use, _meta, [_case, opts]} = node, acc when is_list(opts) ->
          {node, acc or Keyword.get(opts, :async) == true}

        node, acc ->
          {node, acc}
      end)

    async?
  end

  defp calls_shared_mode?(body) do
    call = String.to_atom(@shared_call)

    {_ast, found} =
      Macro.prewalk(body, false, fn
        {{:., _meta, [_module, ^call]}, _call_meta, _args} = node, _acc -> {node, true}
        {^call, _meta, args} = node, _acc when is_list(args) -> {node, true}
        node, acc -> {node, acc}
      end)

    found
  end

  defp umbrella_root, do: Path.expand("../../../..", __DIR__)
end

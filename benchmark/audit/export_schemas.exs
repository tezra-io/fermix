# Runs with mix run --no-start; it neither starts the daemon nor reads credentials.
FermixCore.BootProfile.remember(:source)

alias FermixCore.Capabilities.Builtin

modules = FermixCore.Capabilities.BuiltinSeeder.builtin_tool_modules()
classified = MapSet.new(Builtin.classified_names())

tools =
  Map.new(modules, fn module ->
    name = module.name()
    unless MapSet.member?(classified, name), do: raise("unclassified built-in: #{name}")

    {name,
     %{
       module: inspect(module),
       description: module.description(),
       policy_class: Builtin.from_tool_module(module).policy_class,
       parameters: module.parameters()
     }}
  end)

if map_size(tools) != length(modules), do: raise("duplicate built-in tool names")
{_, os} = :os.type()
snapshot = %{schema: "fermix.audit.schemas.v1", profile: "source_test", os: os, tools: tools}
File.write!(hd(System.argv()), Jason.encode!(snapshot, pretty: true))

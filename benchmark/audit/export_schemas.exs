# Runs with mix run --no-start; it neither starts the daemon nor reads credentials.
FermixCore.BootProfile.remember(:source)

modules = FermixCore.Capabilities.BuiltinSeeder.builtin_tool_modules()

tools =
  Map.new(modules, fn module ->
    {module.name(),
     %{
       module: inspect(module),
       description: module.description(),
       parameters: module.parameters()
     }}
  end)

if map_size(tools) != length(modules), do: raise("duplicate built-in tool names")
{_, os} = :os.type()
snapshot = %{schema: "fermix.audit.schemas.v1", profile: "source_test", os: os, tools: tools}
File.write!(hd(System.argv()), Jason.encode!(snapshot, pretty: true))

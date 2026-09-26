credo_checks =
  "deps/credo/.credo.exs"
  |> Code.eval_file()
  |> get_in([Access.elem(0), :configs, Access.at(0), :checks])
  |> then(fn checks -> checks.enabled ++ checks.disabled end)

overwrite_checks = [
  {Credo.Check.Design.AliasUsage, false},
  {Credo.Check.Readability.AliasAs, false},
  {Credo.Check.Readability.NestedFunctionCalls, false},
  {Credo.Check.Readability.SinglePipe, false},
  {Credo.Check.Readability.Specs, false},
  {
    Credo.Check.Readability.StrictModuleLayout,
    order: [:shortdoc, :moduledoc, :behaviour, :alias, :use, :import, :require],
    ignore_module_attributes: [:external_resource, :doc_body, :schema]
  },
  {Credo.Check.Refactor.CondInsteadOfIfElse, false},
  {Credo.Check.Refactor.ModuleDependencies, false},
  {Credo.Check.Refactor.PipeChainStart, false},
  {Credo.Check.Consistency.UnusedVariableNames, false},
  {Credo.Check.Warning.LazyLogging, false}
]

project_checks =
  Enum.reduce(overwrite_checks, credo_checks, fn {check, config}, acc ->
    Keyword.replace!(acc, check, config)
  end)

%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: [~r"/_build/", ~r"/deps/"]
      },
      plugins: [],
      requires: [],
      strict: true,
      parse_timeout: 5000,
      color: true,
      checks: %{
        enabled: project_checks
      }
    }
  ]
}

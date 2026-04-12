%{
  configs: [
    %{
      name: "default",
      strict: true,
      checks: %{
        extra: [],
        disabled: [
          {Credo.Check.Refactor.Nesting, []},
          {Credo.Check.Refactor.CyclomaticComplexity, []},
          {Credo.Check.Refactor.CondStatements, []},
          {Credo.Check.Design.AliasUsage, []}
        ]
      }
    }
  ]
}

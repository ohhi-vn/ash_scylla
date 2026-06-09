%{
  configs: [
    %{
      name: "default",
      files: %{
        included: ["lib/", "test/"],
        excluded: []
      },
      plugins: [],
      requires: [],
      strict: true,
      parse_timeout: 5000,
      checks: [
        # Consistency checks
        {Credo.Check.Consistency.LineEndings},
        {Credo.Check.Consistency.SpaceAroundOperators},
        {Credo.Check.Consistency.SpaceInParentheses},
        {Credo.Check.Consistency.TabsOrSpaces},

        # Design checks
        {Credo.Check.Design.AliasUsage},
        {Credo.Check.Design.DuplicatedCode},
        {Credo.Check.Design.TagFIXME},
        {Credo.Check.Design.TagTODO},

        # Readability checks
        {Credo.Check.Readability.AliasOrder},
        {Credo.Check.Readability.FunctionNames},
        {Credo.Check.Readability.LargeNumbers},
        {Credo.Check.Readability.MaxLineLength, max_length: 120},
        {Credo.Check.Readability.ModuleAttributeNames},
        {Credo.Check.Readability.ModuleDoc},
        {Credo.Check.Readability.ParenthesesOnZeroArityDefs},
        {Credo.Check.Readability.PredicateFunctionNames},
        {Credo.Check.Readability.RedundantBlankLines},
        {Credo.Check.Readability.StringSigils},
        {Credo.Check.Readability.UnnecessaryAliasExpansion},
        {Credo.Check.Readability.VariableNames},

        # Refactoring checks
        {Credo.Check.Refactoring.CondStatements},
        {Credo.Check.Refactoring.CyclomaticComplexity, max_complexity: 12},
        {Credo.Check.Refactoring.FunctionArity},
        {Credo.Check.Refactoring.Nesting, max_nesting: 3},
        {Credo.Check.Refactoring.UnlessWithElse},

        # Warnings checks
        {Credo.Check.Warning.ApplicationConfigInModuleAttribute},
        {Credo.Check.Warning.DebugExpressions},
        {Credo.Check.Warning.IExPry},
        {Credo.Check.Warning.OperationOnSameLine},
        {Credo.Check.Warning.OutdatedDependency},
        {Credo.Check.Warning.UnusedEnumOperation},
        {Credo.Check.Warning.UnusedFileOperation},
        {Credo.Check.Warning.UnusedFunctionReturnValue},
        {Credo.Check.Warning.UnusedKeywordOperation},
        {Credo.Check.Warning.UnusedListOperation},
        {Credo.Check.Warning.UnusedPathOperation},
        {Credo.Check.Warning.UnusedRegexOperation},
        {Credo.Check.Warning.UnusedStringOperation},
        {Credo.Check.Warning.UnusedTupleOperation},

        # Custom checks (disable if not needed)
        # {Credo.Check.Readability.Specs},
      ]
    }
  ]
}

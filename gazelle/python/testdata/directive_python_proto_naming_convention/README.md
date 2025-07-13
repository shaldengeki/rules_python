# Directive: `python_proto_naming_convention`

This test case asserts that the `# gazelle:python_proto_naming_convention` directive
correctly:

1.  Has no effect on pre-existing `py_proto_library` when `gazelle:python_generate_proto` is disabled.
2.  Uses the default value when proto generation is on and `python_proto_naming_convention` is not set.
2.  Uses the provided naming convention when proto generation is on and `python_proto_naming_convention` is set.

[gh-3081]: https://github.com/bazel-contrib/rules_python/issues/3081

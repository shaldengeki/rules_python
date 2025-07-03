# Directive: `py_generate_proto`

This test case asserts that the `# gazelle:py_generate_proto` directive
correctly:

1.  Uses the default value when `py_generate_proto` is not set.
2.  Generates (or not) `py_proto_library` when `py_generate_proto` is set, based on whether a proto is present.
3.  Generates new `py_proto_library` with dependencies, when appropriate.
4.  Removes `py_proto_library` dependencies, when unnecessary.

[gh-2994]: https://github.com/bazel-contrib/rules_python/issues/2994

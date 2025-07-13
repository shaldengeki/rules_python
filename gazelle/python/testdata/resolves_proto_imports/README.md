# Resolves proto imports

This test asserts that Gazelle can resolve imports from `py_proto_library` targets:

1.  Generates a dependency in the default case.
2.  Uses `gazelle:resolve` to generate dependencies.
3.  Uses `python_proto_naming_convention` to generate dependencies.

[gh-1703]: https://github.com/bazel-contrib/rules_python/issues/1703

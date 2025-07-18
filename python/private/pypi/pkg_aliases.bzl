# Copyright 2024 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

"""{obj}`pkg_aliases` is a macro to generate aliases for selecting the right wheel for the right target platform.

If you see an error where the distribution selection error indicates the config setting names this
page may help to describe the naming convention and relationship between various flags and options
in `rules_python` and the error message contents.

Definitions:
:minor_version: Python interpreter minor version that the distributions are compatible with.
:suffix: Can be either empty or `_<os>_<suffix>`, which is usually used to distinguish multiple versions used for different target platforms.
:os: OS identifier that exists in `@platforms//os:<os>`.
:cpu: CPU architecture identifier that exists in `@platforms//cpu:<cpu>`.
:python_tag: The Python tag as defined by the [Python Packaging Authority][packaging_spec]. E.g. `py2.py3`, `py3`, `py311`, `cp311`.
:abi_tag: The ABI tag as defined by the [Python Packaging Authority][packaging_spec]. E.g. `none`, `abi3`, `cp311`, `cp311t`.
:platform_tag: The Platform tag as defined by the [Python Packaging Authority][packaging_spec]. E.g. `manylinux_2_17_x86_64`.
:platform_suffix: is a derivative of the `platform_tag` and is used to implement selection based on `libc` or `osx` version.

All of the config settings used by this macro are generated by
{obj}`config_settings`, for more detailed documentation on what each config
setting maps to and their precedence, refer to documentation on that page.

The first group of config settings that are as follows:

* `//_config:is_cp3<minor_version><suffix>` is used to select legacy `pip`
  based `whl` and `sdist` {obj}`whl_library` instances. Whereas other config
  settings are created when {obj}`pip.parse.experimental_index_url` is used.
* `//_config:is_cp3<minor_version>_sdist<suffix>` is for wheels built from
  `sdist` in {obj}`whl_library`.
* `//_config:is_cp3<minor_version>_py_<abi_tag>_any<suffix>` for wheels with
  `py2.py3` `python_tag` value.
* `//_config:is_cp3<minor_version>_py3_<abi_tag>_any<suffix>` for wheels with
  `py3` `python_tag` value.
* `//_config:is_cp3<minor_version>_<abi_tag>_any<suffix>` for any other wheels.
* `//_config:is_cp3<minor_version>_py_<abi_tag>_<platform_suffix>` for
  platform-specific wheels with `py2.py3` `python_tag` value.
* `//_config:is_cp3<minor_version>_py3_<abi_tag>_<platform_suffix>` for
  platform-specific wheels with `py3` `python_tag` value.
* `//_config:is_cp3<minor_version>_<abi_tag>_<platform_suffix>` for any other
  platform-specific wheels.

Note that wheels with `abi3` or `none` `abi_tag` values and `python_tag` values
other than `py2.py3` or `py3` are compatible with the python version that is
equal or higher than the one denoted in the `python_tag`. For example: `py37`
and `cp37` wheels are compatible with Python 3.7 and above and in the case of
the target python version being `3.11`, `rules_python` will use
`//_config:is_cp311_<abi_tag>_any<suffix>` config settings.

For platform-specific wheels, i.e. the ones that have their `platform_tag` as
something else than `any`, we treat them as below:
* `linux_<cpu>` tags assume that the target `libc` flavour is `glibc`, so this
  is in many ways equivalent to it being `manylinux`, but with an unspecified
  `libc` version.
* For `osx` and `linux` OSes wheel filename will be mapped to multiple config settings:
  * `osx_<cpu>` and `osx_<major_version>_<minor_version>_<cpu>` where
    `major_version` and `minor_version` are the compatible OSX versions.
  * `<many|musl>linux_<cpu>` and
    `<many|musl>linux_<major_version>_<minor_version>_<cpu>` where the version
    identifiers are the compatible libc versions.

[packaging_spec]: https://packaging.python.org/en/latest/specifications/platform-compatibility-tags/
"""

load("@bazel_skylib//lib:selects.bzl", "selects")
load("//python/private:text_util.bzl", "render")
load(
    ":labels.bzl",
    "DATA_LABEL",
    "DIST_INFO_LABEL",
    "EXTRACTED_WHEEL_FILES",
    "PY_LIBRARY_IMPL_LABEL",
    "PY_LIBRARY_PUBLIC_LABEL",
    "WHEEL_FILE_IMPL_LABEL",
    "WHEEL_FILE_PUBLIC_LABEL",
)
load(":parse_whl_name.bzl", "parse_whl_name")
load(":whl_target_platforms.bzl", "whl_target_platforms")

# This value is used as sentinel value in the alias/config setting machinery
# for libc and osx versions. If we encounter this version in this part of the
# code, then it means that we have a bug in rules_python and that we should fix
# it. It is more of an internal consistency check.
_VERSION_NONE = (0, 0)

_NO_MATCH_ERROR_TEMPLATE = """\
No matching wheel for current configuration's Python version.

The current build configuration's Python version doesn't match any of the Python
wheels available for this distribution. This distribution supports the following Python
configuration settings:
    {config_settings}

To determine the current configuration's Python version, run:
    `bazel config <config id>` (shown further below)

For the current configuration value see the debug message above that is
printing the current flag values. If you can't see the message, then re-run the
build to make it a failure instead by running the build with:
    --{current_flags}=fail

However, the command above will hide the `bazel config <config id>` message.
"""

_LABEL_NONE = Label("//python:none")
_LABEL_CURRENT_CONFIG = Label("//python/config_settings:current_config")
_LABEL_CURRENT_CONFIG_NO_MATCH = Label("//python/config_settings:is_not_matching_current_config")
_INCOMPATIBLE = "_no_matching_repository"

def pkg_aliases(
        *,
        name,
        actual,
        group_name = None,
        extra_aliases = None,
        **kwargs):
    """Create aliases for an actual package.

    Exposed only to be used from the hub repositories created by `rules_python`.

    Args:
        name: {type}`str` The name of the package.
        actual: {type}`dict[Label | tuple, str] | str` The name of the repo the
            aliases point to, or a dict of select conditions to repo names for
            the aliases to point to mapping to repositories. The keys are passed
            to bazel skylib's `selects.with_or`, so they can be tuples as well.
        group_name: {type}`str` The group name that the pkg belongs to.
        extra_aliases: {type}`list[str]` The extra aliases to be created.
        **kwargs: extra kwargs to pass to {bzl:obj}`get_filename_config_settings`.
    """
    alias = kwargs.pop("native", native).alias
    select = kwargs.pop("select", selects.with_or)

    alias(
        name = name,
        actual = ":" + PY_LIBRARY_PUBLIC_LABEL,
    )

    target_names = {
        PY_LIBRARY_PUBLIC_LABEL: PY_LIBRARY_IMPL_LABEL if group_name else PY_LIBRARY_PUBLIC_LABEL,
        WHEEL_FILE_PUBLIC_LABEL: WHEEL_FILE_IMPL_LABEL if group_name else WHEEL_FILE_PUBLIC_LABEL,
        DATA_LABEL: DATA_LABEL,
        DIST_INFO_LABEL: DIST_INFO_LABEL,
        EXTRACTED_WHEEL_FILES: EXTRACTED_WHEEL_FILES,
    } | {
        x: x
        for x in extra_aliases or []
    }

    actual = multiplatform_whl_aliases(aliases = actual, **kwargs)
    if type(actual) == type({}) and "//conditions:default" not in actual:
        alias(
            name = _INCOMPATIBLE,
            actual = select(
                {_LABEL_CURRENT_CONFIG_NO_MATCH: _LABEL_NONE},
                no_match_error = _NO_MATCH_ERROR_TEMPLATE.format(
                    config_settings = render.indent(
                        "\n".join(sorted([
                            value
                            for key in actual
                            for value in (key if type(key) == "tuple" else [key])
                        ])),
                    ).lstrip(),
                    current_flags = str(_LABEL_CURRENT_CONFIG),
                ),
            ),
            visibility = ["//visibility:private"],
            tags = ["manual"],
        )
        actual["//conditions:default"] = _INCOMPATIBLE

    for name, target_name in target_names.items():
        if type(actual) == type(""):
            _actual = "@{repo}//:{target_name}".format(
                repo = actual,
                target_name = name,
            )
        elif type(actual) == type({}):
            _actual = select(
                {
                    v: "@{repo}//:{target_name}".format(
                        repo = repo,
                        target_name = name,
                    ) if repo != _INCOMPATIBLE else repo
                    for v, repo in actual.items()
                },
            )
        else:
            fail("The `actual` arg must be a dictionary or a string")

        kwargs = {}
        if target_name.startswith("_"):
            kwargs["visibility"] = ["//_groups:__subpackages__"]

        alias(
            name = target_name,
            actual = _actual,
            **kwargs
        )

    if group_name:
        alias(
            name = PY_LIBRARY_PUBLIC_LABEL,
            actual = "//_groups:{}_pkg".format(group_name),
        )
        alias(
            name = WHEEL_FILE_PUBLIC_LABEL,
            actual = "//_groups:{}_whl".format(group_name),
        )

def _normalize_versions(name, versions):
    if not versions:
        return []

    if _VERSION_NONE in versions:
        fail("a sentinel version found in '{}', check render_pkg_aliases for bugs".format(name))

    return sorted(versions)

def multiplatform_whl_aliases(
        *,
        aliases = [],
        glibc_versions = [],
        muslc_versions = [],
        osx_versions = []):
    """convert a list of aliases from filename to config_setting ones.

    Exposed only for unit tests.

    Args:
        aliases: {type}`str | dict[struct | str, str]`: The aliases
            to process. Any aliases that have the filename set will be
            converted to a dict of config settings to repo names. The
            struct is created by {func}`whl_config_setting`.
        glibc_versions: {type}`list[tuple[int, int]]` list of versions that can be
            used in this hub repo.
        muslc_versions: {type}`list[tuple[int, int]]` list of versions that can be
            used in this hub repo.
        osx_versions: {type}`list[tuple[int, int]]` list of versions that can be
            used in this hub repo.

    Returns:
        A dict with of config setting labels to repo names or the repo name itself.
    """

    if type(aliases) == type(""):
        # We don't have any aliases, this is a repo name
        return aliases

    # TODO @aignas 2024-11-17: we might be able to use FeatureFlagInfo and some
    # code gen to create a version_lt_x target, which would allow us to check
    # if the libc version is in a particular range.
    glibc_versions = _normalize_versions("glibc_versions", glibc_versions)
    muslc_versions = _normalize_versions("muslc_versions", muslc_versions)
    osx_versions = _normalize_versions("osx_versions", osx_versions)

    ret = {}
    versioned_additions = {}
    for alias, repo in aliases.items():
        if type(alias) != "struct":
            ret[alias] = repo
            continue
        elif not (alias.filename or alias.target_platforms):
            # This is an internal consistency check
            fail("Expected to have either 'filename' or 'target_platforms' set, got: {}".format(alias))

        config_settings, all_versioned_settings = get_filename_config_settings(
            filename = alias.filename or "",
            target_platforms = alias.target_platforms,
            python_version = alias.version,
            # If we have multiple platforms but no wheel filename, lets use different
            # config settings.
            non_whl_prefix = "sdist" if alias.filename else "",
            glibc_versions = glibc_versions,
            muslc_versions = muslc_versions,
            osx_versions = osx_versions,
        )

        for setting in config_settings:
            ret["//_config" + setting] = repo

        # Now for the versioned platform config settings, we need to select one
        # that best fits the bill and if there are multiple wheels, e.g.
        # manylinux_2_17_x86_64 and manylinux_2_28_x86_64, then we need to select
        # the former when the glibc is in the range of [2.17, 2.28) and then chose
        # the later if it is [2.28, ...). If the 2.28 wheel was not present in
        # the hub, then we would need to use 2.17 for all the glibc version
        # configurations.
        #
        # Here we add the version settings to a dict where we key the range of
        # versions that the whl spans. If the wheel supports musl and glibc at
        # the same time, we do this for each supported platform, hence the
        # double dict.
        for default_setting, versioned in all_versioned_settings.items():
            versions = sorted(versioned)
            min_version = versions[0]
            max_version = versions[-1]

            versioned_additions.setdefault(default_setting, {})[(min_version, max_version)] = struct(
                repo = repo,
                settings = versioned,
            )

    versioned = {}
    for default_setting, candidates in versioned_additions.items():
        # Sort the candidates by the range of versions the span, so that we
        # start with the lowest version.
        for _, candidate in sorted(candidates.items()):
            # Set the default with the first candidate, which gives us the highest
            # compatibility. If the users want to use a higher-version than the default
            # they can configure the glibc_version flag.
            versioned.setdefault("//_config" + default_setting, candidate.repo)

            # We will be overwriting previously added entries, but that is intended.
            for _, setting in candidate.settings.items():
                versioned["//_config" + setting] = candidate.repo

    ret.update(versioned)
    return ret

def get_filename_config_settings(
        *,
        filename,
        target_platforms,
        python_version,
        glibc_versions = None,
        muslc_versions = None,
        osx_versions = None,
        non_whl_prefix = "sdist"):
    """Get the filename config settings.

    Exposed only for unit tests.

    Args:
        filename: the distribution filename (can be a whl or an sdist).
        target_platforms: list[str], target platforms in "{abi}_{os}_{cpu}" format.
        glibc_versions: list[tuple[int, int]], list of versions.
        muslc_versions: list[tuple[int, int]], list of versions.
        osx_versions: list[tuple[int, int]], list of versions.
        python_version: the python version to generate the config_settings for.
        non_whl_prefix: the prefix of the config setting when the whl we don't have
            a filename ending with ".whl".

    Returns:
        A tuple:
         * A list of config settings that are generated by ./pip_config_settings.bzl
         * The list of default version settings.
    """
    prefixes = []
    suffixes = []
    setting_supported_versions = {}

    if filename.endswith(".whl"):
        parsed = parse_whl_name(filename)
        if parsed.python_tag == "py2.py3":
            py = "py_"
        elif parsed.python_tag == "py3":
            py = "py3_"
        elif parsed.python_tag.startswith("cp"):
            py = ""
        else:
            py = "py3_"

        abi = parsed.abi_tag

        # TODO @aignas 2025-04-20: test
        abi, _, _ = abi.partition(".")

        if parsed.platform_tag == "any":
            prefixes = ["{}{}_any".format(py, abi)]
        else:
            prefixes = ["{}{}".format(py, abi)]
            suffixes = _whl_config_setting_suffixes(
                platform_tag = parsed.platform_tag,
                glibc_versions = glibc_versions,
                muslc_versions = muslc_versions,
                osx_versions = osx_versions,
                setting_supported_versions = setting_supported_versions,
            )
    else:
        prefixes = [non_whl_prefix or ""]

    py = "cp{}".format(python_version).replace(".", "")
    prefixes = [
        "{}_{}".format(py, prefix) if prefix else py
        for prefix in prefixes
    ]

    versioned = {
        ":is_{}_{}".format(prefix, suffix): {
            version: ":is_{}_{}".format(prefix, setting)
            for version, setting in versions.items()
        }
        for prefix in prefixes
        for suffix, versions in setting_supported_versions.items()
    }

    if suffixes or target_platforms or versioned:
        target_platforms = target_platforms or []
        suffixes = suffixes or [_non_versioned_platform(p) for p in target_platforms]
        return [
            ":is_{}_{}".format(prefix, suffix)
            for prefix in prefixes
            for suffix in suffixes
        ], versioned
    else:
        return [":is_{}".format(p) for p in prefixes], setting_supported_versions

def _whl_config_setting_suffixes(
        platform_tag,
        glibc_versions,
        muslc_versions,
        osx_versions,
        setting_supported_versions):
    suffixes = []
    for platform_tag in platform_tag.split("."):
        for p in whl_target_platforms(platform_tag):
            prefix = p.os
            suffix = p.cpu
            if "manylinux" in platform_tag:
                prefix = "manylinux"
                versions = glibc_versions
            elif "musllinux" in platform_tag:
                prefix = "musllinux"
                versions = muslc_versions
            elif p.os in ["linux", "windows"]:
                versions = [(0, 0)]
            elif p.os == "osx":
                versions = osx_versions
                if "universal2" in platform_tag:
                    suffix = "universal2"
            else:
                fail("Unsupported whl os: {}".format(p.os))

            default_version_setting = "{}_{}".format(prefix, suffix)
            supported_versions = {}
            for v in versions:
                if v == (0, 0):
                    suffixes.append(default_version_setting)
                elif v >= p.version:
                    supported_versions[v] = "{}_{}_{}_{}".format(
                        prefix,
                        v[0],
                        v[1],
                        suffix,
                    )
            if supported_versions:
                setting_supported_versions[default_version_setting] = supported_versions

    return suffixes

def _non_versioned_platform(p, *, strict = False):
    """A small utility function that converts 'cp311_linux_x86_64' to 'linux_x86_64'.

    This is so that we can tighten the code structure later by using strict = True.
    """
    has_abi = p.startswith("cp")
    if has_abi:
        return p.partition("_")[-1]
    elif not strict:
        return p
    else:
        fail("Expected to always have a platform in the form '{{abi}}_{{os}}_{{arch}}', got: {}".format(p))

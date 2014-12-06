%%% Mock a git resource and create an app magically for each URL submitted.
-module(mock_git_resource).
-export([mock/0, mock/1, unmock/0]).
-define(MOD, rebar_git_resource).

%%%%%%%%%%%%%%%%%
%%% Interface %%%
%%%%%%%%%%%%%%%%%

%% @doc same as `mock([])'.
mock() -> mock([]).

%% @doc Mocks a fake version of the git resource fetcher that creates
%% empty applications magically, rather than trying to download them.
%% Specific config options are explained in each of the private functions.
-spec mock(Opts) -> ok when
    Opts :: [Option],
    Option :: {update, [App]}
            | {default_vsn, Vsn}
            | {override_vsn, [{App, Vsn}]}
            | {deps, [{App, [Dep]}]},
    App :: string(),
    Dep :: {App, string(), {git, string()} | {git, string(), term()}},
    Vsn :: string().
mock(Opts) ->
    meck:new(?MOD, [no_link]),
    mock_lock(Opts),
    mock_update(Opts),
    mock_vsn(Opts),
    mock_download(Opts),
    ok.

unmock() ->
    meck:unload(?MOD).

%%%%%%%%%%%%%%%
%%% Private %%%
%%%%%%%%%%%%%%%

%% @doc creates values for a lock file. The refs are fake, but
%% tags and existing refs declared for a dependency are preserved.
mock_lock(_) ->
    meck:expect(
        ?MOD, lock,
        fun(_AppDir, Git) ->
            case Git of
                {git, Url, {tag, Ref}} -> {git, Url, {ref, Ref}};
                {git, Url, {ref, Ref}} -> {git, Url, {ref, Ref}};
                {git, Url} -> {git, Url, {ref, "fake-ref"}};
                {git, Url, _} -> {git, Url, {ref, "fake-ref"}}
            end
        end).

%% @doc The config passed to the `mock/2' function can specify which apps
%% should be updated on a per-name basis: `{update, ["App1", "App3"]}'.
mock_update(Opts) ->
    ToUpdate = proplists:get_value(update, Opts, []),
    meck:expect(
        ?MOD, needs_update,
        fun(_Dir, {git, Url, _Ref}) ->
            App = app(Url),
            lists:member(App, ToUpdate)
        end).

%% @doc Tries to fetch a version from the `*.app.src' file or otherwise
%% just returns random stuff, avoiding to check for the presence of git.
%% This probably breaks the assumption that stable references are returned.
%%
%% This function can't respect the `override_vsn' option because if the
%% .app.src file isn't there, we can't find the app name either.
mock_vsn(Opts) ->
    Default = proplists:get_value(default_vsn, Opts, "0.0.0"),
    meck:expect(
        ?MOD, make_vsn,
        fun(Dir) ->
            case filelib:wildcard("*.app.src", filename:join([Dir,"src"])) of
                [AppSrc] ->
                    {ok, App} = file:consult(AppSrc),
                    Vsn = proplists:get_value(vsn, App),
                    {plain, Vsn};
                _ ->
                    {plain, Default}
            end
        end).

%% @doc For each app to download, create a dummy app on disk instead.
%% The configuration for this one (passed in from `mock/1') includes:
%%
%% - Specify a version, branch, ref, or tag via the `{git, URL, {_, Vsn}'
%%   format to specify a path.
%% - If there is no version submitted (`{git, URL}'), the function instead
%%   reads from the `override_vsn' proplist (`{override_vsn, {"App1","1.2.3"}'),
%%   and otherwise uses the value associated with `default_vsn'.
%% - Dependencies for each application must be passed of the form:
%%   `{deps, [{"app1", [{app2, ".*", {git, ...}}]}]}' -- basically
%%   the `deps' option takes a key/value list of terms to output directly
%%   into a `rebar.config' file to describe dependencies.
mock_download(Opts) ->
    Deps = proplists:get_value(deps, Opts, []),
    Default = proplists:get_value(default_vsn, Opts, "0.0.0"),
    Overrides = proplists:get_value(override_vsn, Opts, []),
    meck:expect(
        ?MOD, download,
        fun (Dir, Git) ->
            filelib:ensure_dir(Dir),
            {git, Url, {_, Vsn}} = normalize_git(Git, Overrides, Default),
            App = app(Url),
            AppDeps = proplists:get_value(App, Deps, []),
            rebar_test_utils:create_app(
                Dir, App, Vsn,
                [element(1,D) || D  <- AppDeps]
            ),
            rebar_test_utils:create_config(Dir, [{deps, AppDeps}]),
            {ok, 'WHATEVER'}
        end).

%%%%%%%%%%%%%%%
%%% Helpers %%%
%%%%%%%%%%%%%%%
app(Path) ->
    filename:basename(Path, ".git").

normalize_git({git, Url}, Overrides, Default) ->
    Vsn = proplists:get_value(app(Url), Overrides, Default),
    {git, Url, {tag, Vsn}};
normalize_git({git, Url, Branch}, _, _) when is_list(Branch) ->
    {git, Url, {branch, Branch}};
normalize_git(Git, _, _) ->
    Git.

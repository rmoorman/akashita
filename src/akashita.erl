%% -*- coding: utf-8 -*-
%% -------------------------------------------------------------------
%%
%% Copyright (c) 2016 Nathan Fiedler
%%
%% This file is provided to you under the Apache License,
%% Version 2.0 (the "License"); you may not use this file
%% except in compliance with the License. You may obtain
%% a copy of the License at
%%
%% http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing,
%% software distributed under the License is distributed on an
%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%% KIND, either express or implied. See the License for the
%% specific language governing permissions and limitations
%% under the License.
%%
%% -------------------------------------------------------------------
%%
%% The low-level, easily testable functions.
%%
-module(akashita).

-export([is_go_time/3]).
-export([ensure_objects/3]).
-export([ensure_clone_exists/3, ensure_snapshot_exists/3]).
-export([destroy_dataset/2]).
-export([ensure_bucket_created/1, upload_object/2]).

-include_lib("kernel/include/file.hrl").
-include_lib("enenra/include/enenra.hrl").

% Determine if given time falls within upload window(s). Windows is a list
% of strings in HH:MM-HH:MM format. The hours are 24-hour. The times can
% span midnight, if needed.
is_go_time(Windows, Hour, Minute)
        when Hour >= 0 andalso Hour < 24
        andalso Minute >= 0 andalso Minute < 60 ->
    TheTime = {Hour, Minute},
    ConvertHour = fun(Str) ->
        case list_to_integer(Str) of
            X when X >= 0 andalso X < 24 -> X;
            _ -> erlang:error(badarg)
        end
    end,
    ConvertMinute = fun(Str) ->
        case list_to_integer(Str) of
            X when X >= 0 andalso X < 60 -> X;
            _ -> erlang:error(badarg)
        end
    end,
    InWindow = fun(Elem) ->
        [StartStr, EndStr] = re:split(Elem, "-", [{return, list}]),
        [StartHour, StartMin] = re:split(StartStr, ":", [{return, list}]),
        Start = {ConvertHour(StartHour), ConvertMinute(StartMin)},
        [EndHour, EndMin] = re:split(EndStr, ":", [{return, list}]),
        End = {ConvertHour(EndHour), ConvertMinute(EndMin)},
        case End < Start of
            true  -> (Start =< TheTime) or (TheTime =< End);
            false -> (Start =< TheTime) and (TheTime =< End)
        end
    end,
    lists:any(InWindow, Windows).

% Ensure the named bucket has been created.
ensure_bucket_created(BucketName) when is_list(BucketName) ->
    ensure_bucket_created(list_to_binary(BucketName));
ensure_bucket_created(BucketName) when is_binary(BucketName) ->
    case application:get_env(akashita, test_log) of
        undefined ->
            Creds = retrieve_credentials(),
            {ok, Location} = application:get_env(akashita, gcs_region),
            InBucket = #bucket{
                name = BucketName,
                location = list_to_binary(Location),
                storageClass = <<"NEARLINE">>
            },
            {ok, _Bucket} = enenra:insert_bucket(InBucket, Creds),
            lager:info("created bucket ~s", [BucketName]);
        {ok, LogFile} ->
            % in test mode, write to a log file
            {ok, IoDevice} = file:open(LogFile, [append]),
            Record = io_lib:format("bucket ~s created\n", [BucketName]),
            ok = file:write(IoDevice, list_to_binary(Record)),
            ok = file:close(IoDevice),
            lager:info("created fake bucket ~s", [BucketName])
    end.

% Upload a single file to the named bucket, retrying as needed.
upload_object(Filename, BucketName) when is_list(BucketName) ->
    upload_object(Filename, list_to_binary(BucketName));
upload_object(Filename, BucketName) when is_binary(BucketName) ->
    case application:get_env(akashita, test_log) of
        undefined ->
            Creds = retrieve_credentials(),
            {ok, #file_info{size = Size}} = file:read_file_info(Filename),
            {ok, Md5} = enenra:compute_md5(Filename),
            InObject = #object{
                name=list_to_binary(filename:basename(Filename)),
                bucket=BucketName,
                contentType = <<"application/octet-stream">>,
                md5Hash=Md5,
                size=Size
            },
            upload_object(Filename, InObject, Creds, 0);
        {ok, LogFile} ->
            % in test mode, write to a log file
            {ok, IoDevice} = file:open(LogFile, [append]),
            Record = io_lib:format("file ~s uploaded to ~s\n", [Filename, BucketName]),
            ok = file:write(IoDevice, list_to_binary(Record)),
            ok = file:close(IoDevice)
    end.

% Upload the given file using the details provided in the object, and the
% loaded credentials. Return 'ok' when successful, or {'error', Reason} if
% it fails 10 times in a row.
upload_object(_Filename, _Object, _Creds, 10) ->
    {error, retry_limit_reached};
upload_object(Filename, Object, Creds, FailedCount) ->
    case enenra:upload_file(Filename, Object, Creds) of
        {ok, _Object} -> ok;
        {error, Reason} ->
            lager:error("file ~s upload failed (temporarily), ~s", [Filename, Reason]),
            upload_object(Filename, Object, Creds, FailedCount + 1)
    end.

% Create the ZFS snapshot, if it is missing, where Name is the snapshot
% name, and Dataset is the name of the zfs dataset for which a snapshot
% will be created. Returns {ok, SnapshotName} on success.
ensure_snapshot_exists(Name, Dataset, Config) ->
    Snapshot = io_lib:format("~s@akashita:~s", [Dataset, Name]),
    case os:find_executable("zfs") of
        false ->
            lager:info("missing 'zfs' in PATH"),
            error(missing_zfs);
        ZfsBin ->
            ListPort = add_sudo_if_needed(ZfsBin, ["list", "-H", Snapshot], Config),
            case wait_for_port(ListPort, true) of
                {ok, 0} ->
                    % zfs snapshot already exists
                    ok;
                {ok, _C} ->
                    lager:info("creating zfs snapshot ~s", [Snapshot]),
                    SnapArgs = ["snapshot", "-o", "com.sun:auto-snapshot=false", Snapshot],
                    SnapPort = add_sudo_if_needed(ZfsBin, SnapArgs, Config),
                    {ok, 0} = wait_for_port(SnapPort),
                    lager:info("zfs snapshot ~s created", [Snapshot])
            end,
            {ok, Snapshot}
    end.

% Ensure that the named zfs Clone exists for the given Snapshot. Returns ok.
ensure_clone_exists(Clone, Snapshot, Config) ->
    case os:find_executable("zfs") of
        false ->
            lager:info("missing 'zfs' in PATH"),
            error(missing_zfs);
        ZfsBin ->
            ListPort = add_sudo_if_needed(ZfsBin, ["list", "-H", Clone], Config),
            case wait_for_port(ListPort, true) of
                {ok, 0} ->
                    % zfs clone already exists
                    ok;
                {ok, _C} ->
                    % create the zfs clone
                    lager:info("creating zfs clone ~s of ~s", [Clone, Snapshot]),
                    CloneArgs = [
                        "clone",
                        "-o", "com.sun:auto-snapshot=false",
                        "-p",
                        Snapshot,
                        Clone
                    ],
                    ClonePort = add_sudo_if_needed(ZfsBin, CloneArgs, Config),
                    {ok, 0} = wait_for_port(ClonePort),
                    lager:info("zfs clone ~s created", [Clone]),
                    ok
            end
    end.

% Destroy the named zfs dataset. The Config indicates if sudo is needed or
% not. Returns ok on success (raises error otherwise).
destroy_dataset(Dataset, Config) ->
    case os:find_executable("zfs") of
        false ->
            lager:info("missing 'zfs' in PATH"),
            error(missing_zfs);
        ZfsBin ->
            % destroying a dataset may require sudo
            ZfsArgs = ["destroy", Dataset],
            ZfsPort = add_sudo_if_needed(ZfsBin, ZfsArgs, Config),
            {ok, 0} = wait_for_port(ZfsPort),
            lager:info("zfs destroy ~s successful", [Dataset]),
            ok
    end.

% Ensure the objects are created for the named Bucket, with the Tag as the
% suffix of the working directory where the objects will be created. The
% Config is a proplist taken from the application configuration. Returns
% the path of the generated objects.
ensure_objects(Bucket, Tag, Config) ->
    WorkDir = proplists:get_value(tmpdir, Config),
    ObjectDir = filename:join(WorkDir, Bucket ++ "-" ++ Tag),
    CreateObjects = fun() ->
        BucketList = proplists:get_value(buckets, Config),
        BucketConf = proplists:get_value(Bucket, BucketList),
        SplitSize = proplists:get_value(split_size, Config, "64M"),
        DefaultExcludes = proplists:get_value(default_excludes, Config, []),
        create_objects(Bucket, ObjectDir, SplitSize, BucketConf, DefaultExcludes)
    end,
    EnsureObjects = fun() ->
        case file:list_dir(ObjectDir) of
            {error, enoent} ->
                ok = filelib:ensure_dir(ObjectDir),
                ok = file:make_dir(ObjectDir),
                CreateObjects();
            {ok, []} -> CreateObjects();
            {ok, _Filenames} -> ok  % files exist, nothing to do
        end
    end,
    % ensure the target directory exists, and if it is empty, create the objects
    try EnsureObjects() of
        ok -> ObjectDir
    catch
        error:Error ->
            lager:error("error creating objects: ~w", [Error]),
            os:cmd("rm -rf " ++ ObjectDir),
            error(Error)
    end.

% Produce the tar objects (split into reasonably sized files) for the list
% of 'paths' defined in the Options proplist (relative to the 'dataset'
% directory, also defined in Options), with the split files having the
% given Bucket name as a prefix. The split files will be created in the
% SplitDir directory.
create_objects(Bucket, SplitDir, SplitSize, Options, DefaultExcludes) ->
    lager:info("generating tar files..."),
    Paths = proplists:get_value(paths, Options),
    SourceDir = "/" ++ proplists:get_value(dataset, Options),
    Compress = proplists:get_bool(compress, Options),
    Exclusions = proplists:get_value(excludes, Options, DefaultExcludes),
    TarCmd = string:join(tar_cmd(SourceDir, Paths, Compress, Exclusions), " "),
    SplitCmd = string:join(split_cmd(Bucket, SplitSize), " "),
    ScriptCmd = generate_tar_split_script(TarCmd, SplitCmd, SplitDir),
    ScriptPort = erlang:open_port({spawn, ScriptCmd}, [exit_status]),
    {ok, 0} = wait_for_port(ScriptPort),
    lager:info("tar file creation complete"),
    ok.

% Generate the command to invoke tar for the given set of file paths.
tar_cmd(ChangeDir, Paths, Compress, Exclusions) ->
    Copt = case Compress of
        true -> ["-j"];
        false -> []
    end,
    Eopt = case Exclusions of
        [] -> [];
        _ -> ["--exclude " ++ E || E <- Exclusions]
    end,
    % Need the "-f -" for bsdtar, otherwise it attempts to use the default
    % tape drive device (/dev/sa0).
    ["tar", "-C", ChangeDir, "-f", "-", "-c"] ++ Copt ++ Eopt ++ Paths.

% Generate the command to invoke split, reading from standard input, and
% producing files whose names begin with the given prefix. The SplitSize
% is passed directly to the split command (e.g. "256K" is 262144 bytes).
split_cmd(Prefix, SplitSize) ->
    [
        %
        % These options should work for both GNU split and BSD split for
        % the sake of testing on various systems.
        %
        "split",
        "-d",
        % The split command fails if it runs out of suffix digits, so give
        % it enough digits to handle a large number of files.
        "-a", "5",
        "-b", SplitSize,
        "-",
        Prefix
    ].

% Generate a shell script to change to the given SplitDir, then execute the
% tar command, piping its output to the split command. Returns the path of
% the generated shell script.
generate_tar_split_script(TarCmd, SplitCmd, SplitDir) ->
    % Let the shell do the pipelining for us, as it seems rather difficult
    % to do so in Erlang, without eventually running out of memory. It
    % should use the pipestatus as its own exit code. Note that we return
    % the PIPESTATUS, which requires using bash.
    case os:find_executable("bash", "/bin:/usr/bin:/usr/local/bin") of
        false ->
            lager:info("cannot find 'bash' in /bin:/usr/bin:/usr/local/bin"),
            error(missing_bash);
        Bash ->
            Cmds = [
                "#!" ++ Bash,
                "cd " ++ SplitDir,
                TarCmd ++ " | " ++ SplitCmd,
                "exit ${PIPESTATUS[0]}",
                % ensure the last line ends with a newline
                ""
            ],
            PrivPath = code:priv_dir(akashita),
            ScriptPath = filename:join(PrivPath, "tar_split.sh"),
            {ok, IoDevice} = file:open(ScriptPath, [write]),
            ScriptText = string:join(Cmds, "\n"),
            ok = file:write(IoDevice, list_to_binary(ScriptText)),
            ok = file:close(IoDevice),
            ok = file:write_file_info(ScriptPath, #file_info{mode=8#00755}),
            ScriptPath
    end.

% Wait for the given Port to complete and return the exit code in the form
% of {ok, Status}. Any output received is written to the log. If the port
% experiences an error, returns {error, Reason}.
wait_for_port(Port) ->
    wait_for_port(Port, false).

% Wait for the given Port to complete and return the exit code in the form
% of {ok, Status}. Any output received is written to the log. If the port
% experiences an error, returns {error, Reason}. If Quiet is true, output
% from the port is ignored.
wait_for_port(Port, Quiet) when is_boolean(Quiet) ->
    receive
        {Port, {exit_status, Status}} ->
            ensure_port_closed(Port),
            {ok, Status};
        {Port, {data, Data}} ->
            if Quiet -> lager:notice("output from port ignored...");
                true -> lager:notice("received output from port: ~s", [Data])
            end,
            wait_for_port(Port, Quiet);
        {'EXIT', Port, Reason} ->
            lager:info("port ~w exited, ~w", [Port, Reason]),
            {error, Reason}
    end.

% Ensure that the given Port has been properly closed. Does nothing if the
% port is not open.
ensure_port_closed(Port) ->
    case erlang:port_info(Port) of
        undefined -> ok;
        _         -> erlang:port_close(Port)
    end.

% Opens a port to 'spawn_executable' the given Cmd (plus Args), adding
% 'sudo' if needed, based on the Config. Returns the opened port.
add_sudo_if_needed(Cmd, Args, Config) ->
    case proplists:get_bool(use_sudo, Config) of
        false ->
            erlang:open_port({spawn_executable, Cmd}, [exit_status, {args, Args}]);
        true ->
            case os:find_executable("sudo") of
                false ->
                    lager:info("missing 'sudo' in PATH"),
                    error(missing_sudo);
                SudoBin ->
                    erlang:open_port({spawn_executable, SudoBin},
                        [exit_status, {args, [Cmd] ++ Args}])
            end
    end.

% Ensure the Google Cloud application credentials have been loaded. The
% loaded credentials are returned, ready to be passed to enenra.
retrieve_credentials() ->
    case application:get_key(google_application_credentials) of
        undefined ->
            {ok, Credentials} = application:get_env(gcp_credentials),
            {ok, Creds} = enenra:load_credentials(Credentials),
            Creds;
        C -> C
    end.

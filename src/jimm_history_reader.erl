%%%
%%% Jimm history file reader.
%%% Rms is proprietary format and is specified for each vendor.
%%% Format described on the jimm forum (http://forum.jimm.net.ru/viewtopic.php?id=342).
%%% Supported Nokia and Seimens devices (tested only with Nokia 7373).
%%%
-module(jimm_history_reader).

-export([
    main/1,
    convert_file/4,
    read_file/2
]).

-record(message, {
    direction,
    author,
    text,
    date
}).

%% entry point
main(Args) ->
    OptSpecList =
    [
        {verbose      , undefined, "verbose"   , undefined         , "Verbose mode (debug will be printed)."},
        {quite        , $q       , "quite"     , undefined         , "Quite mode (only errros will be printed)."},
        {vendor       , $v       , "vendor"    , {string, "nokia"} , "Input file vendor (nokia or siemens)."},
        {output       , $o       , "output"    , string            , "Output file name."},
        {format       , $f       , "format"    , {string, "txt"}   , "Output file format (txt or csv)."}
    ],
    try
        {Options, TailArgs} = check_sucess(
            getopt:parse(OptSpecList, Args), 
            invalid_run_options
        ),

        set_log_level(
            proplists:get_value(quite  , Options, false),
            proplists:get_value(verbose, Options, false)
        ),

        InputFile = get_input_file(TailArgs),
        Format = proplists:get_value(format, Options),
        Vendor = proplists:get_value(vendor, Options),
        OutputFile = case proplists:get_value(output, Options) of
            undefined -> InputFile++"."++Format;
            V -> V
        end,

        convert_file(
            Vendor,
            Format,
            InputFile,
            OutputFile
         )
    catch
        throw:Error ->
            print_error(Error, OptSpecList),
            halt(1)
    end.

get_input_file([InputFile]) -> InputFile;
get_input_file(_          ) -> throw(invalid_run_options).


print_error(Error, OptSpecList) ->
    log(error, "~p", [Error]),
    getopt:usage(OptSpecList, ?MODULE_STRING, "input file").

convert_file(Vendor, OutputFormat, InputFile, OutputFile) ->
    try
        write_file(OutputFormat, OutputFile, read_file(Vendor, InputFile))
    catch
        _:Error ->
            log(error, "Converting error: ~p", [Error]),
            log(debug, "Stacktrace: ~p", [erlang:get_stacktrace()]),
            halt(1)
    end.

%% reading
read_file(Vendor, File) ->
    log(info, "Reading ~s file ~s...", [Vendor, File]),
    Data0 = check_sucess(file:read_file(File), {failed_to_read_input_file, File}),
    {MsgCount, Data1} = read_header(Vendor, Data0),
    lists:reverse(read_msgs(MsgCount, Data1, [])).

read_header("siemens", <<"midp-rms", _:8/binary, MsgCount:32/big-unsigned-integer, _:28/binary, Tail/binary>>) ->
    log(debug, "Siemens file header: messages count ~p", [MsgCount]),
    {MsgCount, Tail};
read_header("nokia", <<"midp-rms", _:24/binary, MsgCount:32/big-unsigned-integer, _:36/binary, Tail/binary>>) ->
    log(debug, "Nokia file header: messages count ~p", [MsgCount]),
    {MsgCount, Tail};
read_header(Type, _) when (Type == "nokia") or (Type == "siemens") ->
    throw(currupted_header);
read_header(_, _) ->
    throw(bad_vendor).

read_msgs(0, _, Acc) ->
    Acc;
read_msgs(MsgCount, Data0, Acc) ->
    {Msg, Data1} = read_msg(Data0),
    read_msgs(MsgCount - 1, Data1, [Msg|Acc]).

read_msg(<<
    MsgCount:32/big-unsigned-integer,
    _:32/big-unsigned-integer,
    DataSize:32/big-unsigned-integer,
    MsgSize:32/big-unsigned-integer,
    Data1/binary
>>) ->
    log(debug, "Message header: msg number ~p, msg size ~p, data size ~p", [MsgCount, DataSize, MsgSize]),

    FillingSize = DataSize-MsgSize-16,
    case Data1 of
        <<Msg:MsgSize/binary, _:FillingSize/binary, Data2/binary>> ->
            {parse_msg(Msg), Data2};
        <<Msg:MsgSize/binary>> ->
            {parse_msg(Msg), <<>>};
        _ ->
            throw(currupted_file)
    end;
read_msg(_) ->
    throw(currupted_file).

parse_msg(Data0) ->
    {Direction, Data1} = read_direction(Data0),
    {Author   , Data2} = read_string(Data1),
    {Text     , Data3} = read_string(Data2),
    {Date     , <<>> } = read_string(Data3),

    Msg = #message{direction=Direction, author=Author, text=Text, date=Date},
    log(debug, "Message: ~s ~s ~s: ~s", [Direction, Date, Author, Text]),
    Msg.

read_direction(<<0:8/integer, Data1/binary>>) ->
    {in, Data1};
read_direction(<<1:8/integer, Data1/binary>>) ->
    {out, Data1};
read_direction(_) ->
    throw(currupted_file).

read_string(<<Size:16/big-signed-integer, Data1/binary>>) ->
    read_string(Data1, Size);
read_string(_) ->
    throw(currupted_file).

read_string(Data0, Size) ->
    case Data0 of
        <<Str:Size/binary, Data1/binary>> ->
            {Str, Data1};
        _ ->
            throw(currupted_file)
    end.

%% writing
write_file(_, _, []) ->
    log(info, "Empty file");
write_file(Format, FileName, Msgs) ->
    log(info, "Writing ~s file ~s...", [Format, FileName]),
    Data = lists:map(fun(E) -> write_msg(Format, E) end, Msgs),
    ok = check_sucess(file:write_file(FileName, Data), {failed_to_write_output_file, FileName}).

write_msg("txt", #message{author=Author, text=Text, date=Date}) ->
    io_lib:format("~s ~s: ~s~n", [Date, Author, Text]);
write_msg("csv", #message{author=Author, text=Text, date=Date}) ->
    io_lib:format("~s;~s;~s~n", [Date, Author, Text]).


%% logging
set_log_level(QuiteMode, Verbose) ->
    set_log_level(log_level(QuiteMode, Verbose)).

set_log_level(Level) when is_atom(Level) ->
    put(gdt_log_level, Level).

log(Level, Str) ->
    log(Level, Str, []).

log(Level, Str, Args) when is_atom(Level) ->
    LogLevel = get(gdt_log_level),
    case should_log(LogLevel, Level) of
        true ->
            io:format(log_prefix(Level) ++ Str ++ "~n", Args);
        false ->
            ok
    end.

%% log_level(QuiteMode, Verbose)
log_level(true , _    ) -> error;
log_level(false, false) -> info;
log_level(false, true ) -> debug.

should_log(undefined, _) -> false;
should_log(debug, _    ) -> true;
should_log(info , debug) -> false;
should_log(info , _    ) -> true;
should_log(error, error) -> true;
should_log(_    , _    ) -> false.

log_prefix(debug) -> "DEBUG: ";
log_prefix(info ) -> "--> ";
log_prefix(error) -> "ERROR: ".

%% utils
check_sucess(ok, _) -> ok;
check_sucess({ok, V1}, _) -> V1;
check_sucess({ok, V1, V2}, _) -> {V1, V2};
check_sucess({ok, V1, V2, V3}, _) -> {V1, V2, V3};
check_sucess({error, R1}, Error) -> throw({Error, R1});
check_sucess({error, R1, R2}, Error) -> throw({Error, R1, R2});
check_sucess({error, R1, R2, R3}, Error) -> throw({Error, R1, R2, R3}).

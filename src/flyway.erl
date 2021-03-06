-module(flyway).

-compile(export_all).

-include_lib("epgsql/include/pgsql.hrl").
-define(MUTEX_GRAB_FAIL, <<"55P03">>).
-define(DUPLICATE_TABLE, <<"42P07">>).


migrate(App, PSQLConnectionOpts) when is_list(PSQLConnectionOpts) ->
    PSQLWorkerOpts = [{size, 1}],
    epgsql_poolboy:start_pool(?MODULE, PSQLWorkerOpts, PSQLConnectionOpts),
    migrate(App, ?MODULE);
migrate(App, PoolName) when is_atom(PoolName) ->
    case code:priv_dir(App) of
        {error, bad_name} ->
            {error, unknown_app};
        Path when is_list(Path) ->
            run_migrations(Path, PoolName)
    end.

run_migrations(Path, PoolName) ->
    MigrationFiles = filelib:wildcard(Path ++ "/**/migration_*.erl"),
    MigrationInTransaction =
        fun(Worker) ->
                put(pg_worker, Worker),
                LockTable = "LOCK TABLE migrations IN ACCESS EXCLUSIVE MODE NOWAIT",
                case pgsql:equery(Worker, LockTable) of
                    {ok, _, _} ->
                        try
                            err_pipe([fun sort_migrations/1,
                                      fun compile_migrations/1,
                                      fun execute_migrations/1],
                                     MigrationFiles)
                        after
                            erase(pg_worker)
                        end;
                    {error, _} = E->
                        E
                end
        end,
    ok = poolboy:transaction(PoolName, fun initialize_flyway_schema/1),
    case epgsql_poolboy:with_transaction(PoolName, MigrationInTransaction) of
        Res when element(1, Res) == ok ->
            ok;
        {error, #error{code = ?MUTEX_GRAB_FAIL}} ->
            timer:sleep(5000),
            run_migrations(Path, PoolName);
        {error, #error{code = Code}} ->
            {error, flyway_postgres_codes:code_to_atom(Code)};
        O -> O
    end.

initialize_flyway_schema(Worker) ->
    true = is_process_alive(Worker),
    FlywayPriv = code:priv_dir(flyway),
    Schema = filename:join(FlywayPriv, "schema.sql"),
    {ok, SchemaContents} = file:read_file(Schema),
    case epgsql_poolboy:equery(Worker, binary_to_list(SchemaContents)) of
        Res when element(1, Res) == ok ->
            ok;
        {error, #error{code = ?DUPLICATE_TABLE}} ->
            ok;
        {error, _} = E ->
            E
    end.

sort_migrations(Migrations) ->
    SortFn =
        fun(A, B) ->
                ADigit = extract_number(filename:basename(A)),
                BDigit = extract_number(filename:basename(B)),
                ADigit < BDigit
        end,
    {ok, lists:sort(SortFn, Migrations)}.

compile_migrations(Migrations) ->
    {ok,
     [begin
          compile:file(Migration),
          extract_mod_name(Migration)
      end || Migration <- Migrations]}.

extract_mod_name(Migration) ->
    list_to_atom(filename:basename(Migration, ".erl")).

execute_migrations(Migrations) ->
    Worker = get(pg_worker),
    [ok = run_query(Worker, Migration) || Migration <- Migrations],
    {ok, Migrations}.

run_query(Worker, Migration) ->
    case has_migration_ran(Migration) of
        true ->
            ok;
        false ->
            case pgsql:equery(Worker, Migration:forwards()) of
                {error, E} ->
                    error(E);
                %% There are multiple ok type responses :(
                Res when element(1, Res) == ok ->
                    Insert = "INSERT INTO migrations (name) VALUES($1)",
                    {ok, _} = pgsql:equery(Worker, Insert, [atom_to_list(Migration)]),
                    ok
            end
    end.

has_migration_ran(Migration) ->
    Worker = get(pg_worker),
    HasRanQuery = "SELECT * FROM migrations WHERE name = $1",
    case pgsql:equery(Worker, HasRanQuery, [Migration]) of
        {ok, _, []} ->
            false;
        {ok, _, [_]} ->
            true
    end.

err_pipe([], Val) ->
    {ok, Val};
err_pipe([Fn|Fns], Val) ->
    case Fn(Val) of
        {ok, V} ->
            err_pipe(Fns, V);
        {ok, A, B} ->
            err_pipe(Fns, {A, B});
        {error, _} = E ->
            E
    end.

extract_number(S) ->
    [_, I, _] = re:split(S, "migration_(\\d+).erl"),
    binary_to_integer(I).

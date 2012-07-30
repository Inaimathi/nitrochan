-module(board).
-behaviour(gen_server).
-include_lib("stdlib/include/qlc.hrl").

-export([start/1, stop/1]).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-export([create/0]).

-record(board, {name, description, created, max_threads=300, max_thread_size=500, 
		default_name="Anonymous", deleted_image=""}).
-record(thread, {id, board, status=active, last_update, first_comment, last_comments=[], comment_count}).
-record(comment, {id, thread, user, tripcode, body, file}).

-export([list/0, new/1, delete/2, summarize/1, default_name/1, new_thread/2, get_thread/2, reply/3]).


%%%%%%%%%%%%%%%%%%%% external API
list() -> db:do(qlc:q([X#board.name || X <- mnesia:table(board)])).

new(BoardName) ->
    {atomic, ok} = mnesia:transaction(fun () -> mnesia:write(#board{name=BoardName, created=now()}) end),
    supervisor:start_child(erl_chan_sup, erl_chan_sup:child_spec(BoardName)).

delete(Board, {image, CommentId}) -> 
    gen_server:call(Board, {delete_comment_image, CommentId});
delete(Board, Id) -> 
    case db:find(thread, #thread.id, Id) of
	false -> gen_server:call(Board, {delete_comment, Id});
	_ -> gen_server:call(Board, {delete_thread, Id})
    end.

summarize(Rec) when is_record(Rec, thread) ->
    {Rec#thread.id, Rec#thread.last_update, Rec#thread.comment_count,
     [Rec#thread.first_comment | Rec#thread.last_comments]};
summarize(Rec) when is_record(Rec, comment) ->
    {Rec#comment.id, Rec#comment.user, Rec#comment.tripcode, 
     Rec#comment.body, Rec#comment.file};
summarize({Board, ThreadId}) -> 
    gen_server:call(Board, {summarize, ThreadId});
summarize(Board) -> 
    gen_server:call(Board, summarize).

default_name(Board) -> gen_server:call(Board, default_name).
get_thread(Board, Thread) -> gen_server:call(Board, {get_thread, Thread}).
new_thread(Board, {User, Tripcode, Comment, File}) -> 
    gen_server:call(Board, {new_thread, User, Tripcode, Comment, File}).
reply(Board, Thread, {User, Tripcode, Body, File}) -> 
    gen_server:call(Board, {reply, Thread, User, Tripcode, Body, File}).

%%%%%%%%%%%%%%%%%%%% internal call handling
%%%%%%%%%% read operations
handle_call(summarize, _From, BoardName) -> 
    Res = db:do(qlc:q([summarize(X) || X <- mnesia:table(thread), X#thread.board =:= BoardName])),
    {reply, lists:sort(fun sort_threads/2, Res), BoardName};
handle_call({summarize, ThreadId}, _From, BoardName) -> 
    [Res] = db:do(qlc:q([summarize(X) || X <- mnesia:table(thread), X#thread.board =:= BoardName, X#thread.id =:= ThreadId])),
    {reply, Res, BoardName};
handle_call({get_thread, Thread}, _From, BoardName) -> 
    Res = db:do(qlc:q([summarize(X) || X <- mnesia:table(comment), X#comment.thread =:= Thread])),
    {reply, Res, BoardName};
handle_call(default_name, _From, BoardName) -> 
    [Res] = db:do(qlc:q([X#board.default_name || X <- mnesia:table(board), X#board.name =:= BoardName])),
    {reply, Res, BoardName};

%%%%%%%%%% delete operations
handle_call({delete_thread, ThreadId}, _From, BoardName) ->
    [First | Rest] = db:do(qlc:q([X || X <- mnesia:table(comment), X#comment.thread =:= ThreadId])),
    Thread = db:find(thread, #thread.id, ThreadId),
    Comm = deleted_comment(First),
    New = Thread#thread{status=deleted, first_comment=summarize(Comm), last_comments=[], comment_count=1},
    db:transaction(fun() ->
			   lists:map(fun mnesia:delete_object/1, Rest),
			   mnesia:write(Comm),
			   mnesia:write(New)
		   end),
    {reply, collect_files([First | Rest]), BoardName};
handle_call({delete_comment, CommentId}, _From, BoardName) ->
    Comment = db:find(comment, #comment.id, CommentId),
    Thread = db:find(thread, #thread.id, Comment#comment.thread),
    New = deleted_comment(Comment),
    db:transaction(fun() -> 
			   mnesia:write(replace_comment_cache(Thread, CommentId, summarize(New))),
			   mnesia:write(New) 
		   end),
    {reply, Comment#comment.file, BoardName};
handle_call({delete_comment_image, CommentId}, _From, BoardName) ->
    Comment = db:find(comment, #comment.id, CommentId),
    OldFile = Comment#comment.file,
    db:atomic_insert(Comment#comment{file=deleted}),
    {reply, OldFile, BoardName};

%%%%%%%%%% non-delete write operations
handle_call({new_thread, User, Tripcode, Body, File}, _From, BoardName) -> 
    Id = now(),
    TripHash = case Tripcode of
		   false -> false;
		   _ -> erlsha2:sha256(Tripcode)
	       end,
    Comment = #comment{id=Id, thread=Id, user=User, tripcode=TripHash, body=Body, file=File},
    Thread = #thread{id=Id, board=BoardName, last_update=Id, comment_count=1, 
		     first_comment={Id, User, TripHash, Body, File}},
    {atomic, ok} = mnesia:transaction(fun () -> mnesia:write(Thread), mnesia:write(Comment) end),
    {reply, summarize(Thread), BoardName};
handle_call({reply, ThreadId, User, Tripcode, Body, File}, _From, BoardName) -> 
    Rec = db:find(thread, #thread.id, ThreadId),
    active = Rec#thread.status,
    Id = now(),
    TripHash = case Tripcode of
		   false -> false;
		   _ -> erlsha2:sha256(Tripcode)
	       end,
    Comment = #comment{id=Id, thread=ThreadId, user=User, tripcode=TripHash, body=Body, file=File},
    LastComm = last_n(Rec#thread.last_comments, {Id, User, TripHash, Body, File}, 4),
    Updated = Rec#thread{last_update=Id,
			 comment_count=Rec#thread.comment_count + 1,
			 last_comments=LastComm},
    db:atomic_insert([Comment, Updated]),
    {reply, summarize(Comment), BoardName}.

%%%%%%%%%%%%%%%%%%%% local utility
deleted_comment(Comment) ->
    NewFile = case Comment#comment.file of
		  undefined -> undefined;
		  _ -> deleted
	      end,
    Comment#comment{user="DELETED", body=["DISREGARD THAT, I SUCK COCKS."], file=NewFile}.

last_n(List, NewElem, N) ->
    Res = lists:sublist([NewElem | lists:reverse(List)], N),
    lists:reverse(Res).

replace_comment_cache(Thread, CommentId, NewComment) ->
    Thread#thread{last_comments = lists:keyreplace(CommentId, 1, Thread#thread.last_comments, NewComment)}.

sort_threads({_, A, _, _}, {_, B, _, _}) ->
    common:now_to_seconds(A) > common:now_to_seconds(B).

collect_files(Comments) -> collect_files(Comments, []).
collect_files([], Acc) -> Acc;
collect_files([Comment | Rest], Acc) ->
    case Comment#comment.file of
	deleted -> collect_files(Rest, Acc);
	undefined -> collect_files(Rest, Acc);
	Pic -> collect_files(Rest, [Pic | Acc])
    end.

%%%%%%%%%%%%%%%%%%%% DB-related
create() -> 
    mnesia:create_table(board, [{type, ordered_set}, {disc_copies, [node()]}, {attributes, record_info(fields, board)}]),
    mnesia:create_table(thread, [{type, ordered_set}, {disc_copies, [node()]}, {attributes, record_info(fields, thread)}]),
    mnesia:create_table(comment, [{type, ordered_set}, {disc_copies, [node()]}, {attributes, record_info(fields, comment)}]).

%%%%%%%%%%%%%%%%%%%% generic actions
start(BoardName) -> gen_server:start_link({local, BoardName}, ?MODULE, BoardName, []).
stop(BoardName) -> gen_server:call(BoardName, stop).

%%%%%%%%%%%%%%%%%%%% gen_server handlers
init(BoardName) -> {ok, BoardName}.
handle_cast(_Msg, State) -> {noreply, State}.
handle_info(_Info, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

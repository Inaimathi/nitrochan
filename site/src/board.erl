-module (board).
-compile(export_all).
-include_lib("nitrogen_core/include/wf.hrl").
-include_lib("records.hrl").

main() -> #template { file="./site/templates/bare.html" }.

title() -> "Board".

body() ->
    #container_12 { 
      body=[ #grid_8 { alpha=true, prefix=2, suffix=2, omega=true, 
		       body=case re:split(wf:path_info(), "/", [{return, list}]) of
				[""] -> wf:redirect("/index");
				[Board | _] ->  inner_body(Board);
				_ -> wf:redirect("/index")
			    end}
	   ]}.

inner_body(Board) -> 
    wf:state(board, list_to_atom(Board)),
    wf:comet_global(fun () -> post_loop() end, wf:state(board)),
    Threads =  rpc:call(?BOARD_NODE, board, summarize, [wf:state(board)]),
    [ 
      #crumbs{ board=Board },
      #panel {id=messages, body=lists:map(fun element_thread_summary:from_prop/1, Threads)},
      #comment_form{}
    ].

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%% Event functions %%%
start_upload_event(image) -> ok.

collect_tripcode() ->
    case {wf:user(), util:q(txt_tripcode)} of
	{undefined, ""} -> false;
	{undefined, Trip} -> IP = lists:map(fun erlang:integer_to_list/1, tuple_to_list(wf:peer_ip())),
			     string:join([Trip | IP], ".");
	{User, _} when is_list(User) -> registered
    end.

process_comment_body(Body) -> 
    StripFn = fun (Str, Reg) -> re:replace(Str, Reg, "", [{return, list}]) end,
    Stripped = StripFn(StripFn(Body, "^[\s\n]+"), "[\s\n]+$"),
    Split = re:split(Body, "\n", [{return, list}]),
    {lists:sublist(Stripped, 250), Split}.
    

collect_comment(LocalFileName) ->
    Body = util:q(txt_comment), 
    Username = wf:coalesce([wf:user(), util:q(txt_user_name)]),
    Trip = wf:coalesce([util:q(txt_tripcode), ""]),
    case {Body, LocalFileName, length(Body) > 3000, length(Username) > 100, length(Trip) > 250} of
	{"", undefined, _, _, _} -> {false, "You need either a comment or an image"};
	{_, _, true, _, _} -> {false, "Your comment can't be longer than 3000 characters. What the fuck are you writing, a novel?"};
	{_, _, _, true, _} -> {false, "Your username can't be longer than 100 characters. And even that's excessive."};
	{_, _, _, _, true} -> {false, "Your tripcode can't be longer than 250 characters. Really, you're secure by like 132. Anything after that is wasted effort."};
	_ -> wf:session(username, Username), wf:session(tripcode, util:q(txt_tripcode)),
	     {_Preview, FinalBody} = process_comment_body(Body),
	     {Username, collect_tripcode(), FinalBody, LocalFileName}
    end.

post(Comment) ->
    Board = wf:state(board),
    Res = rpc:call(?BOARD_NODE, board, new_thread, [Board, Comment]),
    Id = proplists:get_value(id, Res),
    wf:send_global(Board, {thread, Res}),
    wf:redirect(util:uri({thread, Id})).

finish_upload_event(_Tag, undefined, _, _) ->
    %% Comment with no image (require a comment in this case)
    case collect_comment(undefined) of
	{false, Reason} -> wf:flash(Reason);
	Comment -> post(Comment)
    end;
finish_upload_event(_Tag, _OriginalFilename, LocalFile, _Node) ->
    %% Comment with image (no other fields required, but the image has to be smaller than 3MB)
    case filelib:file_size(LocalFile) < 2097152 of
	false -> wf:flash("Your file can't be larger than 2MB"), nope;
	_ -> Filename = filename:basename(LocalFile),
	     Big = filename:join(["site", "static", "images", "big", Filename]),
	     Preview = filename:join(["site", "static", "images", "preview", Filename]),
	     file:rename(LocalFile, Big),
	     os:cmd(lists:append(["convert ", Big, "[0] -resize 250x250\\> ", Preview])),
	     case collect_comment(Filename) of
		 {false, Reason} -> wf:flash(Reason);
		 Comment -> post(Comment)
	     end
    end.

post_loop() ->
    receive 
        'INIT' -> ok; %% init is sent to the first client in the comet pool. We don't care in this case.
	{thread, Thread} ->
	    [Id | _] = tuple_to_list(Thread),
	    wf:remove(util:now_to_thread_id(Id)),
	    wf:insert_top(messages, element_thread_summary:from_prop(Thread)),
	    wf:wire(util:highlight(".thread:first"));
	{thread_update, ThreadId, ThreadSummary} ->
	    wf:remove(util:now_to_thread_id(ThreadId)),
	    wf:insert_top(messages, element_thread_summary:from_prop(ThreadSummary)),
	    wf:wire(util:highlight(".thread:first"));
	{thread_moved, NewBoard} ->
	    wf:replace(breadcrumb_trail, #crumbs{ board=NewBoard, thread=wf:state(thread) }),
	    wf:wire(util:highlight(breadcrumb_trail)),
	    wf:flash(["This thread has moved to ", #link{text=NewBoard, url=util:uri({board, NewBoard})}]);
	{replace_thread, ThreadId, {moved, BoardStr}} ->
	    CssId = util:now_to_thread_id(ThreadId),
	    wf:replace(".wfid_" ++ CssId, 
		       #panel { class=[thread, moved], id=CssId,
			        body = [ #span{ class=notice, 
						body=[#link{text=util:now_to_id_string(ThreadId), 
							    url=util:uri({thread, ThreadId})},
						      " moved to ", 
						      #link{text=BoardStr, url=util:uri({board, BoardStr})}]}]});
	{replace_thread, ElemId, Elem} ->
	    wf:replace(util:now_to_thread_id(ElemId), 
		       element_thread_summary:from_prop(Elem));
	{replace_comment, ElemId, Elem} ->
	    wf:replace(util:now_to_css_id(ElemId), 
		       element_comment:from_prop(Elem))
    end,
    wf:flush(),
    post_loop().

event(_) -> ok.

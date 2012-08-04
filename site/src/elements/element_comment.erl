-module (element_comment).
-compile(export_all).
-include_lib("nitrogen_core/include/wf.hrl").
-include("records.hrl").

reflect() -> record_info(fields, comment).

from_tup({Id, Status, User, Tripcode, Body, File}) ->
    #comment{comment_id=Id, status=Status, user=User, body=Body, file=File, tripcode=Tripcode}.

render_element(Rec = #comment{status=deleted}) ->
    Id = util:now_to_css_id(Rec#comment.comment_id),
    #span {class=[comment, deleted], id=Id,
	   body=[#span{ class=notice, text="Deleted" },
		 #span{ class=comment_id, text=Id },
		 #span{ class=comment_datetime, text=util:now_to_datetime_string(Rec#comment.comment_id) },
		 #span{ show_if=wf:role(admin),
			class=admin_links,
			body=[ #link{text="Phoneix Down", postback={revive_comment, Rec#comment.comment_id}} ]},
		 #br{ class=clear }]};
render_element(Rec = #comment{}) ->
    Trip = util:trip_to_string(Rec#comment.tripcode),
    Class = ".comment ." ++ Trip,
    Id = util:now_to_css_id(Rec#comment.comment_id),
    #span {class=comment, id=Id,
	   body=[render_user(Rec#comment.tripcode, Rec#comment.user), 
		 #span{ class=[tripcode, Trip], text=Trip, 
			actions=#event{ target=Class, 
					type=mouseover, 
					actions=util:highlight()} },
		 #span{ class=comment_id, text=Id },
		 #span{ class=comment_datetime, text=util:now_to_datetime_string(Rec#comment.comment_id) },
		 #span{ show_if=wf:role(admin),
			class=admin_links,
			body=[ #link{text="Delete Comment", postback={delete_comment, Rec#comment.comment_id}},
			       #link{show_if=image_present_p(Rec#comment.file), text="Delete Image", postback={delete_image, Rec#comment.comment_id}},
			       #link{show_if=deleted_image_p(Rec#comment.file), text="Phoneix Down, Image Edition", 
				     postback={revive_image, Rec#comment.comment_id}}]},
		 #br{ class=clear },
		 render_image(Rec#comment.file),
		 render_body(Rec#comment.body),
		 #br{ class=clear }]}.

%%%%%%%%%%%%%%%%%%%% component rendering
render_user(registered, User) ->
    #span{ class=[username, registered], text=User };
render_user(_, []) ->
    #span{ class=username, text=rpc:call(?BOARD_NODE, board, default_name, [wf:state(board)]) };
render_user(_, User) ->
    #span{ class=username, text=User }.

render_body([[]]) -> "";
render_body(Body) -> 
    lists:map(fun ([]) -> #br{};
		  (P) -> #p{ text=P } 
	      end, Body).

render_image(undefined) -> "";
render_image(deleted) -> #span{ class=deleted_image, text="FILE DELETED" };
render_image({deleted, _Filename}) -> #span{ class=deleted_image, text="FILE DELETED" };
render_image(Filename) -> 
    #link{ body=#image{ image="/images/preview/" ++ Filename }, 
	   url="/images/big/" ++ Filename }.

%%%%%%%%%%%%%%%%%%%% local utility
image_present_p({deleted, _Filename}) -> false;
image_present_p(deleted) -> false;
image_present_p(undefined) -> false;
image_present_p(_) -> true.
    
deleted_image_p({deleted, _Filename}) -> true;
deleted_image_p(_) -> false.    

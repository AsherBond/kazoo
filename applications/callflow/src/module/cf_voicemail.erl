%%%-------------------------------------------------------------------
%%% @copyright (C) 2011-2014, 2600Hz INC
%%% @doc
%%% "data":{
%%%   "action":"compose"|"check"
%%%   ,"id":"vmbox_id"
%%%   // optional
%%%   ,"max_message_length":500
%%%   ,"interdigit_timeout":2000 // in milliseconds
%%% }
%%% @end
%%% @contributors
%%%   Karl Anderson
%%%   James Aimonetti
%%%-------------------------------------------------------------------
-module(cf_voicemail).

-include("../callflow.hrl").

-export([handle/2]).

-define(FOLDER_NEW, <<"new">>).
-define(FOLDER_SAVED, <<"saved">>).
-define(FOLDER_DELETED, <<"deleted">>).

-define(MAILBOX_DEFAULT_MSG_MAX_COUNT
        ,whapps_config:get_integer(?CF_CONFIG_CAT
                                   ,[<<"voicemail">>, <<"max_message_count">>]
                                   ,0
                                  )).
-define(MAILBOX_DEFAULT_MSG_MAX_LENGTH
        ,whapps_config:get_integer(?CF_CONFIG_CAT
                                   ,[<<"voicemail">>, <<"max_message_length">>]
                                   ,500
                                  )).
-define(MAILBOX_DEFAULT_MSG_MIN_SIZE
        ,whapps_config:get_integer(?CF_CONFIG_CAT
                                   ,[<<"voicemail">>, <<"min_message_size">>]
                                   ,500
                                  )).
-define(MAILBOX_DEFAULT_MSG_MAX_SIZE
        ,whapps_config:get_integer(?CF_CONFIG_CAT
                                   ,[<<"voicemail">>, <<"max_message_size">>]
                                   ,5242880
                                  )).
-define(MAILBOX_DEFAULT_BOX_NUMBER_LENGTH
        ,whapps_config:get_integer(?CF_CONFIG_CAT
                                   ,[<<"voicemail">>, <<"max_box_number_length">>]
                                   ,15
                                  )).
-define(MAILBOX_DEFAULT_VM_EXTENSION
        ,whapps_config:get(?CF_CONFIG_CAT, [<<"voicemail">>, <<"extension">>], <<"mp3">>)
       ).
-define(MAILBOX_DEFAULT_TIMEZONE
        ,whapps_config:get_binary(?CF_CONFIG_CAT, [<<"voicemail">>, <<"timezone">>], <<"America/Los_Angeles">>)
       ).
-define(MAILBOX_DEFAULT_MAX_PIN_LENGTH
        ,whapps_config:get_integer(?CF_CONFIG_CAT, [<<"voicemail">>, <<"max_pin_length">>], 6)
       ).

-record(keys, {
          %% Compose Voicemail
          operator = <<"0">>
          ,login = <<"*">>

          %% Record Review
          ,save = <<"1">>
          ,listen = <<"2">>
          ,record = <<"3">>

          %% Main Menu
          ,hear_new = <<"1">>
          ,hear_saved = <<"2">>
          ,configure = <<"5">>
          ,exit = <<"#">>

          %% Config Menu
          ,rec_unavailable  = <<"1">>
          ,rec_name = <<"2">>
          ,set_pin = <<"3">>
          ,return_main = <<"0">>

          %% Post playbak
          ,keep = <<"1">>
          ,replay = <<"2">>
          ,delete = <<"7">>
         }).
-type vm_keys() :: #keys{}.

-define(KEY_LENGTH, 1).

-record(mailbox, {
          mailbox_id :: api_binary()
          ,mailbox_number = <<>> :: binary()
          ,exists = 'false' :: boolean()
          ,skip_instructions = 'false' :: boolean()
          ,skip_greeting = 'false' :: boolean()
          ,unavailable_media :: api_binary()
          ,name_media :: api_binary()
          ,pin = <<>> :: binary()
          ,timezone = ?MAILBOX_DEFAULT_TIMEZONE :: binary()
          ,max_login_attempts = 3 :: non_neg_integer()
          ,require_pin = 'false' :: boolean()
          ,check_if_owner = 'true' :: boolean()
          ,owner_id :: api_binary()
          ,is_owner = 'false' :: boolean()
          ,is_setup = 'false' :: boolean()
          ,message_count = 0 :: non_neg_integer()
          ,max_message_count = 0 :: non_neg_integer()
          ,max_message_length :: pos_integer()
          ,min_message_length :: pos_integer()
          ,keys = #keys{} :: vm_keys()
          ,transcribe_voicemail = 'false' :: boolean()
          ,notifications :: wh_json:object()
          ,delete_after_notify = 'false' :: boolean()
          ,interdigit_timeout = whapps_call_command:default_interdigit_timeout() :: pos_integer()
         }).
-type mailbox() :: #mailbox{}.

%%--------------------------------------------------------------------
%% @public
%% @doc
%% Entry point for this module, based on the payload will either
%% connect a caller to check_voicemail or compose_voicemail.
%% @end
%%--------------------------------------------------------------------
-spec handle(wh_json:object(), whapps_call:call()) -> 'ok'.
handle(Data, Call) ->
    case wh_json:get_value(<<"action">>, Data, <<"compose">>) of
        <<"compose">> ->
            whapps_call_command:answer(Call),
            case compose_voicemail(get_mailbox(Data, Call), Call) of
                'ok' ->
                    lager:info("compose voicemail complete"),
                    cf_exe:continue(Call);
                {'branch', Flow} ->
                    lager:info("compose voicemail complete, branch to operator"),
                    cf_exe:branch(Flow, Call)
            end;
        <<"check">> ->
            whapps_call_command:answer(Call),
            check_mailbox(get_mailbox(Data, Call), Call),
            cf_exe:continue(Call);
        _ -> cf_exe:continue(Call)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec check_mailbox(mailbox(), whapps_call:call()) -> 'ok'.
check_mailbox(Box, Call) ->
    check_mailbox(Box, Call, 1).

-spec check_mailbox(mailbox(), whapps_call:call(), non_neg_integer()) -> 'ok'.
check_mailbox(#mailbox{is_setup='false'
                       ,is_owner='true'
                      }=Box, Call, _) ->
    %% If this is the owner of the mailbox calling in and it has not been setup
    %% jump right to the main menu
    lager:info("caller is the owner of this mailbox, and has not set it up yet"),
    main_menu(Box, Call);
check_mailbox(#mailbox{require_pin='false'
                       ,is_owner='true'
                      }=Box, Call, _) ->
    %% If this is the owner of the mailbox calling in and it doesn't require a pin then jump
    %% right to the main menu
    lager:info("caller is the owner of this mailbox, and requires no pin"),
    main_menu(Box, Call);
check_mailbox(#mailbox{pin = <<>>
                       ,is_owner='true'
                      }=Box, Call, _) ->
    %% If this is the owner of the mailbox calling in and it doesn't require a pin then jump
    %% right to the main menu
    lager:info("caller is the owner of this mailbox, and it has no pin"),
    main_menu(Box, Call);
check_mailbox(#mailbox{pin = <<>>
                       ,exists='true'
                       ,is_owner='false'
                      }, Call, _) ->
    %% If the caller is not the owner or the mailbox requires a pin to access it but has none set
    %% then terminate this call.
    lager:info("attempted to sign into a mailbox with no pin"),
    whapps_call_command:b_prompt(<<"vm-no_access">>, Call),
    'ok';
check_mailbox(#mailbox{max_login_attempts=MaxLoginAttempts}, Call, Loop)
  when Loop > MaxLoginAttempts ->
    %% if we have exceeded the maximum loop attempts then terminate this call
    lager:info("maximum number of invalid attempts to check mailbox"),
    _ = whapps_call_command:b_prompt(<<"vm-abort">>, Call),
    'ok';
check_mailbox(#mailbox{exists='false'}=Box, Call, Loop) ->
    %% if the callflow did not define the mailbox to check then request the mailbox ID from the user
    find_mailbox(Box, Call, Loop);
check_mailbox(#mailbox{pin=Pin
                       ,interdigit_timeout=Interdigit
                      }=Box, Call, Loop) ->
    lager:info("requesting pin number to check mailbox"),
    NoopId = whapps_call_command:prompt(<<"vm-enter_pass">>, Call),
    case whapps_call_command:collect_digits(?MAILBOX_DEFAULT_MAX_PIN_LENGTH
                                            ,whapps_call_command:default_collect_timeout()
                                            ,Interdigit
                                            ,NoopId
                                            ,Call
                                           )
    of
        {'ok', Pin} ->
            lager:info("caller entered a valid pin"),
            main_menu(Box, Call);
        {'ok', _} ->
            lager:info("invalid mailbox login"),
            _ = whapps_call_command:b_prompt(<<"vm-fail_auth">>, Call),
            check_mailbox(Box, Call, Loop + 1);
        _ -> 'ok'
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec find_mailbox(mailbox(), whapps_call:call(), non_neg_integer()) -> 'ok'.

find_mailbox(#mailbox{max_login_attempts=MaxLoginAttempts}, Call, Loop)
  when Loop > MaxLoginAttempts ->
    %% if we have exceeded the maximum loop attempts then terminate this call
    lager:info("maximum number of invalid attempts to find mailbox"),
    _ = whapps_call_command:b_prompt(<<"vm-abort">>, Call),
    'ok';
find_mailbox(#mailbox{interdigit_timeout=Interdigit}=Box, Call, Loop) ->
    lager:info("requesting mailbox number to check"),
    NoopId = whapps_call_command:prompt(<<"vm-enter_id">>, Call),
    case whapps_call_command:collect_digits(?MAILBOX_DEFAULT_BOX_NUMBER_LENGTH
                                            ,whapps_call_command:default_collect_timeout()
                                            ,Interdigit
                                            ,NoopId
                                            ,Call
                                           )
    of
        {'ok', <<>>} -> find_mailbox(Box, Call, Loop + 1);
        {'ok', Mailbox} ->
            BoxNum = try wh_util:to_integer(Mailbox) catch _:_ -> 0 end,
            %% find the voicemail box, by making a fake 'callflow data payload' we look for it now because if the
            %% caller is the owner, and the pin is not required then we skip requesting the pin
            ViewOptions = [{'key', BoxNum}],
            AccountDb = whapps_call:account_db(Call),
            case couch_mgr:get_results(AccountDb, <<"vmboxes/listing_by_mailbox">>, ViewOptions) of
                {'ok', []} ->
                    lager:info("mailbox ~s doesnt exist", [Mailbox]),
                    find_mailbox(Box, Call, Loop + 1);
                {'ok', [JObj]} ->
                    lager:info("get profile of ~p", [JObj]),
                    ReqBox = get_mailbox(wh_json:from_list([{<<"id">>, wh_json:get_value(<<"id">>, JObj)}]), Call),
                    check_mailbox(ReqBox, Call, Loop);
                {'ok', _} ->
                    lager:info("mailbox ~s is ambiguous", [Mailbox]),
                    find_mailbox(Box, Call, Loop + 1);
                _E ->
                    lager:info("failed to find mailbox ~s: ~p", [Mailbox, _E]),
                    find_mailbox(Box, Call, Loop + 1)
            end;
        _E -> lager:info("recv other: ~p", [_E])
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec compose_voicemail(mailbox(), whapps_call:call()) ->
                               'ok' | {'branch', _}.
compose_voicemail(#mailbox{check_if_owner='true'
                           ,is_owner='true'
                          }=Box, Call) ->
    lager:info("caller is the owner of this mailbox"),
    lager:info("overriding action as check (instead of compose)"),
    check_mailbox(Box, Call);
compose_voicemail(#mailbox{exists='false'}, Call) ->
    lager:info("attempted to compose voicemail for missing mailbox"),
    _ = whapps_call_command:b_prompt(<<"vm-not_available_no_voicemail">>, Call),
    'ok';
compose_voicemail(#mailbox{max_message_count=Count
                           ,message_count=Count
                          }, Call)
  when Count > 0 ->
    lager:debug("voicemail box is full, cannot hold more messages"),
    _ = whapps_call_command:b_prompt(<<"vm-mailbox_full">>, Call),
    'ok';
compose_voicemail(#mailbox{keys=#keys{login=Login
                                      ,operator=Operator
                                     }
                          }=Box, Call) ->
    lager:debug("playing mailbox greeting to caller"),
    _ = play_greeting(Box, Call),
    _ = play_instructions(Box, Call),
    _NoopId = whapps_call_command:noop(Call),
    %% timeout after 5 min for saftey, so this process cant hang around forever
    case whapps_call_command:wait_for_application_or_dtmf(<<"noop">>, 300000) of
        {'ok', _} ->
            lager:info("played greeting and instructions to caller, recording new message"),
            record_voicemail(tmp_file(), Box, Call);
        {'dtmf', Digit} ->
            _ = whapps_call_command:b_flush(Call),
            case Digit of
                Login ->
                    lager:info("caller pressed '~s', redirecting to check voicemail", [Login]),
                    check_mailbox(Box, Call);
                Operator ->
                    lager:info("caller choose to ring the operator"),
                    case cf_util:get_operator_callflow(whapps_call:account_id(Call)) of
                        {'ok', Flow} -> {'branch', Flow};
                        {'error', _R} -> record_voicemail(tmp_file(), Box, Call)
                    end;
                _Else ->
                    lager:info("caller pressed unbound '~s', skip to recording new message", [_Else]),
                    record_voicemail(tmp_file(), Box, Call)
            end;
        {'error', R} ->
            lager:info("error while playing voicemail greeting: ~p", [R])
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec play_greeting(mailbox(), whapps_call:call()) -> ne_binary() | 'ok'.
play_greeting(#mailbox{skip_greeting='true'}, _) -> 'ok';
play_greeting(#mailbox{unavailable_media='undefined'
                       ,mailbox_number=Mailbox
                      }, Call) ->
    lager:debug("mailbox has no greeting, playing the generic"),
    whapps_call_command:audio_macro([{'prompt', <<"vm-person">>}
                                     ,{'say', Mailbox}
                                     ,{'prompt', <<"vm-not_available">>}
                                    ], Call);
play_greeting(#mailbox{unavailable_media = <<"local_stream://", _/binary>> = Id}, Call) ->
    lager:info("mailbox has a greeting file on the softswitch: ~s", Id),
    whapps_call_command:play(Id, Call);
play_greeting(#mailbox{unavailable_media=Media}, Call) ->
    lager:info("streaming mailbox greeting"),
    %% TODO: change to wh_media
    whapps_call_command:play(wh_media:fetch_url(Media), Call).
%% <<$/, (whapps_call:account_db(Call))/binary, $/, Id/binary>>, Call).

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec play_instructions(mailbox(), whapps_call:call()) -> ne_binary() | 'ok'.
play_instructions(#mailbox{skip_instructions='true'}, _) -> 'ok';
play_instructions(#mailbox{skip_instructions='false'}, Call) ->
    whapps_call_command:prompt(<<"vm-record_message">>, Call).

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec record_voicemail(ne_binary(), mailbox(), whapps_call:call()) -> 'ok'.
record_voicemail(AttachmentName, #mailbox{max_message_length=MaxMessageLength}=Box, Call) ->
    Tone = wh_json:from_list([{<<"Frequencies">>, [<<"440">>]}
                              ,{<<"Duration-ON">>, <<"500">>}
                              ,{<<"Duration-OFF">>, <<"100">>}
                             ]),
    whapps_call_command:tones([Tone], Call),
    lager:info("composing new voicemail"),
    case whapps_call_command:b_record(AttachmentName, ?ANY_DIGIT, wh_util:to_binary(MaxMessageLength), Call) of
        {'ok', Msg} ->
            Length = wh_json:get_integer_value(<<"Length">>, Msg, 0),
            case review_recording(Box, Call, AttachmentName, 'true') of
                {'ok', 'record'} ->
                    record_voicemail(tmp_file(), Box, Call);
                {'ok', _Selection} ->
                    _ = new_message(Box, Call, AttachmentName, Length),
                    _ = whapps_call_command:prompt(<<"vm-saved">>, Call),
                    _ = whapps_call_command:prompt(<<"vm-thank_you">>, Call),
                    _ = timer:sleep(8000),
                    cf_exe:continue(Call);
                {'branch', Flow} ->
                    _ = new_message(Box, Call, AttachmentName, Length),
                    _ = whapps_call_command:prompt(<<"vm-saved">>, Call),
                    _ = timer:sleep(8000),
                    cf_exe:branch(Flow, Call)
            end;
        {'error', _R} ->
            lager:info("error while attempting to record a new message: ~p", [_R])
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec setup_mailbox(mailbox(), whapps_call:call()) -> mailbox().
setup_mailbox(Box, Call) ->
    lager:debug("starting voicemail configuration wizard"),
    {'ok', _} = whapps_call_command:b_prompt(<<"vm-setup_intro">>, Call),

    lager:info("prompting caller to set a pin"),
    _ = change_pin(Box, Call),

    {'ok', _} = whapps_call_command:b_prompt(<<"vm-setup_rec_greeting">>, Call),
    lager:info("prompting caller to record an unavailable greeting"),

    Box1 = record_unavailable_greeting(Box, Call, tmp_file()),
    'ok' = update_doc(<<"is_setup">>, 'true', Box1, Call),
    lager:info("voicemail configuration wizard is complete"),

    {'ok', _} = whapps_call_command:b_prompt(<<"vm-setup_complete">>, Call),
    Box1#mailbox{is_setup='true'}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec main_menu(mailbox(), whapps_call:call()) -> 'ok'.
-spec main_menu(mailbox(), whapps_call:call(), non_neg_integer()) -> 'ok'.
main_menu(#mailbox{is_setup='false'}=Box, Call) ->
    main_menu(setup_mailbox(Box, Call), Call, 1);
main_menu(Box, Call) -> main_menu(Box, Call, 1).

main_menu(Box, Call, Loop)
  when Loop > 4 ->
    %% If there have been too may loops with no action from the caller this
    %% is likely a abandonded channel, terminate
    lager:info("main menu too many invalid entries"),
    _ = unsolicited_owner_mwi_update(Box, Call),
    _ = whapps_call_command:b_prompt(<<"vm-goodbye">>, Call),
    'ok';
main_menu(#mailbox{keys=#keys{hear_new=HearNew
                               ,hear_saved=HearSaved
                               ,configure=Configure
                               ,exit=Exit
                              }
                   ,interdigit_timeout=Interdigit
                  }=Box, Call, Loop) ->
    lager:debug("playing mailbox main menu"),
    _ = whapps_call_command:b_flush(Call),
    Messages = get_messages(Box, Call),
    New = count_messages(Messages, ?FOLDER_NEW),
    Saved = count_messages(Messages, ?FOLDER_SAVED),
    lager:debug("mailbox has ~p new and ~p saved messages", [New, Saved]),
    NoopId = whapps_call_command:audio_macro(message_count_prompts(New, Saved)
                                             ++ [{'prompt', <<"vm-main_menu">>}]
                                             ,Call),
    case whapps_call_command:collect_digits(?KEY_LENGTH
                                            ,whapps_call_command:default_collect_timeout()
                                            ,Interdigit
                                            ,NoopId
                                            ,Call
                                           )
    of
        {'error', _} ->
            lager:info("error during mailbox main menu"),
            unsolicited_owner_mwi_update(Box, Call);
        {'ok', Exit} ->
            lager:info("user choose to exit voicemail menu"),
            unsolicited_owner_mwi_update(Box, Call);
        {'ok', HearNew} ->
            lager:info("playing all messages in folder: ~s", [?FOLDER_NEW]),
            Folder = get_folder(Messages, ?FOLDER_NEW),
            case play_messages(Box, Call, Folder, New) of
                'ok' -> unsolicited_owner_mwi_update(Box, Call);
                _Else -> main_menu(Box, Call)
            end;
        {'ok', HearSaved} ->
            lager:info("playing all messages in folder: ~s", [?FOLDER_SAVED]),
            Folder = get_folder(Messages, ?FOLDER_SAVED),
            case play_messages(Box, Call, Folder, Saved) of
                'ok' -> unsolicited_owner_mwi_update(Box, Call);
                _Else ->  main_menu(Box, Call)
            end;
        {'ok', Configure} ->
            lager:info("caller choose to change their mailbox configuration"),
            case config_menu(Box, Call) of
                'ok' -> unsolicited_owner_mwi_update(Box, Call);
                Else -> main_menu(Else, Call)
            end;
        _ -> main_menu(Box, Call, Loop + 1)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec message_count_prompts(integer(), integer()) -> wh_proplist().
message_count_prompts(0, 0) ->
    [{'prompt', <<"vm-no_messages">>}];
message_count_prompts(1, 0) ->
    [{'prompt', <<"vm-you_have">>}
     ,{'say', <<"1">>}
     ,{'prompt', <<"vm-new_message">>}
    ];
message_count_prompts(0, 1) ->
    [{'prompt', <<"vm-you_have">>}
     ,{'say', <<"1">>}
     ,{'prompt', <<"vm-saved_message">>}
    ];
message_count_prompts(1, 1) ->
    [{'prompt', <<"vm-you_have">>}
     ,{'say', <<"1">>}
     ,{'prompt', <<"vm-new_and">>}
     ,{'say', <<"1">>}
     ,{'prompt', <<"vm-saved_message">>}
    ];
message_count_prompts(New, 0) ->
    [{'prompt', <<"vm-you_have">>}
     ,{'say', wh_util:to_binary(New), <<"number">>}
     ,{'prompt', <<"vm-new_messages">>}
    ];
message_count_prompts(New, 1) ->
    [{'prompt', <<"vm-you_have">>}
     ,{'say', wh_util:to_binary(New), <<"number">>}
     ,{'prompt', <<"vm-new_and">>}
     ,{'say', <<"1">>}
     ,{'prompt', <<"vm-saved_message">>}
    ];
message_count_prompts(0, Saved) ->
    [{'prompt', <<"vm-you_have">>}
     ,{'say', wh_util:to_binary(Saved), <<"number">>}
     ,{'prompt', <<"vm-saved_messages">>}
    ];
message_count_prompts(1, Saved) ->
    [{'prompt', <<"vm-you_have">>}
     ,{'say', <<"1">>}
     ,{'prompt', <<"vm-new_and">>}
     ,{'say', wh_util:to_binary(Saved), <<"number">>}
     ,{'prompt', <<"vm-saved_messages">>}
    ];
message_count_prompts(New, Saved) ->
    [{'prompt', <<"vm-you_have">>}
     ,{'say', wh_util:to_binary(New), <<"number">>}
     ,{'prompt', <<"vm-new_and">>}
     ,{'say', wh_util:to_binary(Saved), <<"number">>}
     ,{'prompt', <<"vm-saved_messages">>}
    ].

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Plays back a message then the menu, and continues to loop over the
%% menu utill
%% @end
%%--------------------------------------------------------------------
-spec play_messages(mailbox(), whapps_call:call(), wh_json:objects(), non_neg_integer()) ->
                           'ok' | 'complete'.
play_messages(#mailbox{timezone=Timezone}=Box, Call, [H|T]=Messages, Count) ->
    Message = get_message(H, Call),
    lager:info("playing mailbox message ~p (~s)", [Count, Message]),
    Prompt = [{'prompt', <<"vm-message_number">>}
              ,{'say', wh_util:to_binary(Count - length(Messages) + 1), <<"number">>}
              ,{'play', Message}
              ,{'prompt', <<"vm-received">>}
              ,{'say',  get_unix_epoch(wh_json:get_value(<<"timestamp">>, H), Timezone), <<"current_date_time">>}
              ,{'prompt', <<"vm-message_menu">>}
             ],
    case message_menu(Box, Call, Prompt) of
        {'ok', 'keep'} ->
            lager:info("caller choose to save the message"),
            _ = whapps_call_command:b_prompt(<<"vm-saved">>, Call),
            set_folder(?FOLDER_SAVED, H, Box, Call),
            play_messages(Box, Call, T, Count);
        {'ok', 'delete'} ->
            lager:info("caller choose to delete the message"),
            _ = whapps_call_command:b_prompt(<<"vm-deleted">>, Call),
            set_folder(?FOLDER_DELETED, H, Box, Call),
            play_messages(Box, Call, T, Count);
        {'ok', 'return'} ->
            lager:info("caller choose to return to the main menu"),
            _ = whapps_call_command:b_prompt(<<"vm-saved">>, Call),
            set_folder(?FOLDER_SAVED, H, Box, Call),
            'complete';
        {'ok', 'replay'} ->
            lager:info("caller choose to replay"),
            play_messages(Box, Call, Messages, Count);
        {'error', _} ->
            lager:info("error during message playback")
    end;
play_messages(_, _, [], _) ->
    lager:info("all messages in folder played to caller"),
    'complete'.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Loops over the message menu after the first play back util the
%% user provides a valid option
%% @end
%%--------------------------------------------------------------------
-type message_menu_returns() :: {'ok', 'keep' | 'delete' | 'return' | 'replay'}.

-spec message_menu(mailbox(), whapps_call:call()) ->
                          {'error', 'channel_hungup' | 'channel_unbridge' | wh_json:object()} |
                          message_menu_returns().
message_menu(Box, Call) ->
    message_menu(Box, Call, [{'prompt', <<"vm-message_menu">>}]).

-spec message_menu(mailbox(), whapps_call:call(), whapps_call_command:audio_macro_prompts()) ->
                          {'error', 'channel_hungup' | 'channel_unbridge' | wh_json:object()} |
                          message_menu_returns().
message_menu(#mailbox{keys=#keys{replay=Replay
                                 ,keep=Keep
                                 ,delete=Delete
                                 ,return_main=ReturnMain
                                }
                      ,interdigit_timeout=Interdigit
                     }=Box, Call, Prompt) ->
    lager:info("playing message menu"),
    NoopId = whapps_call_command:audio_macro(Prompt, Call),
    case whapps_call_command:collect_digits(?KEY_LENGTH
                                            ,whapps_call_command:default_collect_timeout()
                                            ,Interdigit
                                            ,NoopId
                                            ,Call
                                           )
    of
        {'ok', Keep} -> {'ok', 'keep'};
        {'ok', Delete} -> {'ok', 'delete'};
        {'ok', ReturnMain} -> {'ok', 'return'};
        {'ok', Replay} -> {'ok', 'replay'};
        {'error', _}=E -> E;
        _ -> message_menu(Box, Call)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec config_menu(mailbox(), whapps_call:call()) ->
                         'ok' | mailbox().
config_menu(Box, Call) -> config_menu(Box, Call, 1).

-spec config_menu(mailbox(), whapps_call:call(), pos_integer()) ->
                         'ok' | mailbox().
config_menu(#mailbox{keys=#keys{rec_unavailable=RecUnavailable
                                ,rec_name=RecName
                                ,set_pin=SetPin
                                ,return_main=ReturnMain
                               }
                     ,interdigit_timeout=Interdigit
                    }=Box, Call, Loop)
  when Loop < 4 ->
    lager:info("playing mailbox configuration menu"),
    {'ok', _} = whapps_call_command:b_flush(Call),
    NoopId = whapps_call_command:prompt(<<"vm-settings_menu">>, Call),
    case whapps_call_command:collect_digits(?KEY_LENGTH
                                            ,whapps_call_command:default_collect_timeout()
                                            ,Interdigit
                                            ,NoopId
                                            ,Call
                                           )
    of
        {'ok', RecUnavailable} ->
            lager:info("caller choose to record their unavailable greeting"),
            case record_unavailable_greeting(Box, Call, tmp_file()) of
                'ok' -> 'ok';
                Else -> config_menu(Else, Call)
            end;
        {'ok', RecName} ->
            lager:info("caller choose to record their name"),
            case record_name(Box, Call, tmp_file()) of
                'ok' -> 'ok';
                Else -> config_menu(Else, Call)
            end;
        {'ok', SetPin} ->
            lager:info("caller choose to change their pin"),
            case change_pin(Box, Call) of
                'ok' -> 'ok';
                _Else -> config_menu(Box, Call)
            end;
        {'ok', ReturnMain} ->
            lager:info("caller choose to return to the main menu"),
            Box;
        %% Bulk delete -> delete all voicemails
        %% Reset -> delete all voicemails, greetings, name, and reset pin
        {'ok', _} -> config_menu(Box, Call, Loop + 1);
        _ -> 'ok'
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec record_unavailable_greeting(mailbox(), whapps_call:call(), ne_binary()) ->
                                         'ok' | mailbox().
record_unavailable_greeting(#mailbox{unavailable_media='undefined'}=Box, Call, AttachmentName) ->
    Media = new_media(Box, Call, <<"unavailable greeting">>),
    record_unavailable_greeting(Box#mailbox{unavailable_media=Media}, Call, AttachmentName);

record_unavailable_greeting(#mailbox{unavailable_media=Media}=Box, Call, AttachmentName) ->
    lager:info("recording unavailable greeting  as ~s", [AttachmentName]),
    Tone = wh_json:from_list([{<<"Frequencies">>, [<<"440">>]}
                              ,{<<"Duration-ON">>, <<"500">>}
                              ,{<<"Duration-OFF">>, <<"100">>}
                             ]),
    _NoopId = whapps_call_command:audio_macro([{'prompt', <<"vm-record_greeting">>}
                                               ,{'tones', [Tone]}
                                              ], Call),
    _ = whapps_call_command:b_record(AttachmentName, Call),
    case review_recording(Box, Call, AttachmentName, 'false') of
        {'ok', 'record'} ->
            record_unavailable_greeting(Box, Call, tmp_file());
        {'ok', 'save'} ->
            %% TODO: how to get media id?
            _ = store_recording(Box, Call, AttachmentName, Media),
            MediaId = wh_media:metadata_id(Media),
            'ok' = update_doc([<<"media">>, <<"unavailable">>], MediaId, Box, Call),
            _ = whapps_call_command:b_prompt(<<"vm-saved">>, Call),
            Box;
        {'ok', 'no_selection'} ->
            _ = whapps_call_command:b_prompt(<<"vm-deleted">>, Call),
            'ok';
        {'branch', _}=B -> B
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec record_name(mailbox(), whapps_call:call(), ne_binary()) ->
                         'ok' | mailbox().
record_name(#mailbox{name_media='undefined'}=Box, Call, AttachmentName) ->
    Media = new_media(Box, Call, <<"users name">>),
    record_name(Box#mailbox{name_media=Media}, Call, AttachmentName);
record_name(#mailbox{owner_id='undefined'
                     ,mailbox_id=MailboxId
                    }=Box, Call, AttachmentName) ->
    lager:info("no owner_id set on mailbox, saving recorded name id into mailbox"),
    record_name(Box, Call, AttachmentName, MailboxId);
record_name(#mailbox{owner_id=OwnerId}=Box, Call, AttachmentName) ->
    lager:info("owner_id (~s) set on mailbox, saving into owner's doc", [OwnerId]),
    record_name(Box, Call, AttachmentName, OwnerId).

-spec record_name(mailbox(), whapps_call:call(), ne_binary(), ne_binary()) ->
                         'ok' | mailbox().
record_name(#mailbox{name_media=Media}=Box, Call, AttachmentName, DocId) ->
    lager:info("recording name as ~s", [AttachmentName]),
    Tone = wh_json:from_list([{<<"Frequencies">>, [<<"440">>]}
                              ,{<<"Duration-ON">>, <<"500">>}
                              ,{<<"Duration-OFF">>, <<"100">>}
                             ]),
    _NoopId = whapps_call_command:audio_macro([{'prompt',  <<"vm-record_name">>}
                                               ,{'tones', [Tone]}
                                              ], Call),
    _ = whapps_call_command:b_record(AttachmentName, Call),
    case review_recording(Box, Call, AttachmentName, 'false') of
        {'ok', 'record'} ->
            record_name(Box, Call, tmp_file());
        {'ok', 'save'} ->
            %% TODO: how to get media id?
            _ = store_recording(Box, Call, AttachmentName, Media),
            MediaId = wh_media:metadata_id(Media),
            'ok' = update_doc(?RECORDED_NAME_KEY, MediaId, DocId, Call),
            _ = whapps_call_command:b_prompt(<<"vm-saved">>, Call),
            Box;
        {'ok', 'no_selection'} ->
            _ = whapps_call_command:b_prompt(<<"vm-deleted">>, Call),
            'ok';
        {'branch', _}=B -> B
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec change_pin(mailbox(), whapps_call:call()) -> 'ok' | mailbox().
change_pin(#mailbox{mailbox_id=Id
                    ,interdigit_timeout=Interdigit
                   }=Box, Call) ->
    lager:info("requesting new mailbox pin number"),
    try
        {'ok', Pin} = get_new_pin(Interdigit, Call),
        lager:info("collected first pin"),
        {'ok', Pin} = confirm_new_pin(Interdigit, Call),
        lager:info("collected second pin"),

        if byte_size(Pin) == 0 -> throw('pin_empty'); 'true' -> 'ok' end,
        lager:info("entered pin is not empty"),

        AccountDb = whapps_call:account_db(Call),

        {'ok', JObj} = couch_mgr:open_doc(AccountDb, Id),
        {'ok', _} = couch_mgr:save_doc(AccountDb, wh_json:set_value(<<"pin">>, Pin, JObj)),
        {'ok', _} = whapps_call_command:b_prompt(<<"vm-pin_set">>, Call),
        lager:info("updated mailbox pin number"),
        Box
    catch
        _:_ ->
            lager:info("new pin was invalid, trying again"),
            case whapps_call_command:b_prompt(<<"vm-pin_invalid">>, Call) of
                {'ok', _} -> change_pin(Box, Call);
                _ -> 'ok'
            end
    end.

-spec get_new_pin(pos_integer(), whapps_call:call()) ->
                         {'ok', binary()}.
get_new_pin(Interdigit, Call) ->
    NoopId = whapps_call_command:prompt(<<"vm-enter_new_pin">>, Call),
    collect_pin(Interdigit, Call, NoopId).

-spec confirm_new_pin(pos_integer(), whapps_call:call()) ->
                         {'ok', binary()}.
confirm_new_pin(Interdigit, Call) ->
    NoopId = whapps_call_command:prompt(<<"vm-enter_new_pin_confirm">>, Call),
    collect_pin(Interdigit, Call, NoopId).

-spec collect_pin(pos_integer(), whapps_call:call(), ne_binary()) ->
                         {'ok', binary()}.
collect_pin(Interdigit, Call, NoopId) ->
    whapps_call_command:collect_digits(?MAILBOX_DEFAULT_MAX_PIN_LENGTH
                                       ,whapps_call_command:default_collect_timeout()
                                       ,Interdigit
                                       ,NoopId
                                       ,Call
                                      ).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec new_message(mailbox(), whapps_call:call(), ne_binary(), pos_integer()) -> any().
new_message(Box, Call, AttachmentName, Length) ->
    lager:debug("saving new ~bms voicemail message and metadata", [Length]),
    Media = new_media(Box, Call, <<"message">>),
    case store_recording(Box, Call, AttachmentName, Media) of
        'true' -> update_mailbox(Box, Call, Media, Length);
        'false' -> wh_media:delete(Media)
    end.

-spec update_mailbox(mailbox(), whapps_call:call(), ne_binary(), integer()) ->
                            'ok'.
update_mailbox(#mailbox{mailbox_id=MailboxId
                        ,mailbox_number=MailboxNumber
                        ,transcribe_voicemail=MaybeTranscribe
                       }=Box, Call, Media, Length) ->
%%    Transcription = maybe_transcribe(Call, MediaId, MaybeTranscribe),
    VoicemailName = wh_json:get_value(<<"name">>, wh_media:metadata(Media)),
    Prop = props:filter_undefined(
             [{<<"From-User">>, whapps_call:from_user(Call)}
              ,{<<"From-Realm">>, whapps_call:from_realm(Call)}
              ,{<<"To-User">>, whapps_call:to_user(Call)}
              ,{<<"To-Realm">>, whapps_call:to_realm(Call)}
              ,{<<"Caller-ID-Number">>, whapps_call:caller_id_number(Call)}
              ,{<<"Caller-ID-Name">>, whapps_call:caller_id_name(Call)}
              ,{<<"Call-ID">>, whapps_call:call_id(Call)}
              ,{<<"Account-DB">>, whapps_call:account_db(Call)}
              ,{<<"Account-ID">>, whapps_call:account_id(Call)}
              ,{<<"Voicemail-Timestamp">>, new_timestamp()}
              ,{<<"Voicemail-Name">>, VoicemailName}
              ,{<<"Voicemail-Length">>, Length}
%%              ,{<<"Voicemail-Transcription">>, Transcription}
              ,{<<"Voicemail-Box">>, MailboxId}
              ,{<<"Voicemail-Box-Number">>, MailboxNumber}
              | wh_api:default_headers(?APP_NAME, ?APP_VERSION)
             ]
            ),
    _ = case whapps_util:amqp_pool_request(Prop
                                           ,fun wapi_notifications:publish_voicemail/1
                                           ,fun wapi_notifications:notify_update_v/1
                                           ,15000
                                          )
        of
            {'ok', UpdateJObj} ->
                maybe_save_meta(Box, Call, Media, Length, UpdateJObj);
            {'error', _E} ->
                lager:debug("notification error: ~p", [_E]),
                save_meta(Box, Call, Media, Length)
        end,
    timer:sleep(2500),
    _ = unsolicited_owner_mwi_update(Box, Call),
    'ok'.

maybe_save_meta(#mailbox{delete_after_notify='false'}=Box
                ,Call, Media, Length, _UpdateJObj) ->
    save_meta(Box, Call, Media, Length);
maybe_save_meta(#mailbox{delete_after_notify='true'}=Box
                ,Call, Media, Length, UpdateJObj) ->
    case wh_json:get_value(<<"Status">>, UpdateJObj) of
        <<"completed">> ->
            lager:debug("attachment was sent out via notification, deleting media file"),
            wh_media:delete(Media);
        <<"failed">> ->
            lager:debug("attachment failed to send out via notification: ~s"
                        ,[wh_json:get_value(<<"Failure-Message">>, UpdateJObj)]),
            save_meta(Box, Call, Media, Length)
    end.

save_meta(#mailbox{mailbox_id=MailboxId}, Call, Media, Length) ->
    Metadata = wh_json:from_list(
                 [{<<"timestamp">>, new_timestamp()}
                  ,{<<"from">>, whapps_call:from(Call)}
                  ,{<<"to">>, whapps_call:to(Call)}
                  ,{<<"caller_id_number">>, whapps_call:caller_id_number(Call)}
                  ,{<<"caller_id_name">>, whapps_call:caller_id_name(Call)}
                  ,{<<"call_id">>, whapps_call:call_id(Call)}
                  ,{<<"folder">>, ?FOLDER_NEW}
                  ,{<<"length">>, Length}
                  ,{<<"media_id">>, wh_media:metadata_id(Media)}
                 ]),
    {'ok', _BoxJObj} = save_metadata(Metadata, whapps_call:account_db(Call), MailboxId),
    lager:debug("stored voicemail metadata for ~s", [MailboxId]).

-spec maybe_transcribe(whapps_call:call(), ne_binary(), boolean()) ->
                              api_object().
maybe_transcribe(Call, MediaId, 'true') ->
    Db = whapps_call:account_db(Call),
    {'ok', MediaDoc} = couch_mgr:open_doc(Db, MediaId),
    case wh_json:get_value(<<"_attachments">>, MediaDoc, []) of
        [] ->
            lager:warning("no audio attachments on media doc ~s: ~p", [MediaId, MediaDoc]),
            'undefined';
        Attachments ->
            {Attachment, MetaData} = hd(wh_json:to_proplist(Attachments)),
            case couch_mgr:fetch_attachment(Db, MediaId, Attachment) of
                {'ok', Bin} ->
                    lager:info("transcribing first attachment ~s: ~p", [Attachment, MetaData]),
                    maybe_transcribe(Db, MediaDoc, Bin, wh_json:get_value(<<"content_type">>, MetaData));
                {'error', _E} ->
                    lager:info("error fetching vm: ~p", [_E]),
                    'undefined'
            end
    end;
maybe_transcribe(_, _, 'false') -> 'undefined'.

-spec maybe_transcribe(ne_binary(), wh_json:object(), binary(), api_binary()) ->
                                    api_object().
maybe_transcribe(_, _, _, 'undefined') -> 'undefined';
maybe_transcribe(_, _, <<>>, _) -> 'undefined';
maybe_transcribe(Db, MediaDoc, Bin, ContentType) ->
    case whapps_speech:asr_freeform(Bin, ContentType) of
        {'ok', Resp} ->
            lager:info("transcription resp: ~p", [Resp]),
            MediaDoc1 = wh_json:set_value(<<"transcription">>, Resp, MediaDoc),
            _ = couch_mgr:ensure_saved(Db, MediaDoc1),
            is_valid_transcription(wh_json:get_value(<<"result">>, Resp)
                                   ,wh_json:get_value(<<"text">>, Resp)
                                   ,Resp
                                  );
        {'error', _E} ->
            lager:info("error transcribing: ~p", [_E]),
            'undefined'
    end.

-spec is_valid_transcription(api_binary(), binary(), wh_json:object()) ->
                                    api_object().
is_valid_transcription(<<"success">>, ?NE_BINARY, Resp) -> Resp;
is_valid_transcription(_Res, _Txt, _) ->
    lager:info("not valid transcription: ~s: '~s'", [_Res, _Txt]),
    'undefined'.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec save_metadata(wh_json:object(), ne_binary(), ne_binary()) ->
                           {'ok', wh_json:object()} |
                           {'error', atom()}.
save_metadata(NewMessage, Db, Id) ->
    {'ok', JObj} = couch_mgr:open_doc(Db, Id),
    Messages = wh_json:get_value([<<"messages">>], JObj, []),
    case has_message_meta(wh_json:get_value(<<"call_id">>, NewMessage), Messages) of
        'true' ->
            lager:info("message meta already exists in VM Messages"),
            {'ok', JObj};
        'false' ->
            case couch_mgr:save_doc(Db, wh_json:set_value([<<"messages">>], [NewMessage | Messages], JObj)) of
                {'error', 'conflict'} ->
                    lager:info("saving resulted in a conflict, trying again"),
                    save_metadata(NewMessage, Db, Id);
                {'ok', _}=Ok -> Ok;
                {'error', R}=E ->
                    lager:info("error while storing voicemail metadata: ~p", [R]),
                    E
            end
    end.

-spec has_message_meta(ne_binary(), wh_json:objects()) -> boolean().
has_message_meta(_, []) -> 'false';
has_message_meta(NewMsgCallId, Messages) ->
    lists:any(fun(Msg) ->
                      wh_json:get_value(<<"call_id">>, Msg) =:= NewMsgCallId
              end, Messages).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Fetches the mailbox parameters from the datastore and loads the
%% mailbox record
%% @end
%%--------------------------------------------------------------------
-spec get_mailbox(wh_json:object(), whapps_call:call()) -> mailbox().
get_mailbox(Data, Call) ->
    case wh_json:get_ne_value(<<"id">>, Data) of
        'undefined' -> get_mailbox_by_capture_group(Data, Call);
        MailboxId -> get_mailbox_by_id(Data, Call, MailboxId)
    end.

-spec get_mailbox_by_capture_group(wh_json:object(), whapps_call:call()) -> mailbox().
get_mailbox_by_capture_group(Data, Call) ->
    CaptureGroup = whapps_call:kvs_fetch('cf_capture_group', Call),
    case wh_util:is_empty(CaptureGroup) of
        'true' -> #mailbox{};
        'false' ->
            lager:debug("attempting to open mailbox number ~s", [CaptureGroup]),
            Options = [{'key', CaptureGroup}
                       ,'include_docs'
                      ],
            AccountDb = whapps_call:account_db(Call),
            case couch_mgr:get_results(AccountDb, <<"cf_attributes/mailbox_number">>, Options) of
                {'ok', []} -> #mailbox{};
                {'ok', [JObj|_]} -> build_mailbox_profile(Data, Call, wh_json:get_value(<<"doc">>, JObj));
                {'error', _R} ->
                    lager:debug("unable to find mailbox by number ~p: ~p", [CaptureGroup, _R]),
                     #mailbox{}
            end
    end.

-spec get_mailbox_by_id(wh_json:object(), whapps_call:call(), ne_binary()) -> mailbox().
get_mailbox_by_id(Data, Call, MailboxId) ->
    AccountDb = whapps_call:account_db(Call),
    case couch_mgr:open_doc(AccountDb, MailboxId) of
        {'ok', JObj} -> build_mailbox_profile(Data, Call, JObj);
        {'error', _R} ->
            lager:info("failed to load voicemail box ~s, ~p", [MailboxId, _R]),
             #mailbox{}
    end.

-spec build_mailbox_profile(wh_json:object(), whapps_call:call(), wh_json:object()) -> mailbox().
build_mailbox_profile(Data, Call, JObj) ->
    MailboxId = wh_json:get_value(<<"_id">>, JObj),
    OwnerId =  wh_json:get_ne_value(<<"owner_id">>, JObj),
    lager:info("loaded voicemail box ~s", [MailboxId]),
    #mailbox{exists = 'true'
             ,mailbox_id = MailboxId
             ,owner_id = OwnerId
             ,skip_instructions = wh_json:is_true(<<"skip_instructions">>, JObj)
             ,skip_greeting = wh_json:is_true(<<"skip_greeting">>, JObj)
             ,pin = wh_json:get_binary_value(<<"pin">>, JObj, <<>>)
             ,timezone = wh_json:get_value(<<"timezone">>, JObj, ?MAILBOX_DEFAULT_TIMEZONE)
             ,mailbox_number = wh_json:get_binary_value(<<"mailbox">>, JObj, whapps_call:request_user(Call))
             ,require_pin = wh_json:is_true(<<"require_pin">>, JObj)
             ,notifications = wh_json:get_value(<<"notifications">>, JObj)
             ,transcribe_voicemail = wh_json:is_true(<<"transcribe">>, JObj)
             ,is_setup = wh_json:is_true(<<"is_setup">>, JObj)
             ,delete_after_notify = wh_json:is_true(<<"delete_after_notify">>, JObj)
             ,check_if_owner = check_if_owner(JObj, Call)
             ,unavailable_media = unavailable_media(JObj, Call)
             ,name_media = name_media(JObj, Call)
             ,is_owner = is_owner(Call, OwnerId)
             ,max_message_count = max_message_count(Call)
             ,max_message_length = max_message_length([Data, JObj])
             ,message_count = message_count(JObj)
             ,interdigit_timeout = interdigit_timeout([JObj, Data])
             ,keys = populate_keys(Call)
            }.

-spec populate_keys(whapps_call:call()) -> vm_keys().
populate_keys(Call) ->
    Default = #keys{},
    JObj = whapps_account_config:get(whapps_call:account_id(Call), <<"keys">>),
    #keys{operator = wh_json:get_binary_value([<<"voicemail">>, <<"operator">>], JObj, Default#keys.operator)
          ,login = wh_json:get_binary_value([<<"voicemail">>, <<"login">>], JObj, Default#keys.login)
          ,save = wh_json:get_binary_value([<<"voicemail">>, <<"save">>], JObj, Default#keys.save)
          ,listen = wh_json:get_binary_value([<<"voicemail">>, <<"listen">>], JObj, Default#keys.listen)
          ,record = wh_json:get_binary_value([<<"voicemail">>, <<"record">>], JObj, Default#keys.record)
          ,hear_new = wh_json:get_binary_value([<<"voicemail">>, <<"hear_new">>], JObj, Default#keys.hear_new)
          ,hear_saved = wh_json:get_binary_value([<<"voicemail">>, <<"hear_saved">>], JObj, Default#keys.hear_saved)
          ,configure = wh_json:get_binary_value([<<"voicemail">>, <<"configure">>], JObj, Default#keys.configure)
          ,exit = wh_json:get_binary_value([<<"voicemail">>, <<"exit">>], JObj, Default#keys.exit)
          ,rec_unavailable = wh_json:get_binary_value([<<"voicemail">>, <<"record_unavailable">>], JObj, Default#keys.rec_unavailable)
          ,rec_name = wh_json:get_binary_value([<<"voicemail">>, <<"record_name">>], JObj, Default#keys.rec_name)
          ,set_pin = wh_json:get_binary_value([<<"voicemail">>, <<"set_pin">>], JObj, Default#keys.set_pin)
          ,return_main = wh_json:get_binary_value([<<"voicemail">>, <<"return_main_menu">>], JObj, Default#keys.return_main)
          ,keep = wh_json:get_binary_value([<<"voicemail">>, <<"keep">>], JObj, Default#keys.keep)
          ,replay = wh_json:get_binary_value([<<"voicemail">>, <<"replay">>], JObj, Default#keys.replay)
          ,delete = wh_json:get_binary_value([<<"voicemail">>, <<"delete">>], JObj, Default#keys.delete)
         }.

-spec check_if_owner(wh_json:object(), whapps_call:call()) -> boolean().
check_if_owner(JObj, Call) ->
    %% dont check if the voicemail box belongs to the owner (by default) if the call was not
    %% specificly to him, IE: calling a ring group and going to voicemail should not check
    Default = case whapps_call:kvs_fetch('cf_last_action', Call) of
                  'undefined' -> 'true';
                  'cf_device' -> 'true';
                  'cf_user' -> 'true';
                  _Else -> 'false'
              end,
    wh_json:is_true(<<"check_if_owner">>, JObj, Default).

-spec unavailable_media(wh_json:object(), whapps_call:call()) -> wh_media:media().
unavailable_media(JObj, Call) ->
    case wh_json:get_ne_value([<<"media">>, <<"unavailable">>], JObj) of
        'undefined' -> 'undefined';
        Id ->
            AccountDb = whapps_call:account_db(Call),
            wh_media:fetch(AccountDb, Id)
    end.

-spec name_media(wh_json:object(), whapps_call:call()) -> wh_media:media().
name_media(JObj, Call) ->
    case name_media_id(JObj, Call) of
        'undefined' -> 'undefined';
        Id ->
            AccountDb = whapps_call:account_db(Call),
            wh_media:fetch(AccountDb, Id)
    end.

-spec name_media_id(wh_json:object(), whapps_call:call()) -> wh_media:media().
name_media_id(JObj, Call) ->
    case wh_json:get_ne_value(<<"owner_id">>, JObj) of
        'undefined' -> wh_json:get_ne_value(?RECORDED_NAME_KEY, JObj);
        OwnerId ->
            AccountDb = whapps_call:account_db(Call),
            case couch_mgr:open_cache_doc(AccountDb, OwnerId) of
                {'ok', Owner} ->
                    wh_json:find(?RECORDED_NAME_KEY, [Owner, JObj]);
                {'error', _R} ->
                    lager:info("unable to open mailbox owner ~s: ~p"
                               ,[OwnerId, _R]),
                    wh_json:get_ne_value(?RECORDED_NAME_KEY, JObj)
            end
    end.

-spec max_message_count(whapps_call:call()) -> non_neg_integer().
max_message_count(Call) ->
    case whapps_account_config:get(whapps_call:account_id(Call)
                                   ,?CF_CONFIG_CAT
                                   ,[<<"voicemail">>, <<"max_message_count">>]
                                  )
    of
        'undefined' -> ?MAILBOX_DEFAULT_MSG_MAX_COUNT;
        MMC -> MMC
    end.

-spec message_count(wh_json:object()) -> non_neg_integer().
message_count(JObj) ->
    Messages = wh_json:get_value(<<"messages">>, JObj, []),
    count_non_deleted_messages(Messages, 0).

-spec count_non_deleted_messages(wh_json:objects(), non_neg_integer()) -> non_neg_integer().
count_non_deleted_messages([], Count) -> Count;
count_non_deleted_messages([Message|Messages], Count) ->
    case wh_json:get_value(<<"folder">>, Message) of
        ?FOLDER_DELETED -> count_non_deleted_messages(Messages, Count);
        _ -> count_non_deleted_messages(Messages, Count+1)
    end.

-spec max_message_length(wh_json:objects()) -> non_neg_integer().
max_message_length(JObjs) ->
    case wh_json:find(<<"max_message_length">>, JObjs) of
        'undefined' -> ?MAILBOX_DEFAULT_MSG_MAX_LENGTH;
        MaxMessageLength -> wh_util:to_integer(MaxMessageLength)
    end.

-spec interdigit_timeout(wh_json:objects()) -> non_neg_integer().
interdigit_timeout(JObjs) ->
    case wh_json:find(<<"interdigit_timeout">>, JObjs) of
        'undefined' -> whapps_call_command:default_interdigit_timeout();
        InterdigitTimeout -> wh_util:to_integer(InterdigitTimeout)
    end.
%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec review_recording(mailbox(), whapps_call:call(), ne_binary(), boolean()) ->
                              {'ok', 'record' | 'save' | 'no_selection'} |
                              {'branch', wh_json:object()}.
review_recording(Box, Call, AttachmentName, AllowOperator) ->
    review_recording(Box, Call, AttachmentName, AllowOperator, 1).

-spec review_recording(mailbox(), whapps_call:call(), ne_binary(), boolean(), integer()) ->
                              {'ok', 'record' | 'save' | 'no_selection'} |
                              {'branch', wh_json:object()}.
review_recording(_, _, _, _, Loop)
  when Loop > 4 ->
    {'ok', 'no_selection'};
review_recording(#mailbox{keys=#keys{listen=Listen
                                      ,save=Save
                                      ,record=Record
                                      ,operator=Operator
                                     }
                           ,interdigit_timeout=Interdigit
                          }=Box
                 ,Call, AttachmentName, AllowOperator, Loop) ->
    lager:info("playing recording review options"),
    NoopId = whapps_call_command:prompt(<<"vm-review_recording">>, Call),
    case whapps_call_command:collect_digits(?KEY_LENGTH
                                            ,whapps_call_command:default_collect_timeout()
                                            ,Interdigit
                                            ,NoopId
                                            ,Call
                                           )
    of
        {'ok', Listen} ->
            lager:info("caller choose to replay the recording"),
            _ = whapps_call_command:b_play(AttachmentName, Call),
            review_recording(Box, Call, AttachmentName, AllowOperator);
        {'ok', Record} ->
            lager:info("caller choose to re-record"),
            {'ok', 'record'};
        {'ok', Save} ->
            lager:info("caller choose to save the recording"),
            {'ok', 'save'};
        {'ok', Operator} when AllowOperator ->
            lager:info("caller choose to ring the operator"),
            case cf_util:get_operator_callflow(whapps_call:account_id(Call)) of
                {'ok', Flow} -> {'branch', Flow};
                {'error',_R} -> review_recording(Box, Call, AttachmentName, AllowOperator, Loop + 1)
            end;
        {'error', _} ->
            lager:info("error while waiting for review selection"),
            {'ok', 'no_selection'};
        _ ->
            review_recording(Box, Call, AttachmentName, AllowOperator, Loop + 1)
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec store_recording(mailbox(), whapps_call:call(), ne_binary(), wh_media:media()) -> boolean().
store_recording(Box, Call, AttachmentName, Media) ->
    lager:debug("storing recording ~s", [AttachmentName]),
    URL = wh_media:store_url(wh_media:prepare_store(Media)),
    _ = whapps_call_command:b_store(AttachmentName, URL, Call),
    verify_store_recording(wh_media:fetch(Media), Call).

-spec verify_store_recording(wh_media:media(), whapps_call:call()) -> boolean().
verify_store_recording(Media, Call) ->
    MinLength =
        case whapps_account_config:get(whapps_call:account_id(Call)
                                       ,?CF_CONFIG_CAT
                                       ,[<<"voicemail">>, <<"min_message_size">>]
                                      )
        of
            'undefined' -> ?MAILBOX_DEFAULT_MSG_MIN_SIZE;
            MML -> wh_util:to_integer(MML)
        end,
    ContentLength = wh_media:content_length(Media),
    case ContentLength >= MinLength of
        'true' -> 'true';
        'false' ->
            lager:info("attachment length is ~B and must be larger than ~B to be stored"
                       ,[ContentLength, MinLength]),
            'false'
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec new_media(mailbox(), whapps_call:call(), ne_binary()) -> wh_media:media().
new_media(#mailbox{mailbox_id=MailboxId
                   ,mailbox_number=MailboxNumber
                   ,owner_id=OwnerId
                   ,timezone=Timezone
                  }, Call, Type) ->
    UtcSeconds = wh_util:current_tstamp(),
    UtcDateTime = calendar:gregorian_seconds_to_datetime(UtcSeconds),
    Name = case localtime:utc_to_local(UtcDateTime, wh_util:to_list(Timezone)) of
               {{Y,M,D},{H,I,S}} ->
                   list_to_binary(["mailbox ", MailboxNumber
                                   ," ", Type, " "
                                   ,wh_util:to_binary(M), "-"
                                   ,wh_util:to_binary(D), "-"
                                   ,wh_util:to_binary(Y), " "
                                   ,wh_util:to_binary(H), ":"
                                   ,wh_util:to_binary(I), ":"
                                   ,wh_util:to_binary(S)
                                  ]);
               {'error', 'unknown_tz'} ->
                   lager:info("unknown timezone: ~s", [Timezone]),
                   {{Y,M,D},{H,I,S}} = UtcDateTime,
                   list_to_binary(["mailbox ", MailboxNumber
                                   ," ", Type, " "
                                   ,wh_util:to_binary(M), "-"
                                   ,wh_util:to_binary(D), "-"
                                   ,wh_util:to_binary(Y), " "
                                   ,wh_util:to_binary(H), ":"
                                   ,wh_util:to_binary(I), ":"
                                   ,wh_util:to_binary(S), " UTC"
                                  ])
           end,
    Props = props:filter_undefined(
              [{<<"name">>, Name}
               ,{<<"description">>, <<"voicemail ", Type/binary, " media">>}
               ,{<<"source_type">>, <<"voicemail">>}
               ,{<<"media_source">>, <<"call">>}
               ,{<<"streamable">>, 'true'}
               ,{<<"utc_seconds">>, UtcSeconds}

               ,{<<"from_user">>, whapps_call:from_user(Call)}
               ,{<<"from_realm">>, whapps_call:from_realm(Call)}
               ,{<<"to_user">>, whapps_call:to_user(Call)}
               ,{<<"to_realm">>, whapps_call:to_realm(Call)}
               ,{<<"caller_id_number">>, whapps_call:caller_id_number(Call)}
               ,{<<"caller_id_name">>, whapps_call:caller_id_name(Call)}
               ,{<<"call_id">>, whapps_call:call_id(Call)}

               ,{<<"voicemail_box_id">>, MailboxId}
               ,{<<"voicemail_box_number">>, MailboxNumber}
%%               ,{<<"voicemail_length">>, Length}
               ,{<<"voicemail_timestamp">>, UtcSeconds}
               ,{<<"owner_id">>, OwnerId}
              ]
             ),
    case Type =:= <<"message">> of
        'true' ->
            wh_media:new_private(whapps_call:account_db(Call)
                                 ,wh_json:from_list(Props));
        'false' ->
            wh_media:new_public(whapps_call:account_db(Call)
                                ,wh_json:from_list(Props))
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec unsolicited_owner_mwi_update(mailbox(), whapps_call:call()) -> 'ok'.
unsolicited_owner_mwi_update(#mailbox{owner_id=OwnerId}, Call) ->
    AccountDb = whapps_call:account_db(Call),
    _ = cf_util:unsolicited_owner_mwi_update(AccountDb, OwnerId),
    'ok'.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec get_messages(mailbox(), whapps_call:call()) -> wh_json:objects().
get_messages(#mailbox{mailbox_id=Id}, Call) ->
    AccountDb = whapps_call:account_db(Call),
    case couch_mgr:open_doc(AccountDb, Id) of
        {'ok', JObj} -> wh_json:get_value(<<"messages">>, JObj, []);
        _ -> []
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec get_message(wh_json:object(), whapps_call:call()) -> ne_binary().
get_message(Message, Call) ->
    MediaId = wh_json:get_value(<<"media_id">>, Message),
    list_to_binary(["/", whapps_call:account_db(Call), "/", MediaId]).

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec count_messages(wh_json:objects(), ne_binary()) -> non_neg_integer().
count_messages(Messages, Folder) ->
    lists:sum([1 || Message <- Messages,
                    wh_json:get_value(<<"folder">>, Message) =:= Folder
              ]).

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec get_folder(wh_json:objects(), ne_binary()) -> wh_json:objects().
get_folder(Messages, Folder) ->
    [M || M <- Messages, wh_json:get_value(<<"folder">>, M) =:= Folder].

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec set_folder(ne_binary(), wh_json:object(), mailbox(), whapps_call:call()) -> any().
set_folder(Folder, Message, Box, Call) ->
    lager:info("setting folder for message to ~s", [Folder]),
    not (wh_json:get_value(<<"folder">>, Message) =:= Folder) andalso
        update_folder(Folder, wh_json:get_value(<<"media_id">>, Message), Box, Call).

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec update_folder(ne_binary(), ne_binary(), mailbox(), whapps_call:call()) ->
                           {'ok', wh_json:object()} |
                           {'error', term()}.
update_folder(_, 'undefined', _, _) ->
    {'error', 'attachment_undefined'};
update_folder(Folder, MediaId, #mailbox{mailbox_id=Id}=Mailbox, Call) ->
    AccountDb = whapps_call:account_db(Call),
    Folder =:= ?FOLDER_DELETED andalso
        update_doc(<<"pvt_deleted">>, 'true', MediaId, AccountDb),
    case couch_mgr:open_doc(AccountDb, Id) of
        {'ok', JObj} ->
            Messages = [ update_folder1(Message, Folder, MediaId, wh_json:get_value(<<"media_id">>, Message))
                         || Message <- wh_json:get_value(<<"messages">>, JObj, []) ],
            case couch_mgr:save_doc(AccountDb, wh_json:set_value(<<"messages">>, Messages, JObj)) of
                {'error', 'conflict'} ->
                    update_folder(Folder, MediaId, Mailbox, Call);
                {'ok', _}=OK ->
                    OK;
                {'error', R}=E ->
                    lager:info("error while updating folder ~s ~p", [Folder, R]),
                    E
            end;
        {'error', R}=E ->
            lager:info("failed ot open mailbox ~s: ~p", [Id, R]),
            E
    end.

update_folder1(Message, Folder, MediaId, MediaId) ->
    wh_json:set_value(<<"folder">>, Folder, Message);
update_folder1(Message, _, _, _) ->
    Message.

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec update_doc(wh_json:key() | wh_json:keys()
                 ,wh_json:json_term()
                 ,mailbox() | ne_binary()
                 ,whapps_call:call() | ne_binary()
                ) ->
                        'ok' |
                        {'error', atom()}.
update_doc(Key, Value, #mailbox{mailbox_id=Id}, Db) ->
    update_doc(Key, Value, Id, Db);
update_doc(Key, Value, Id, ?NE_BINARY = Db) ->
    case couch_mgr:open_doc(Db, Id) of
        {'ok', JObj} ->
            case couch_mgr:save_doc(Db, wh_json:set_value(Key, Value, JObj)) of
                {'error', 'conflict'} ->
                    update_doc(Key, Value, Id, Db);
                {'ok', _} -> 'ok';
                {'error', R}=E ->
                    lager:info("unable to update ~s in ~s, ~p", [Id, Db, R]),
                    E
            end;
        {'error', R}=E ->
            lager:info("unable to update ~s in ~s, ~p", [Id, Db, R]),
            E
    end;
update_doc(Key, Value, Id, Call) ->
    update_doc(Key, Value, Id, whapps_call:account_db(Call)).

%%--------------------------------------------------------------------
%% @private
%% @doc
%% @end
%%--------------------------------------------------------------------
-spec tmp_file() -> ne_binary().
tmp_file() ->
    Ext = ?MAILBOX_DEFAULT_VM_EXTENSION,
    <<(wh_util:to_hex_binary(crypto:rand_bytes(16)))/binary, ".", Ext/binary>>.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Returns the Universal Coordinated Time (UTC) reported by the
%% underlying operating system (local time is used if universal
%% time is not available) as number of gregorian seconds starting
%% with year 0.
%% @end
%%--------------------------------------------------------------------
-spec new_timestamp() -> pos_integer().
new_timestamp() -> wh_util:current_tstamp().

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Accepts Universal Coordinated Time (UTC) and convert it to binary
%% encoded Unix epoch in the provided timezone
%% @end
%%--------------------------------------------------------------------
-spec get_unix_epoch(ne_binary(), ne_binary()) -> ne_binary().
get_unix_epoch(Epoch, Timezone) ->
    UtcDateTime = calendar:gregorian_seconds_to_datetime(wh_util:to_integer(Epoch)),
    LocalDateTime = localtime:utc_to_local(UtcDateTime, wh_util:to_list(Timezone)),
    wh_util:to_binary(calendar:datetime_to_gregorian_seconds(LocalDateTime) - ?UNIX_EPOCH_IN_GREGORIAN).

%%--------------------------------------------------------------------
%% @private
%% @doc
%%
%% @end
%%--------------------------------------------------------------------
-spec is_owner(whapps_call:call(), ne_binary()) -> boolean().
is_owner(Call, OwnerId) ->
    case whapps_call:kvs_fetch('owner_id', Call) of
        <<>> -> 'false';
        'undefined' -> 'false';
        OwnerId -> 'true';
        _Else -> 'false'
    end.

-module(powersaver).

-export([start_link/0, wakeup/0]).
-export([init/0, active/1, idle/2, sleeping/1]).

-include("openmoko.hrl").

-define(W, powersaver_node).

-define(ACTIVE_BRIGHTNESS, 0.6).
-define(IDLE_BRIGHTNESS, 0.1).
-define(SLEEPING_BRIGHTNESS, 0).

-define(ACTIVE_TO_IDLE, 10000).
-define(IDLE_TO_SLEEPING, 20000).
-define(SLEEPING_RING_BRIGHTEN_DELAY, 5000).

start_link() ->
    {ok, spawn_link(?MODULE, init, [])}.

wakeup() ->
    ?MODULE ! wakeup,
    ok.

-record(state, {}).

init() ->
    true = erlang:register(?MODULE, self()),
    gui:start_glade(?W, "lockwindow.glade"),
    ok = openmoko_event:subscribe(?MODULE),
    {ok, _ReaderPid1} = linux_input_device:start_link("/dev/input/touchscreen0", touchscreen),
    {ok, _ReaderPid2} = linux_input_device:start_link("/dev/input/event0", aux_buttons),
    enter_active(#state{}).

enter_active(State) ->
    ok = openmoko_lcd:set_brightness(?ACTIVE_BRIGHTNESS),
    ?MODULE:active(State).

active(State) ->
    receive
	wakeup -> ?MODULE:active(switch_on_lcd_refresh(State));
	{?OPENMOKO_EVENT_SERVER, power_button_pressed} -> enter_sleeping(State);
	_ -> ?MODULE:active(State)
    after ?ACTIVE_TO_IDLE -> enter_idle(State)
    end.

enter_idle(State) ->
    ok = openmoko_lcd:set_brightness(?IDLE_BRIGHTNESS),
    {ok, TRef} = timer:send_after(?IDLE_TO_SLEEPING, idle_to_sleeping),
    ?MODULE:idle(State, TRef).

leave_idle(State, TRef) ->
    {ok, cancel} = timer:cancel(TRef),
    enter_active(State).

idle(State, TRef) ->
    receive
	wakeup ->
	    leave_idle(switch_on_lcd_refresh(State), TRef);
	{?OPENMOKO_EVENT_SERVER, modem_ringing} -> leave_idle(State, TRef);
	{?OPENMOKO_EVENT_SERVER, {received_sms, _}} -> leave_idle(State, TRef);
	{?OPENMOKO_EVENT_SERVER, {charger_inserted, _TrueOrFalse}} -> leave_idle(State, TRef);
	{?OPENMOKO_EVENT_SERVER, power_button_pressed} -> enter_sleeping(State);
	{?OPENMOKO_EVENT_SERVER, _} -> ?MODULE:idle(State, TRef);
	idle_to_sleeping -> enter_sleeping(State);
	_ -> leave_idle(State, TRef)
    end.

enter_sleeping(State) ->
    case openmoko_callmanager:get_call_state() of
	{ok, call_in_progress} ->
	    enter_idle(State);
	{ok, _} ->
	    gui:cmd(?W, 'Gtk_widget_show', [lock_window]),
	    gui:cmd(?W, 'Gtk_window_fullscreen', [lock_window]),
	    gui:cmd(?W, 'Gtk_window_set_keep_above', [lock_window, true]),
	    deep_sleep(State)
    end.

%% There's no easy way of *actually* turning off the LCD - yet!
switch_off_lcd_refresh(State) -> State.
switch_on_lcd_refresh(State) -> State.

leave_sleeping(State) ->
    NewState = switch_on_lcd_refresh(State),
    gui:cmd(?W, 'Gtk_window_set_keep_above', [lock_window, false]),
    gui:cmd(?W, 'Gtk_window_unfullscreen', [lock_window]),
    gui:cmd(?W, 'Gtk_widget_hide', [lock_window]),
    enter_active(NewState).

deep_sleep(State) ->
    NewState = switch_off_lcd_refresh(State),
    ok = openmoko_lcd:set_brightness(?SLEEPING_BRIGHTNESS),
    ?MODULE:sleeping(NewState).

sleeping(State) ->
    receive
	wakeup ->
	    leave_sleeping(State);
	{_ReaderPid, aux_buttons, _} ->
	    leave_sleeping(State);
	{?OPENMOKO_EVENT_SERVER, {charger_inserted, _TrueOrFalse}} ->
	    leave_sleeping(State);
	{?OPENMOKO_EVENT_SERVER, modem_ringing} ->
	    shallow_sleep(State);
	{?OPENMOKO_EVENT_SERVER, {received_sms, _}} ->
	    shallow_sleep(State);
	_ ->
	    ?MODULE:sleeping(State)
    end.

shallow_sleep(State) ->    
    NewState = switch_on_lcd_refresh(State),
    openmoko_lcd:set_brightness(?ACTIVE_BRIGHTNESS),
    receive
	wakeup ->
	    leave_sleeping(NewState);
	{?OPENMOKO_EVENT_SERVER, accept_call} ->
	    leave_sleeping(NewState);
	{?OPENMOKO_EVENT_SERVER, reject_call} ->
	    deep_sleep(NewState);
	{?OPENMOKO_EVENT_SERVER, modem_ringing} ->
	    shallow_sleep(NewState);
	{?OPENMOKO_EVENT_SERVER, {received_sms, _}} ->
	    shallow_sleep(NewState)
    after ?SLEEPING_RING_BRIGHTEN_DELAY ->
	    deep_sleep(NewState)
    end.

module GnomeOrgNextSchedule where

import Prelude
import Clutter.Actor as Actor
import Clutter.ActorAlign as ActorAlign
import Data.Array (drop, filter, head, length, nubBy)
import Data.Either (Either(..))
import Data.Int (floor, toNumber)
import Data.Maybe (Maybe(..), fromMaybe)
import Data.Number (remainder)
import Data.String (Pattern(..), indexOf, splitAt)
import Data.String as String
import Data.String.Common (split)
import Data.Traversable (sequence, traverse_)
import Data.Tuple (Tuple(..))
import Effect (Effect)
import Effect.Ref (Ref)
import Effect.Ref as Ref
import GJS as GJS
import GLib (getenv)
import GLib as GLib
import GLib.DateTime (getUnix, new_from_iso8601, to_unix)
import Gio.File as Gio.File
import Gio.ThemedIcon as ThemedIcon
import Gnome.Extension (ExtensionSimple)
import Gnome.UI.Main as Main
import Gnome.UI.Main.Panel as Panel
import Gnome.UI.PanelMenu (Button)
import Gnome.UI.PanelMenu as PanelMenu
import Gnome.UI.PopupMenu as PopupMenu
import Safe.Coerce (coerce)
import St as St
import St.BoxLayout as BoxLayout
import St.Icon as St.Icon
import St.Label as Label
import St.Label as St.Label

newtype UnixTS
  = UnixTS Int

derive newtype instance semiringUnixTS :: Semiring UnixTS

derive newtype instance ringUnixTS :: Ring UnixTS

derive newtype instance eqUnixTS :: Eq UnixTS

derive newtype instance ordUnixTS :: Ord UnixTS

type Event
  = { when :: UnixTS
    , what :: String
    }

-- | Load event from cache file content
parseEvents :: String -> Either String (Array Event)
parseEvents lines = sequence (toEvent <$> filter (not <<< String.null) (split (coerce "\n") lines))
  where
  toEvent :: String -> Either String Event
  toEvent line = do
    sepPos <- case indexOf (Pattern " ") line of
      Nothing -> Left ("No sep: '" <> line <> "'")
      Just v -> pure v
    let
      { before, after } = splitAt sepPos line
    date <- case new_from_iso8601 before of
      Nothing -> Left ("Bad date: " <> before)
      Just v -> pure v
    let
      when = UnixTS (to_unix date)

      what = after
    pure { when, what }

-- | Load events from cache file
loadEvents :: EventsPath -> Effect (Array Event)
loadEvents (EventsPath fp) = do
  content <- Gio.File.readFileSync fp
  case content of
    Left err -> do
      GJS.warn (Tuple "Could not read events" err)
      pure []
    Right str -> case parseEvents str of
      Left e -> do
        GJS.warn ("Failed to parse: " <> e <> "\n" <> str)
        pure []
      Right ev -> pure ev

data Status
  = Waiting
  | Alerting Event

type State
  = { status :: Status
    , events :: Array Event
    , updated_at :: UnixTS
    }

newState :: UnixTS -> Array Event -> State
newState now baseEvents = { status, events, updated_at }
  where
  updated_at = now

  events =
    nubBy (\a b -> compare a.what b.what)
      $ filter (\ev -> ev.when >= now) baseEvents

  status = Waiting

readState :: EventsPath -> Effect State
readState cache = do
  now <- UnixTS <$> getUnix
  events <- loadEvents cache
  pure $ newState now events

newtype EventsPath
  = EventsPath String

eventsPath :: Effect EventsPath
eventsPath = do
  home <- fromMaybe "/homeless" <$> getenv "HOME"
  pure $ EventsPath $ home <> "/.local/share/gnome-org-next-schedule/events"

getModifiedDate :: EventsPath -> Effect UnixTS
getModifiedDate (EventsPath path) = do
  file_update <- Gio.File.getModificationDateTime path
  pure
    $ case file_update of
        Nothing -> UnixTS 0
        Just ts -> UnixTS $ to_unix ts

loadState :: EventsPath -> Ref State -> Effect State
loadState cache stateRef = do
  GJS.log "Loading gnome-org-next-schedule events"
  state <- readState cache
  Ref.write state stateRef
  pure state

-- | Reload state when the file changes
updateState :: EventsPath -> UnixTS -> Ref State -> Effect State
updateState cache now stateRef = do
  state <- Ref.read stateRef
  if (now - state.updated_at <= UnixTS 61) then
    pure state
  else do
    path <- eventsPath
    ts <- getModifiedDate path
    if ts <= state.updated_at then
      pure state
    else
      loadState cache stateRef

-- | Warn 5 minutes before event starts
alarmTime :: UnixTS
alarmTime = UnixTS 300

-- | Check for upcoming alert or expired event
advanceState :: UnixTS -> State -> Maybe State
advanceState now currentState = do
  nextEvent <- head currentState.events
  if now > nextEvent.when then
    -- Advance to the next event
    pure $ currentState { status = Waiting, events = drop 1 currentState.events }
  else case currentState.status of
    Waiting
      | nextEvent.when - now <= alarmTime -> pure $ currentState { status = Alerting nextEvent }
    _ -> Nothing

type UI
  = { label :: Label.Label, countdown :: Label.Label }

newUI :: Effect UI
newUI = do
  countdown <- Label.new ""
  label <- Label.new ""
  pure { countdown, label }

topMenuUI :: UI -> Effect Button
topMenuUI ui = do
  box <- BoxLayout.new
  button <- PanelMenu.newButton 0.0 "OrgNextSchedule" false
  -- create icon
  calIcon <- ThemedIcon.new "x-office-calendar"
  icon <- St.Icon.new
  St.add_style_class_name icon "system-status-icon"
  St.Icon.set_gicon icon calIcon
  -- setup layout
  Actor.add_child box icon
  Actor.add_child box ui.countdown
  Actor.add_child box ui.label
  Actor.add_child button box
  Actor.set_y_align ui.label ActorAlign.center
  -- Actor.set_y_align ui.countdown ActorAlign.center
  -- add to status bar
  Panel.addToStatusArea "OrgNextSchedule" button
  pure button

renderEvent :: UnixTS -> UI -> Event -> Effect Unit
renderEvent now ui ev = do
  let
    UnixTS diffSec = ev.when - now

    diff = toNumber diffSec

    hour = 3600.0

    day = hour * 24.0

    showR = show <<< floor

    showM v = do
      let
        s = showR v
      case String.length s of
        1 -> "0" <> s
        _ -> s

    countdown
      | diff < 60.0 = "GO"
      | diff < hour = showR (diff `div` 60.0) <> "m"
      | diff < 9.0 * hour =
        showR (diff `div` hour)
          <> "h"
          <> showM ((diff `remainder` hour) `div` 60.0)
      | diff < day = showR (diff `div` hour) <> "h"
      | otherwise = showR (diff `div` day) <> "d"
  Label.set_text ui.countdown countdown
  Label.set_text ui.label ev.what

renderState :: UnixTS -> UI -> State -> Effect Unit
renderState now ui state = case head state.events of
  Nothing -> do
    Label.set_text ui.countdown "x"
    Label.set_text ui.label "No schedule :("
  Just ev -> renderEvent now ui ev

worker :: EventsPath -> UI -> Ref State -> Effect Boolean
worker cache ui stateRef = do
  now <- UnixTS <$> getUnix
  currentState <- updateState cache now stateRef
  state <- case advanceState now currentState of
    Nothing -> Ref.read stateRef
    Just state -> do
      case state.status of
        Alerting ev -> do
          let
            msg = ev.what <> " starts in 5min"
          GJS.log msg
          Main.notify msg ""
        _ -> pure mempty
      Ref.write state stateRef
      pure state
  renderState now ui state
  pure true

type Env
  = { button :: PanelMenu.Button
    , timer :: GLib.EventSourceId
    }

extension :: ExtensionSimple Env
extension = { extension_enable, extension_disable }
  where
  doReload cache ui stateRef = do
    state <- loadState cache stateRef
    now <- UnixTS <$> getUnix
    renderState now ui state
    pure state

  onMenuClick cache ui button stateRef = do
    -- clear previous menu
    PanelMenu.removeAll button
    PanelMenu.close button
    --
    -- load state
    state <- Ref.read stateRef
    let
      removeEvent event = do
        now <- UnixTS <$> getUnix
        updatedState <- Ref.modify (\s -> s { events = filter (\ev -> ev /= event) s.events }) stateRef
        renderState now ui updatedState
    now <- UnixTS <$> getUnix
    let
      renderEventButton event = do
        evItem <- PopupMenu.newItem ""
        evUI <- newUI
        box <- BoxLayout.new
        renderEvent now evUI event
        Actor.add_child box evUI.countdown
        Actor.add_child box evUI.label
        Actor.add_child evItem box
        PopupMenu.connectActivate evItem (removeEvent event)
        PanelMenu.addMenuItem button evItem
    traverse_ renderEventButton state.events
    --
    -- reload button
    menuItem <- PopupMenu.newItem ""
    PopupMenu.connectActivate menuItem (void $ doReload cache ui stateRef)
    reloadLabel <- St.Label.new "reload"
    Actor.add_child menuItem reloadLabel
    PanelMenu.addMenuItem button menuItem
    --
    -- show menu
    PanelMenu.open button
    pure true

  extension_enable = do
    --
    -- create top menu labels
    ui <- newUI
    --
    -- create state
    cache <- eventsPath
    stateRef <- Ref.new { status: Waiting, events: [], updated_at: UnixTS 0 }
    state <- doReload cache ui stateRef
    --
    -- create menu
    button <- topMenuUI ui
    GJS.log { msg: "enabled OrgNextSchedule", events: length state.events }
    void $ Actor.onButtonPressEvent button (\_ _ -> onMenuClick cache ui button stateRef)
    --
    -- start worker
    timer <- GLib.timeoutAdd 30000 (worker cache ui stateRef)
    pure { button, timer }

  extension_disable env = do
    GLib.sourceRemove env.timer
    Actor.destroy env.button

module GnomeOrgNextSchedule where

import Prelude

import Clutter.Actor as Actor
import Clutter.ActorAlign as ActorAlign
import Data.Array (drop, filter, head, length)
import Data.Either (Either(..))
import Data.Maybe (Maybe(..), fromMaybe)
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
loadEvents :: String -> Effect (Array Event)
loadEvents fp = do
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
    }

newState :: UnixTS -> Array Event -> State
newState now baseEvents = { status, events }
  where
    events = filter (\ev -> ev.when >= now) baseEvents
    status = Waiting

updateState :: Ref State -> Effect State
updateState stateRef = do
    home <- fromMaybe "/homeless" <$> getenv "HOME"
    let
      cache = home <> "/.local/share/gnome-org-next-schedule/events"
    events <- loadEvents cache
    -- state
    now <- UnixTS <$> getUnix
    let state = newState now events
    Ref.write state stateRef
    pure state

-- | Warn 5 minutes before event starts
alarmTime :: UnixTS
alarmTime = UnixTS 300

advanceState :: UnixTS -> State -> Maybe State
advanceState now currentState = do
  nextEvent <- head currentState.events
  if now > nextEvent.when then
    -- Advance to the next event
    pure { status: Waiting, events: drop 1 currentState.events }
  else case currentState.status of
    Waiting
      | nextEvent.when - now <= alarmTime -> pure { status: Alerting nextEvent, events: currentState.events }
    _ -> Nothing

type UI
  = { label :: Label.Label, countdown :: Label.Label }

renderEvent :: UnixTS -> UI -> Event -> Effect Unit
renderEvent now ui ev = do
  let
    UnixTS diffms = ev.when - now

    diff = diffms

    countdown
      | diff < 60 = show diff <> "s"
      | diff < 3600 = show (diff `div` 60) <> "m"
      | diff < (3600 * 24) = show (diff `div` 3600) <> "h"
      | otherwise = show (diff `div` (3600 * 24)) <> "d"
  Label.set_text ui.countdown countdown
  Label.set_text ui.label ev.what

renderState :: UnixTS -> UI -> State -> Effect Unit
renderState now ui state = case head state.events of
  Nothing -> do
    Label.set_text ui.countdown "x"
    Label.set_text ui.label "No schedule :("
  Just ev -> renderEvent now ui ev

worker :: UI -> Ref State -> Effect Boolean
worker ui stateRef = do
  now <- UnixTS <$> getUnix
  currentState <- Ref.read stateRef
  state <- case advanceState now currentState of
    Nothing -> Ref.read stateRef
    Just state -> do
      case state.status of
           Alerting ev -> do
             Main.notify (ev.what <> " starts in 5min") ""
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
  doReload ui stateRef = do
    GJS.log "Reloading gnome-org-next-schedule"
    state <- updateState stateRef
    now <- UnixTS <$> getUnix
    renderState now ui state
    pure state

  onMenuClick ui button stateRef = do
    -- clear previous menu
    PanelMenu.removeAll button
    PanelMenu.close button
    --
    -- add basic action
    halfItem <- PopupMenu.newItem "Reserve 30min"
    PanelMenu.addMenuItem button halfItem
    fullItem <- PopupMenu.newItem "Reserve 60min"
    PanelMenu.addMenuItem button fullItem
    --
    -- load state
    state <- Ref.read stateRef
    let
      removeEvent event = do
        now <- UnixTS <$> getUnix
        updatedState <- Ref.modify (\s -> { status: s.status, events: filter (\ev -> ev /= event) s.events }) stateRef
        renderState now ui updatedState

    now <- UnixTS <$> getUnix
    let
      renderEventButton event = do
        evItem <- PopupMenu.newItem ""
        label <- Label.new ""
        countdown <- Label.new ""
        box <- BoxLayout.new
        renderEvent now { countdown, label } event
        Actor.add_child box countdown
        Actor.add_child box label
        Actor.add_child evItem box
        PopupMenu.connectActivate evItem (removeEvent event)
        PanelMenu.addMenuItem button evItem
    traverse_ renderEventButton state.events
    --
    -- reload button
    menuItem <- PopupMenu.newItem ""
    PopupMenu.connectActivate menuItem (void $ doReload ui stateRef)
    reloadLabel <- St.Label.new "reload"
    Actor.add_child menuItem reloadLabel
    PanelMenu.addMenuItem button menuItem
    --
    -- show menu
    PanelMenu.open button
    pure true

  createMenuButton ui = do
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

  extension_enable = do
    --
    -- create top menu labels
    countdown <- Label.new ""
    label <- Label.new ""
    let
      ui = { countdown, label }
    --
    -- create state
    stateRef <- Ref.new { status: Waiting, events: [] }
    state <- doReload ui stateRef
    --
    -- create menu
    button <- createMenuButton ui
    GJS.log {msg: "enabled OrgNextSchedule", events: length state.events}
    void $ Actor.onButtonPressEvent button (\_ _ -> onMenuClick ui button stateRef)
    --
    -- start worker
    timer <- GLib.timeoutAdd 5000 (worker ui stateRef)
    pure { button, timer }

  extension_disable env = do
    GLib.sourceRemove env.timer
    Actor.destroy env.button
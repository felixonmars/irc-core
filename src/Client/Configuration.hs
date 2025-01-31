{-# LANGUAGE BangPatterns      #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}
{-# LANGUAGE TemplateHaskell   #-}
{-# LANGUAGE ApplicativeDo     #-}
{-# LANGUAGE RankNTypes        #-}
{-# LANGUAGE LambdaCase        #-}

{-|
Module      : Client.Configuration
Description : Client configuration format and operations
Copyright   : (c) Eric Mertens, 2016
License     : ISC
Maintainer  : emertens@gmail.com

This module defines the top-level configuration information for the client.
-}

module Client.Configuration
  (
  -- * Configuration type
    Configuration(..)
  , ConfigurationFailure(..)
  , LayoutMode(..)
  , EditMode(..)
  , PaddingMode(..)
  , ExtensionConfiguration(..)

  -- * Lenses
  , configDefaults
  , configServers
  , configPalette
  , configWindowNames
  , configNickPadding
  , configMacros
  , configExtensions
  , configExtraHighlights
  , configNeverHighlights
  , configUrlOpener
  , configIgnores
  , configActivityBar
  , configBellOnMention
  , configHideMeta
  , configKeyMap
  , configLayout
  , configShowPing
  , configJumpModifier
  , configDigraphs

  , extensionPath
  , extensionRtldFlags
  , extensionArgs

  -- * Loading configuration
  , loadConfiguration

  -- * Resolving paths
  , getConfigPath

  -- * Specification
  , configurationSpec

  -- * FilePath resolution
  , FilePathContext
  , newFilePathContext
  , resolveFilePath

  -- * Url opener configuration
  , UrlOpener(..)
  , UrlArgument(..)
  ) where

import           Client.Commands.Interpolation
import           Client.Commands.Recognizer
import           Client.Configuration.Colors
import           Client.Configuration.Macros (macroMapSpec)
import           Client.Configuration.ServerSettings
import           Client.EventLoop.Actions
import           Client.Image.Palette
import           Config
import           Config.Macro
import           Config.Schema
import           Control.Exception
import           Control.Lens                        hiding (List)
import           Data.Foldable                       (foldl', toList)
import           Data.HashMap.Strict                 (HashMap)
import qualified Data.HashMap.Strict                 as HashMap
import qualified Data.List.NonEmpty                  as NonEmpty
import           Data.Map                            (Map)
import qualified Data.Map                            as Map
import           Data.Maybe
import           Data.Monoid                         (Endo(..))
import           Data.Text                           (Text)
import qualified Data.Text                           as Text
import qualified Data.Vector                         as Vector
import           Digraphs (Digraph(..))
import           Graphics.Vty.Input.Events (Modifier(..), Key(..))
import           Graphics.Vty.Attributes             (Attr)
import           Irc.Identifier                      (Identifier)
import           System.Directory
import           System.FilePath
import           System.Posix.DynamicLinker          (RTLDFlags(..))
import           System.IO.Error

-- | Top-level client configuration information. When connecting to a
-- server configuration from '_configServers' is used where possible,
-- otherwise '_configDefaults' is used.
data Configuration = Configuration
  { _configDefaults        :: ServerSettings -- ^ Default connection settings
  , _configServers         :: (HashMap Text ServerSettings) -- ^ Host-specific settings
  , _configPalette         :: Palette -- ^ User-customized color palette
  , _configWindowNames     :: Text -- ^ Names of windows, used when alt-jumping)
  , _configExtraHighlights :: [Identifier] -- ^ Extra highlight nicks/terms
  , _configNeverHighlights :: [Identifier] -- ^ Never highlight nicks/terms
  , _configNickPadding     :: PaddingMode -- ^ Padding of nicks in messages
  , _configMacros          :: Recognizer Macro -- ^ command macros
  , _configExtensions      :: [ExtensionConfiguration] -- ^ extensions to load
  , _configUrlOpener       :: Maybe UrlOpener -- ^ paths to url opening executable
  , _configIgnores         :: [Text] -- ^ initial ignore mask list
  , _configActivityBar     :: Bool -- ^ initially visibility of the activity bar
  , _configBellOnMention   :: Bool -- ^ notify terminal on mention
  , _configHideMeta        :: Bool -- ^ default setting for hidemeta on new windows
  , _configKeyMap          :: KeyMap -- ^ keyboard bindings
  , _configLayout          :: LayoutMode -- ^ Default layout on startup
  , _configShowPing        :: Bool -- ^ visibility of ping time
  , _configJumpModifier    :: [Modifier] -- ^ Modifier used for jumping windows
  , _configDigraphs        :: Map Digraph Text -- ^ Extra digraphs
  }
  deriving Show

data UrlOpener = UrlOpener FilePath [UrlArgument]
  deriving Show

data UrlArgument = UrlArgLiteral String | UrlArgUrl
  deriving Show

-- | Setting for how to pad the message prefix.
data PaddingMode
  = LeftPadding  !Int -- ^ Whitespace add to the left side of chat prefix
  | RightPadding !Int -- ^ Whitespace add to the right side of chat prefix
  | NoPadding         -- ^ No whitespace added
  deriving (Show)

data LayoutMode
  -- | Vertically stack all windows in a single column
  = OneColumn
  -- | Vertically stack extra windows in a second column
  | TwoColumn
  deriving Show

data EditMode
  = SingleLineEditor
  | MultiLineEditor
  deriving Show

-- | Failure cases when loading a configuration file.
data ConfigurationFailure

  -- | Error message from reading configuration file
  = ConfigurationReadFailed String

  -- | Error message from parser or lexer
  | ConfigurationParseFailed FilePath String

  -- | Error message from loading parsed configuration
  | ConfigurationMalformed FilePath String
  deriving Show

-- | default instance
instance Exception ConfigurationFailure

-- | Configuration information for run-time loaded dynamic
-- library extensions.
data ExtensionConfiguration = ExtensionConfiguration
  { _extensionPath      :: FilePath -- ^ path to shared object
  , _extensionRtldFlags :: [RTLDFlags] -- ^ dynamic linker flags
  , _extensionArgs      :: [Text] -- ^ arguments to the extension on startup
  }
  deriving Show

makeLenses ''Configuration
makeLenses ''ExtensionConfiguration

-- | The default client behavior for naming windows is to use the first two
-- rows of a QWERTY keyboard followed by the first two rows combined with
-- SHIFT.
defaultWindowNames :: Text
defaultWindowNames = "1234567890qwertyuiop!@#$%^&*()QWERTYUIOP"

-- | Uses 'getXdgDirectory' 'XdgConfig' to find @~/.config/glirc/config@
getConfigPath :: IO FilePath
getConfigPath =
  do dir <- getXdgDirectory XdgConfig "glirc"
     return (dir </> "config")

-- | Load the configuration file defaulting to @~/.glirc/config@.
--
-- Given configuration path is optional and actual path used will
-- be returns on success
loadConfiguration ::
  Maybe FilePath {- ^ path to configuration file -} ->
  IO (Either ConfigurationFailure (FilePath, Configuration))
loadConfiguration mbPath = try $
  do path <- case mbPath of
               Nothing -> getConfigPath
               Just p  -> pure p

     ctx <- newFilePathContext path

     let toPath txt _ = pure (resolveFilePath ctx (Text.unpack txt))
     rawcfg <- loadFileWithMacros toPath path
        `catches`
        [Handler $ \e -> case e of
           LoadFileParseError fp pe -> throwIO (ConfigurationParseFailed fp (displayException pe))
           LoadFileMacroError (UndeclaredVariable a var) -> badMacro a ("undeclared variable: " ++ Text.unpack var)
           LoadFileMacroError (BadSplice a)              -> badMacro a "bad @splice"
           LoadFileMacroError (BadLoad a)                -> badMacro a "bad @load"
           LoadFileMacroError (UnknownDirective a dir)   -> badMacro a ("unknown directive: @" ++ Text.unpack dir)
        ,Handler $ \e ->
            if isDoesNotExistError e &&
               isNothing mbPath &&
               ioeGetFileName e == Just path
            then pure (Sections (FilePosition path (Position 0 0 0)) [])
            else throwIO (ConfigurationReadFailed (displayException e))
        ]

     case loadValue configurationSpec rawcfg of
       Left e -> throwIO
               $ ConfigurationMalformed path
               $ displayException e
       Right cfg -> return (path, resolvePaths ctx (cfg defaultServerSettings))

badMacro :: FilePosition -> String -> IO a
badMacro (FilePosition path posn) msg =
  throwIO $ ConfigurationMalformed path
          $ "line "    ++ show (posLine   posn) ++
            " column " ++ show (posColumn posn) ++
            ": "       ++ msg

-- | Resolve all the potentially relative file paths in the configuration file
resolvePaths :: FilePathContext -> Configuration -> Configuration
resolvePaths ctx =
  let res = resolveFilePath ctx
      resolveServerFilePaths = over (ssTlsClientCert . mapped) res
                             . over (ssTlsClientKey  . mapped) res
                             . over (ssTlsServerCert . mapped) res
                             . over (ssSaslMechanism . mapped . _SaslEcdsa . _3) res
                             . over (ssLogDir        . mapped) res
  in over (configExtensions . mapped . extensionPath) res
   . over (configServers    . mapped) resolveServerFilePaths

configurationSpec ::
  ValueSpec (ServerSettings -> Configuration)
configurationSpec = sectionsSpec "config-file" $

  do let sec' def name spec info = fromMaybe def <$> optSection' name spec info

     ssDefUpdate            <- sec' (Nothing,id) "defaults" serverSpec
                               "Default values for use across all server configurations"
     ssUpdates              <- sec' [] "servers" (listSpec serverSpec)
                               "Configuration parameters for IRC servers"
     _configPalette         <- sec' defaultPalette "palette" paletteSpec
                               "Customize the client color choices"
     _configWindowNames     <- sec' defaultWindowNames "window-names" anySpec
                               "Window names to use for quick jumping with jump-modifier key"
     _configJumpModifier    <- sec' [MMeta] "jump-modifier" modifierSpec
                               "Modifier used to jump to a window by name. Defaults to `meta`."
     _configMacros          <- sec' mempty "macros" macroMapSpec
                               "Programmable macro commands"
     _configExtensions      <- sec' [] "extensions" (listSpec extensionSpec)
                               "extension libraries to load at startup"
     _configUrlOpener       <- optSection' "url-opener" urlOpenerSpec
                               "External command used by /url command"
     _configExtraHighlights <- sec' mempty "extra-highlights" (listSpec identifierSpec)
                               "Extra words to highlight in chat messages"
     _configNeverHighlights <- sec' mempty "never-highlights" (listSpec identifierSpec)
                               "Words to avoid highlighting in chat messages"
     _configNickPadding     <- sec' NoPadding "nick-padding" nickPaddingSpec
                               "Amount of space to reserve for nicknames in chat messages"
     _configIgnores         <- sec' [] "ignores" anySpec
                               "Set of nicknames to ignore on startup"
     _configActivityBar     <- sec' False  "activity-bar" yesOrNoSpec
                               "Show channel names and message counts for activity on\
                               \ unfocused channels."
     _configBellOnMention   <- sec' False  "bell-on-mention" yesOrNoSpec
                               "Emit bell character to terminal on mention"
     _configHideMeta        <- sec' False  "hide-metadata" yesOrNoSpec
                               "Initial setting for hiding metadata on new windows"
     bindings               <- sec' [] "key-bindings" (listSpec keyBindingSpec)
                               "Extra key bindings"
     _configLayout          <- sec' OneColumn "layout" layoutSpec
                               "Initial setting for window layout"
     _configShowPing        <- sec' True "show-ping" yesOrNoSpec
                               "Initial setting for visibility of ping times"
     _configDigraphs        <- sec' mempty "extra-digraphs" (Map.fromList <$> listSpec digraphSpec)
                               "Extra digraphs"
     return (\def ->
             let _configDefaults = snd ssDefUpdate def
                 _configServers  = buildServerMap _configDefaults ssUpdates
                 _configKeyMap   = foldl (\acc f -> f acc) initialKeyMap bindings
             in Configuration{..})

-- | The default nick padding side if padding is going to be used
defaultPaddingSide :: Int -> PaddingMode
defaultPaddingSide = RightPadding

-- | Either full or abbreviated nick-padding configuration
--
-- > nick-padding: 10
--
-- > nick-padding:
-- >   side: right
-- >   width: 16
nickPaddingSpec :: ValueSpec PaddingMode
nickPaddingSpec = defaultPaddingSide <$> nonnegativeSpec <!> fullNickPaddingSpec

-- | Full nick padding specification:
--
-- > nick-padding:
-- >   side: left
-- >   width: 15
fullNickPaddingSpec :: ValueSpec PaddingMode
fullNickPaddingSpec = sectionsSpec "nick-padding" (sideSec <*> amtSec)
  where
    sideSpec = LeftPadding  <$ atomSpec "left" <!>
               RightPadding <$ atomSpec "right"

    sideSec = fromMaybe defaultPaddingSide
          <$> optSection' "side" sideSpec "Side to pad (default `right`)"

    amtSec  = reqSection' "width" nonnegativeSpec "Field width"


-- | Parse either a single modifier key or a list of modifier keys:
-- @meta@, @alt@, @ctrl@
modifierSpec :: ValueSpec [Modifier]
modifierSpec = toList <$> oneOrNonemptySpec modifier1Spec
  where
    modifier1Spec = namedSpec "modifier"
                  $ MMeta <$ atomSpec "meta"
                <!> MAlt  <$ atomSpec "alt"
                <!> MCtrl <$ atomSpec "ctrl"

-- | Parse either @one-column@ or @two-column@ and return the corresponding
-- 'LayoutMode' value.
layoutSpec :: ValueSpec LayoutMode
layoutSpec = OneColumn <$ atomSpec "one-column"
         <!> TwoColumn <$ atomSpec "two-column"

-- | Parse a single key binding. This can be an action binding, command
-- binding, or an unbinding specification.
keyBindingSpec :: ValueSpec (KeyMap -> KeyMap)
keyBindingSpec = actBindingSpec <!> cmdBindingSpec <!> unbindingSpec

-- | Parse a single action key binding. Action bindings are a map specifying
-- a binding using 'keySpec' and an action:
--
-- > bind: "M-a"
-- > action: jump-to-activity
actBindingSpec :: ValueSpec (KeyMap -> KeyMap)
actBindingSpec = sectionsSpec "action-binding" $
  do ~(m,k) <- reqSection' "bind" keySpec
               "Key to be bound (e.g. a, C-b, M-c C-M-d)"
     a      <- reqSection "action"
               "Action name (see `/keymap`)"
     return (addKeyBinding m k a)

cmdBindingSpec :: ValueSpec (KeyMap -> KeyMap)
cmdBindingSpec = sectionsSpec "command-binding" $
  do ~(m,k) <- reqSection' "bind" keySpec
               "Key to be bound (e.g. a, C-b, M-c C-M-d)"
     cmd    <- reqSection "command"
               "Client command to execute (exclude leading `/`)"
     return (addKeyBinding m k (ActCommand cmd))

unbindingSpec :: ValueSpec (KeyMap -> KeyMap)
unbindingSpec = sectionsSpec "remove-binding" $
  do ~(m,k) <- reqSection' "unbind" keySpec
               "Key to be unbound (e.g. a, C-b, M-c C-M-d)"
     return (removeKeyBinding m k)


-- | Custom configuration specification for emacs-style key descriptions
keySpec :: ValueSpec ([Modifier], Key)
keySpec = customSpec "emacs-key" stringSpec
        $ \key -> case parseKey key of
                    Nothing -> Left "unknown key"
                    Just x  -> Right x


nonnegativeSpec :: (Ord a, Num a) => ValueSpec a
nonnegativeSpec = customSpec "non-negative" numSpec
                $ \x -> if x < 0 then Left "negative number"
                                 else Right x


paletteSpec :: ValueSpec Palette
paletteSpec = sectionsSpec "palette" $
  (ala Endo (foldMap . foldMap) ?? defaultPalette) <$> sequenceA fields

  where
    nickColorsSpec :: ValueSpec (Palette -> Palette)
    nickColorsSpec = set palNicks . Vector.fromList . NonEmpty.toList
                 <$> nonemptySpec attrSpec

    modeColorsSpec :: Lens' Palette (HashMap Char Attr) -> ValueSpec (Palette -> Palette)
    modeColorsSpec l
      = fmap (set l)
      $ customSpec "modes" (assocSpec attrSpec)
      $ fmap HashMap.fromList
      . traverse (\(mode, attr) ->
          case Text.unpack mode of
            [m] -> Right (m, attr)
            _   -> Left "expected single letter")

    fields :: [SectionsSpec (Maybe (Palette -> Palette))]
    fields = optSection' "nick-colors" nickColorsSpec
             "Colors used to highlight nicknames"

           : optSection' "cmodes" (modeColorsSpec palCModes)
             "Colors used to highlight channel modes"

           : optSection' "umodes" (modeColorsSpec palUModes)
             "Colors used to highlight user modes"

           : optSection' "snomask" (modeColorsSpec palSnomask)
             "Colors used to highlight server notice mask"

           : [ optSection' lbl (set l <$> attrSpec) "" | (lbl, Lens l) <- paletteMap ]

extensionSpec :: ValueSpec ExtensionConfiguration
extensionSpec = simpleExtensionSpec <!> fullExtensionSpec

-- | Default dynamic linker flags: @RTLD_LOCAL@ and @RTLD_NOW@
defaultRtldFlags :: [RTLDFlags]
defaultRtldFlags = [RTLD_LOCAL, RTLD_NOW]

-- | Given only a filepath build an extension configuration that
-- loads the extension using the 'defaultRtldFlags' and no arguments.
simpleExtensionSpec :: ValueSpec ExtensionConfiguration
simpleExtensionSpec =
  do _extensionPath <- stringSpec
     pure ExtensionConfiguration
       { _extensionRtldFlags = defaultRtldFlags
       , _extensionArgs      = []
       , .. }

-- | Full extension configuration allows the RTLD flags to be manually
-- specified. This can be useful if the extension defines symbols that
-- need to be visible to libraries that the extension is linked against.
fullExtensionSpec :: ValueSpec ExtensionConfiguration
fullExtensionSpec =
  sectionsSpec "extension" $
  do _extensionPath      <- reqSection' "path"       stringSpec
                            "Path to shared object"
     _extensionRtldFlags <- fromMaybe defaultRtldFlags <$>
                            optSection' "rtld-flags" (listSpec rtldFlagSpec)
                            "Runtime dynamic linker flags"
     _extensionArgs      <- fromMaybe [] <$> optSection "args"
                            "Extension-specific configuration arguments"
     pure ExtensionConfiguration {..}

rtldFlagSpec :: ValueSpec RTLDFlags
rtldFlagSpec = namedSpec "rtld-flag"
             $ RTLD_LOCAL  <$ atomSpec "local"
           <!> RTLD_GLOBAL <$ atomSpec "global"
           <!> RTLD_NOW    <$ atomSpec "now"
           <!> RTLD_LAZY   <$ atomSpec "lazy"

urlOpenerSpec :: ValueSpec UrlOpener
urlOpenerSpec = simpleCase <!> complexCase
  where
    simpleCase =
      do path <- stringSpec
         pure (UrlOpener path [UrlArgUrl])

    complexCase = sectionsSpec "url-opener" $
      do path <- reqSection' "path" stringSpec "Executable"
         args <- reqSection' "args" (listSpec argSpec) "Arguments"
         pure (UrlOpener path args)

    argSpec = UrlArgUrl     <$  atomSpec "url"
          <!> UrlArgLiteral <$> stringSpec

digraphSpec :: ValueSpec (Digraph, Text)
digraphSpec =
  sectionsSpec "digraph" $
   do ~(x,y) <- reqSection' "input" twoChars "digraph key"
      val    <- reqSection' "output" textSpec "replacement text"
      pure (Digraph x y, val)
  where
    twoChars = customSpec "two" stringSpec $ \case
        [x,y] -> Right (x,y)
        _     -> Left "exactly two characters required"

buildServerMap ::
  ServerSettings {- ^ defaults -} ->
  [(Maybe Text, ServerSettings -> ServerSettings)] ->
  HashMap Text ServerSettings
buildServerMap def ups = go HashMap.empty def Nothing
  where
    serverSettingName ss =
      fromMaybe (views ssHostName Text.pack ss)
                (view ssName ss)

    raw = HashMap.fromListWith (++) [(mbExtName, [up]) | (mbExtName, up) <- ups]

    go acc prev prevName = foldl' (add prev) acc nexts
      where
        nexts = HashMap.findWithDefault [] prevName raw

    add prev acc f = go acc' ss (Just me)
      where
        ss = f prev
        me = serverSettingName ss
        acc'
          | HashMap.member me acc = acc
          | otherwise             = HashMap.insert me ss acc

data FilePathContext = FilePathContext { fpBase, fpHome :: FilePath }

newFilePathContext ::
  FilePath {- ^ configuration file path -} ->
  IO FilePathContext
newFilePathContext base = FilePathContext (takeDirectory base) <$> getHomeDirectory

resolveFilePath :: FilePathContext -> FilePath -> FilePath
resolveFilePath fpc path
  | isAbsolute path                   = path
  | "~":rest <- splitDirectories path = joinPath (fpHome fpc : rest)
  | otherwise                         = fpBase fpc </> path

{-# OPTIONS -fglasgow-exts #-}
-----------------------------------------------------------------------------
-- |
-- Module      :  XMobar
-- Copyright   :  (c) Andrea Rossato
-- License     :  BSD-style (see LICENSE)
-- 
-- Maintainer  :  Andrea Rossato <andrea.rossato@unibz.it>
-- Stability   :  unstable
-- Portability :  unportable
--
-- A status bar for the Xmonad Window Manager 
--
-----------------------------------------------------------------------------

module Main ( -- * Configuration
              -- $config
              Config (..)
              -- * Main Stuff
              -- $main
            , Xbar
            , runXMobar
            , main
            , eventLoop
            , createWin
              -- * Printing
              -- $print
            , drawInWin
            , printStrings
              -- * Program Execution
              -- $commands
            , getOptions
            , execCommands
            , execCommand
            , runCommandLoop
            , readVariables
              -- * Parsing
              -- $parser
            , parseString
            , stringParser
            , defaultColors
            , colorsAndText
            , templateStringParser
            , templateCommandParser
            , templateParser
            , parseTemplate
              -- * Unmamaged Windows
              -- $unmanwin
            , mkUnmanagedWindow
              -- * Useful Utilities
            , readConfig
            , initColor
            , io
            ) where

import Graphics.X11.Xlib
import Graphics.X11.Xlib.Misc

import Text.ParserCombinators.Parsec

import Control.Monad.State
import Control.Monad.Reader
import Control.Concurrent
import System.Environment

import System.Process
import System.Exit
import System.IO (hClose, hGetLine)

-- $config
-- Configuration data type and default configuration

-- | The configuration data type
data Config = 
    Config { fonts          :: String   -- ^ Fonts
           , bgColor        :: String   -- ^ Backgroud color
           , fgColor        :: String   -- ^ Default font color
           , xPos           :: Int      -- ^ x Window position (origin in the upper left corner) 
           , yPos           :: Int      -- ^ y Window position 
           , width          :: Int      -- ^ Window width
           , hight          :: Int      -- ^ Window hight
           , align          :: String   -- ^ text alignment
           , refresh        :: Int      -- ^ Refresh rate in tenth of seconds
           , commands       :: [(String, Int, [String])]   -- ^ For setting the refresh rate and 
                                                           -- options for the programs to run (optionals)
           , sepChar        :: String     -- ^ The character to be used for indicating 
                                        --   commands in the output template (default '%')
           , template       :: String   -- ^ The output template 
           } deriving (Eq, Show, Read, Ord)

defaultConfig :: Config
defaultConfig =
    Config { fonts = "-misc-fixed-*-*-*-*-10-*-*-*-*-*-*-*"
           , bgColor = "#000000"
           , fgColor = "#BFBFBF"
           , xPos = 0
           , yPos = 0
           , width = 1024
           , hight = 15
           , align = "left"
           , refresh = 10
           , commands = [("date", 10, [])]
           , sepChar = "%"
           , template = "Uptime: <fc=#00FF00>%uptime%</fc> ** <fc=#FF0000>%date%</fc>"
           }

-- | This is just esthetics, stolen from XMonad: see 'runXMobar'
newtype Xbar a = X (ReaderT Config (StateT XState IO) a)
    deriving (Functor, Monad, MonadIO, MonadState XState, MonadReader Config)

-- | The State component of StateT
data XState = 
    XState { display :: Display
           , window :: Window
           , vars :: [(ThreadId, MVar String)]
           }
-- $main

-- | Totally useless: but it is nice to be able to use get to get the
-- | state and ask to get the configuration: functions requires less
-- | arguments, after all.
runXMobar :: Config -> [(ThreadId, MVar String)] -> Display -> Window -> Xbar () -> IO ()
runXMobar c v d w (X f) = 
    do runStateT (runReaderT f c) (XState d w v)
       return ()

-- | The main entry point
main :: IO ()
main = 
    do args <- getArgs
       config <-
           if length args /= 1
              then do putStrLn ("No configuration file specified. Using default settings.")
                      return defaultConfig
              else readConfig (args!!0)
       cl <- parseTemplate config (template config)
       var <- execCommands config cl
       (d,w) <- createWin config
       runXMobar config var d w eventLoop

-- | The event loop
eventLoop :: Xbar ()
eventLoop =
    do c <- ask
       s <- get
       i <- io $ readVariables (vars s)
       ps <- io $ parseString c i
       drawInWin ps
       -- back again: we are never ending
       io $ threadDelay $ 100000 * refresh c
       eventLoop

-- | The function to create the initial window
createWin :: Config -> IO (Display, Window)
createWin config =
  do dpy   <- openDisplay ""
     let dflt = defaultScreen dpy
     rootw  <- rootWindow dpy dflt
     win <- mkUnmanagedWindow dpy (defaultScreenOfDisplay dpy) rootw 
            (fromIntegral $ xPos config) 
            (fromIntegral $ yPos config) 
            (fromIntegral $ width config) 
            (fromIntegral $ hight config)
     mapWindow dpy win
     return (dpy,win)


-- $print

-- | Draws in and updates the window
drawInWin :: [(String, String)] -> Xbar ()
drawInWin str = 
    do config <- ask
       st <- get
       let (dpy,win) = (display st, window st)
       bgcolor  <-  io $ initColor dpy $ bgColor config
       gc <- io $ createGC dpy win
       --let's get the fonts
       fontst <-  io $ loadQueryFont dpy (fonts config)
       io $ setFont dpy gc (fontFromFontStruct fontst)

       -- set window background 
       io $ setForeground dpy gc bgcolor
       io $ fillRectangle dpy win gc 0 0 
              (fromIntegral $ width config) 
              (fromIntegral $ hight config)
       -- write
       let strWithLenth = map (\(s,c) -> (s,c,textWidth fontst s)) str
       printStrings gc fontst 1 strWithLenth 
       -- free everything
       io $ freeFont dpy fontst
       io $ freeGC dpy gc
       io $ flush dpy

-- | An easy way to print the stuff we need to print
printStrings :: GC
             -> FontStruct
             -> Position
             -> [(String, String, Position)]
             -> Xbar ()
printStrings _ _ _ [] = return ()
printStrings gc fontst offs sl@((s,c,l):xs) =
    do config <- ask
       st <- get
       let (_,asc,_,_) = textExtents fontst s
           totSLen = foldr (\(_,_,len) -> (+) len) 0 sl
           valign = (fromIntegral (hight config) + fromIntegral asc) `div` 2
           offset = case (align config) of
                      "center" -> (fromIntegral (width config) - fromIntegral totSLen) `div` 2
                      "right" -> fromIntegral (width config) - fromIntegral totSLen
                      "left" -> offs
                      _ -> offs
       color <- io $ initColor (display st) c
       io $ setForeground (display st) gc color
       io $ drawString (display st) (window st) gc offset valign s
       printStrings gc fontst (offs + l) xs

-- $commands

-- | Gets the command options set in configuration.
getOptions :: Config -> String -> [String]
getOptions c com =
    let l = commands c
        p = filter (\(s,_,_) -> s == com) l
    in case p of
         [(_,_,opts)] -> opts
         _ -> []

-- | Gets the command options set in configuration.
getRefRate :: Config -> String -> Int
getRefRate c com =
    let l = commands c
        p = filter (\(s,_,_) -> s == com) l
    in case p of
         [(_,int,_)] -> int
         _ -> refresh c

-- | Runs a list of programs
execCommands :: Config -> [(String,String,String)] -> IO [(ThreadId, MVar String)]
execCommands _ [] = return []
execCommands c (x:xs) =
    do i <- execCommand c x
       is <- execCommands c xs
       return $ i : is

execCommand :: Config -> (String,String,String) -> IO (ThreadId, MVar String)
execCommand c com = 
    do var <- newMVar "Updating..."
       h <- forkIO $ runCommandLoop var c com
       return (h,var)

-- | Runs the external program
runCommandLoop :: MVar String -> Config -> (String,String,String) -> IO ()
runCommandLoop var conf c@(s,com,ss) 
    | com == "" = 
        do modifyMVar_ var (\_ -> return $ "Could not parse the template")
           threadDelay $ 100000 * refresh conf
           runCommandLoop var conf c
    | otherwise =
        do (i,o,e,p) <- runInteractiveCommand (com ++ concat (map (' ':) $ getOptions conf com))
           -- the followinf leaks memory
           --(i,o,e,p) <- runInteractiveProcess com (getOptions c com) Nothing Nothing
           exit <- waitForProcess p
           let closeHandles = do hClose o
                                 hClose i
                                 hClose e
           case exit of
             ExitSuccess -> do str <- hGetLine o
                               closeHandles
                               modifyMVar_ var (\_ -> return $ s ++ str ++ ss)
                               threadDelay $ 100000 * (getRefRate conf com)
                               runCommandLoop var conf c
             _ -> do closeHandles
                     modifyMVar_ var $ \_ -> return $ "Could not execute command " ++ com
                     threadDelay $ 100000 * (getRefRate conf com)
                     runCommandLoop var conf c
                                  

-- | Reads MVars set by 'runCommandLoop'
readVariables :: [(ThreadId, MVar String)] -> IO String
readVariables [] = return ""
readVariables ((_,v):xs) =
    do f <- readMVar v
       fs <- readVariables xs
       return $! f ++ fs

{- $parser
These are the neede parsers. Don't trust them too much.

There are parsers for the commands output and parsers for the
formatting template.
 -}

-- | Runs the actual string parsers
parseString :: Config -> String -> IO [(String, String)]
parseString config s = 
    case (parse (stringParser config) "" s) of
      Left _ -> return [("Could not parse string: " ++ s
                        , (fgColor config))]
      Right x  -> return x

-- | Gets the string and combines the needed parsers
stringParser :: Config -> Parser [(String, String)]
stringParser c = manyTill (colorsAndText c <|> defaultColors c) eof

-- | Parses a string with the default color (no color set)
defaultColors :: Config -> Parser (String, String)
defaultColors config = 
    do { s <- many $ noneOf "<"
       ; return (s,(fgColor config))
       }
    <|> colorsAndText config

-- | Parses a string with a color set
colorsAndText :: Config -> Parser (String, String) 
colorsAndText config = 
    do { string "<fc=#"
       ; n <- count 6 hexDigit
       ; string ">"
       ; s <- many $ noneOf "<"
       ; string "</fc>"
       ; return (s,"#"++n)
       }
    <|> defaultColors config

-- | Parses the output template string
templateStringParser :: Config -> Parser (String,String,String)
templateStringParser c =
    do{ s <- many $ noneOf (sepChar c)
      ; (_,com,_) <- templateCommandParser c
      ; ss <- many $ noneOf (sepChar c)
      ; return (s, com, ss)
      } 

-- | Parses the command part of the template string
templateCommandParser :: Config -> Parser (String,String,String)
templateCommandParser c =
    do { let chr = head $ sepChar c
       ; char chr
       ; com <- many $ noneOf (sepChar c)
       ; char chr
       ; return $ ("",com,"")
       }
-- | Combines the template parsers
templateParser :: Config -> Parser [(String,String,String)]
templateParser c = many (templateStringParser c)

-- | Actually runs the template parsers
parseTemplate :: Config -> String -> IO [(String,String,String)]
parseTemplate config s = 
    case (parse (templateParser config) "" s) of
      Left _ -> return [("","","")]
      Right x  -> return x

{- $unmanwin

This is a way to create unmamaged window. It was a mistery in Haskell. 
Till I've found out...;-)

-}

-- | Creates a window with the attribute override_redirect set to True.
-- Windows Managers should not touch this kind of windows.
mkUnmanagedWindow :: Display
                  -> Screen
                  -> Window
                  -> Position
                  -> Position
                  -> Dimension
                  -> Dimension
                  -> IO Window
mkUnmanagedWindow dpy scr rw x y w h = do
  let visual = defaultVisualOfScreen scr
      attrmask = cWOverrideRedirect
  window <- allocaSetWindowAttributes $ 
            \attributes -> do
              set_override_redirect attributes True
              createWindow dpy rw x y w h 0 (defaultDepthOfScreen scr) 
                           inputOutput visual attrmask attributes                                
  return window

{- $utility
Utilities, aka stollen without givin' credit stuff.
-}

-- | Reads the configuration files or quits with an error
readConfig :: FilePath -> IO Config
readConfig f = 
    do s <- readFile f
       case reads s of
         [(config,_)] -> return config
         [] -> error ("Corrupt config file: " ++ f)
         _ -> error ("Some problem occured. Aborting...")


-- | Get the Pixel value for a named color
initColor :: Display -> String -> IO Pixel
initColor dpy c = (color_pixel . fst) `liftM` allocNamedColor dpy colormap c
    where colormap = defaultColormap dpy (defaultScreen dpy)

-- | Short-hand for lifting in the IO monad
io :: IO a -> Xbar a
io = liftIO

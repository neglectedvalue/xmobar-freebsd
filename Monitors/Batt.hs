-----------------------------------------------------------------------------
-- |
-- Module      :  Monitors.Batt
-- Copyright   :  (c) Andrea Rossato
-- License     :  BSD-style (see LICENSE)
-- 
-- Maintainer  :  Andrea Rossato <andrea.rossato@unibz.it>
-- Stability   :  unstable
-- Portability :  unportable
--
-- A battery monitor for XMobar
--
-----------------------------------------------------------------------------

module Main where

import Data.IORef
import qualified Data.ByteString.Lazy.Char8 as B
import System.Posix.Files

import Monitors.Common

monitorConfig :: IO MConfig
monitorConfig = 
    do lc <- newIORef "#FF0000"
       l <- newIORef 25
       nc <- newIORef "#FF0000"
       h <- newIORef 75
       hc <- newIORef "#00FF00"
       t <- newIORef "Batt: <left>"
       p <- newIORef package
       u <- newIORef ""
       a <- newIORef []
       e <- newIORef ["left"]
       return $ MC nc l lc h hc t p u a e

fileB1 :: (String, String)
fileB1 = ("/proc/acpi/battery/BAT1/info", "/proc/acpi/battery/BAT1/state")

fileB2 :: (String, String)
fileB2 = ("/proc/acpi/battery/BAT2/info", "/proc/acpi/battery/BAT2/state")

checkFileBatt :: (String, String) -> IO Bool
checkFileBatt (i,_) =
    fileExist i

readFileBatt :: (String, String) -> IO (B.ByteString, B.ByteString)
readFileBatt (i,s) = 
    do a <- B.readFile i
       b <- B.readFile s
       return (a,b)

parseBATT :: IO Float
parseBATT =
    do (a1,b1) <- readFileBatt fileB1
       c <- checkFileBatt fileB2
       let sp p s = read $ stringParser p s
           (fu, pr) = (sp (3,2) a1, sp (2,4) b1)
       case c of
         True -> do (a2,b2) <- readFileBatt fileB1
                    let full = fu + (sp (3,2) a2)
                        present = pr + (sp (2,4) b2)
                    return $ present / full
         _ -> return $ pr / fu


formatBatt :: Float -> Monitor [String] 
formatBatt x =
    do let f s = floatToPercent (s / 100)
       l <- showWithColors f (x * 100)
       return [l]

package :: String
package = "xmb-batt"

runBatt :: [String] -> Monitor String
runBatt _ =
    do c <- io $ parseBATT
       l <- formatBatt c
       parseTemplate l 
    
main :: IO ()
main =
    do let af = runBatt []
       runMonitor monitorConfig af runBatt

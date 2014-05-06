{-# LANGUAGE GeneralizedNewtypeDeriving, DeriveDataTypeable, CPP, ForeignFunctionInterface #-}

module Development.Shake.FileTime(
    FileTime, fileTimeNone,
    getModTimeError, getModTimeMaybe
    ) where

import Development.Shake.Classes
import General.String
import Data.Char
import Data.Int
import Data.Word
import qualified Data.ByteString.Char8 as BS
import Numeric

#if defined(PORTABLE)
-- Required for Portable
import System.IO.Error
import Control.Exception
import System.Directory
import Data.Time
import System.Time

#elif defined(mingw32_HOST_OS)
-- Required for non-portable Windows
import Foreign
import Foreign.C.Types
import Foreign.C.String
type WIN32_FILE_ATTRIBUTE_DATA = Ptr ()
type LPCSTR = Ptr CChar
type LPCWSTR = Ptr CWchar
foreign import stdcall unsafe "Windows.h GetFileAttributesExA" c_getFileAttributesExA :: LPCSTR  -> Int32 -> WIN32_FILE_ATTRIBUTE_DATA -> IO Bool
foreign import stdcall unsafe "Windows.h GetFileAttributesExW" c_getFileAttributesExW :: LPCWSTR -> Int32 -> WIN32_FILE_ATTRIBUTE_DATA -> IO Bool
size_WIN32_FILE_ATTRIBUTE_DATA = 36
index_WIN32_FILE_ATTRIBUTE_DATA_ftLastWriteTime_dwLowDateTime = 20

#else
-- Required for non-portable Unix (since it requires a non-standard library)
import System.Posix.Files.ByteString
#endif


-- FileTime is an optimised type, which stores some portion of the file time,
-- or maxBound to indicate there is no valid time. The moral type is @Maybe Datetime@
-- but it needs to be more efficient.
newtype FileTime = FileTime Int32
    deriving (Typeable,Eq,Hashable,Binary,NFData)

instance Show FileTime where
    show (FileTime x) = "0x" ++ replicate (length s - 8) '0' ++ map toUpper s
        where s = showHex (fromIntegral x :: Word32) ""

fileTime :: Int32 -> FileTime
fileTime x = FileTime $ if x == maxBound then maxBound - 1 else x

fileTimeNone :: FileTime
fileTimeNone = FileTime maxBound


getModTimeError :: String -> BSU -> IO FileTime
getModTimeError msg x = do
    res <- getModTimeMaybe x
    case res of
        -- Make sure you raise an error in IO, not return a value which will error later
        Nothing -> error $ msg ++ "\n  " ++ unpackU x
        Just x -> return x


getModTimeMaybe :: BSU -> IO (Maybe FileTime)

#if defined(PORTABLE)
-- Portable fallback
getModTimeMaybe x = handleJust (\e -> if isDoesNotExistError e then Just () else Nothing) (const $ return Nothing) $ do
    time <- getModificationTime $ unpackU x
    return $ Just $ extractFileTime time

-- deal with difference in return type of getModificationTime between directory versions
class ExtractFileTime a where extractFileTime :: a -> FileTime
instance ExtractFileTime ClockTime where extractFileTime (TOD t _) = fileTime $ fromIntegral t
instance ExtractFileTime UTCTime where extractFileTime = fileTime . floor . fromRational . toRational . utctDayTime


#elif defined(mingw32_HOST_OS)
-- Directly against the Win32 API, twice as fast as the portable version
getModTimeMaybe x = BS.useAsCString (unpackU_ x) $ \file ->
    allocaBytes size_WIN32_FILE_ATTRIBUTE_DATA $ \info -> do
        res <- c_getFileAttributesExA file 0 info
        if res then
            peeks info
         else if requireU x then withCWString (unpackU x) $ \file -> do
            res <- c_getFileAttributesExW file 0 info
            if res then peeks info else return Nothing
         else
            return Nothing
    where
        -- Technically a Word32, but we can treak it as an Int32 for peek
        peeks info = fmap (Just . fileTime) (peekByteOff info index_WIN32_FILE_ATTRIBUTE_DATA_ftLastWriteTime_dwLowDateTime :: IO Int32)

#else
-- Unix version
getModTimeMaybe x = handleJust (\e -> if isDoesNotExistError e then Just () else Nothing) (const $ return Nothing) $ do
    t <- fmap modificationTime $ getFileStatus $ unpackU_ x
    return $ Just $ fileTime $ fromIntegral $ fromEnum t
#endif

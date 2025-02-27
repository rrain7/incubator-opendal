-- Licensed to the Apache Software Foundation (ASF) under one
-- or more contributor license agreements.  See the NOTICE file
-- distributed with this work for additional information
-- regarding copyright ownership.  The ASF licenses this file
-- to you under the Apache License, Version 2.0 (the
-- "License"); you may not use this file except in compliance
-- with the License.  You may obtain a copy of the License at
--
--   http://www.apache.org/licenses/LICENSE-2.0
--
-- Unless required by applicable law or agreed to in writing,
-- software distributed under the License is distributed on an
-- "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
-- KIND, either express or implied.  See the License for the
-- specific language governing permissions and limitations
-- under the License.
{-# LANGUAGE GeneralizedNewtypeDeriving #-}

module OpenDAL (
  Operator,
  OpenDALError (..),
  ErrorCode (..),
  OpMonad,
  MonadOperation (..),
  runOp,
  newOp,
  readOpRaw,
  writeOpRaw,
  isExistOpRaw,
  createDirOpRaw,
  copyOpRaw,
  renameOpRaw,
  deleteOpRaw,
) where

import Control.Monad.Except (ExceptT, MonadError, runExceptT, throwError)
import Control.Monad.Reader (MonadIO, MonadReader, ReaderT, ask, liftIO, runReaderT)
import Data.ByteString (ByteString)
import qualified Data.ByteString as BS
import Data.HashMap.Strict (HashMap)
import qualified Data.HashMap.Strict as HashMap
import Foreign
import Foreign.C.String
import Foreign.C.Types (CChar)
import OpenDAL.FFI

newtype Operator = Operator (ForeignPtr RawOperator)

data ErrorCode
  = FFIError
  | Unexpected
  | Unsupported
  | ConfigInvalid
  | NotFound
  | PermissionDenied
  | IsADirectory
  | NotADirectory
  | AlreadyExists
  | RateLimited
  | IsSameFile
  deriving (Eq, Show)

data OpenDALError = OpenDALError {errorCode :: ErrorCode, message :: String}
  deriving (Eq, Show)

newtype OpMonad a = OpMonad (ReaderT Operator (ExceptT OpenDALError IO) a)
  deriving
    ( Functor
    , Applicative
    , Monad
    , MonadReader Operator
    , MonadError OpenDALError
    , MonadIO
    )

class (Monad m) => MonadOperation m where
  readOp :: String -> m ByteString
  writeOp :: String -> ByteString -> m ()
  isExistOp :: String -> m Bool
  createDirOp :: String -> m ()
  copyOp :: String -> String -> m ()
  renameOp :: String -> String -> m ()
  deleteOp :: String -> m ()

instance MonadOperation OpMonad where
  readOp path = do
    op <- ask
    result <- liftIO $ readOpRaw op path
    either throwError return result
  writeOp path byte = do
    op <- ask
    result <- liftIO $ writeOpRaw op path byte
    either throwError return result
  isExistOp path = do
    op <- ask
    result <- liftIO $ isExistOpRaw op path
    either throwError return result
  createDirOp path = do
    op <- ask
    result <- liftIO $ createDirOpRaw op path
    either throwError return result
  copyOp src dst = do
    op <- ask
    result <- liftIO $ copyOpRaw op src dst
    either throwError return result
  renameOp src dst = do
    op <- ask
    result <- liftIO $ renameOpRaw op src dst
    either throwError return result
  deleteOp path = do
    op <- ask
    result <- liftIO $ deleteOpRaw op path
    either throwError return result

byteSliceToByteString :: ByteSlice -> IO ByteString
byteSliceToByteString (ByteSlice bsDataPtr len) = BS.packCStringLen (bsDataPtr, fromIntegral len)

parseErrorCode :: Int -> ErrorCode
parseErrorCode 1 = FFIError
parseErrorCode 2 = Unexpected
parseErrorCode 3 = Unsupported
parseErrorCode 4 = ConfigInvalid
parseErrorCode 5 = NotFound
parseErrorCode 6 = PermissionDenied
parseErrorCode 7 = IsADirectory
parseErrorCode 8 = NotADirectory
parseErrorCode 9 = AlreadyExists
parseErrorCode 10 = RateLimited
parseErrorCode 11 = IsSameFile
parseErrorCode _ = FFIError

runOp :: Operator -> OpMonad a -> IO (Either OpenDALError a)
runOp operator (OpMonad op) = runExceptT $ runReaderT op operator

-- | Create a new Operator.
newOp :: String -> HashMap String String -> IO (Either OpenDALError Operator)
newOp scheme hashMap = do
  let keysAndValues = HashMap.toList hashMap
  withCString scheme $ \cScheme ->
    withMany withCString (map fst keysAndValues) $ \cKeys ->
      withMany withCString (map snd keysAndValues) $ \cValues ->
        allocaArray (length keysAndValues) $ \cKeysPtr ->
          allocaArray (length keysAndValues) $ \cValuesPtr ->
            alloca $ \ffiResultPtr -> do
              pokeArray cKeysPtr cKeys
              pokeArray cValuesPtr cValues
              c_via_map_ffi cScheme cKeysPtr cValuesPtr (fromIntegral $ length keysAndValues) ffiResultPtr
              ffiResult <- peek ffiResultPtr
              if ffiCode ffiResult == 0
                then do
                  op <- Operator <$> (newForeignPtr c_free_operator $ castPtr $ dataPtr ffiResult)
                  return $ Right op
                else do
                  let code = parseErrorCode $ fromIntegral $ ffiCode ffiResult
                  errMsg <- peekCString (errorMessage ffiResult)
                  return $ Left $ OpenDALError code errMsg

readOpRaw :: Operator -> String -> IO (Either OpenDALError ByteString)
readOpRaw (Operator op) path = withForeignPtr op $ \opptr ->
  withCString path $ \cPath ->
    alloca $ \ffiResultPtr -> do
      c_blocking_read opptr cPath ffiResultPtr
      ffiResult <- peek ffiResultPtr
      if ffiCode ffiResult == 0
        then do
          byteslice <- peek (castPtr $ dataPtr ffiResult)
          byte <- byteSliceToByteString byteslice
          c_free_byteslice (bsData byteslice) (bsLen byteslice)
          return $ Right byte
        else do
          let code = parseErrorCode $ fromIntegral $ ffiCode ffiResult
          errMsg <- peekCString (errorMessage ffiResult)
          return $ Left $ OpenDALError code errMsg

writeOpRaw :: Operator -> String -> ByteString -> IO (Either OpenDALError ())
writeOpRaw (Operator op) path byte = withForeignPtr op $ \opptr ->
  withCString path $ \cPath ->
    BS.useAsCStringLen byte $ \(cByte, len) ->
      alloca $ \ffiResultPtr -> do
        c_blocking_write opptr cPath cByte (fromIntegral len) ffiResultPtr
        ffiResult <- peek ffiResultPtr
        if ffiCode ffiResult == 0
          then return $ Right ()
          else do
            let code = parseErrorCode $ fromIntegral $ ffiCode ffiResult
            errMsg <- peekCString (errorMessage ffiResult)
            return $ Left $ OpenDALError code errMsg

isExistOpRaw :: Operator -> String -> IO (Either OpenDALError Bool)
isExistOpRaw (Operator op) path = withForeignPtr op $ \opptr ->
  withCString path $ \cPath ->
    alloca $ \ffiResultPtr -> do
      c_blocking_is_exist opptr cPath ffiResultPtr
      ffiResult <- peek ffiResultPtr
      if ffiCode ffiResult == 0
        then do
          -- For Bool type, the memory layout is different between C and Haskell.
          val <- peek ((castPtr $ dataPtr ffiResult) :: Ptr CChar)
          let isExist = val /= 0
          return $ Right isExist
        else do
          let code = parseErrorCode $ fromIntegral $ ffiCode ffiResult
          errMsg <- peekCString (errorMessage ffiResult)
          return $ Left $ OpenDALError code errMsg

createDirOpRaw :: Operator -> String -> IO (Either OpenDALError ())
createDirOpRaw (Operator op) path = withForeignPtr op $ \opptr ->
  withCString path $ \cPath ->
    alloca $ \ffiResultPtr -> do
      c_blocking_create_dir opptr cPath ffiResultPtr
      ffiResult <- peek ffiResultPtr
      if ffiCode ffiResult == 0
        then return $ Right ()
        else do
          let code = parseErrorCode $ fromIntegral $ ffiCode ffiResult
          errMsg <- peekCString (errorMessage ffiResult)
          return $ Left $ OpenDALError code errMsg

copyOpRaw :: Operator -> String -> String -> IO (Either OpenDALError ())
copyOpRaw (Operator op) srcPath dstPath = withForeignPtr op $ \opptr ->
  withCString srcPath $ \cSrcPath ->
    withCString dstPath $ \cDstPath ->
      alloca $ \ffiResultPtr -> do
        c_blocking_copy opptr cSrcPath cDstPath ffiResultPtr
        ffiResult <- peek ffiResultPtr
        if ffiCode ffiResult == 0
          then return $ Right ()
          else do
            let code = parseErrorCode $ fromIntegral $ ffiCode ffiResult
            errMsg <- peekCString (errorMessage ffiResult)
            return $ Left $ OpenDALError code errMsg

renameOpRaw :: Operator -> String -> String -> IO (Either OpenDALError ())
renameOpRaw (Operator op) srcPath dstPath = withForeignPtr op $ \opptr ->
  withCString srcPath $ \cSrcPath ->
    withCString dstPath $ \cDstPath ->
      alloca $ \ffiResultPtr -> do
        c_blocking_rename opptr cSrcPath cDstPath ffiResultPtr
        ffiResult <- peek ffiResultPtr
        if ffiCode ffiResult == 0
          then return $ Right ()
          else do
            let code = parseErrorCode $ fromIntegral $ ffiCode ffiResult
            errMsg <- peekCString (errorMessage ffiResult)
            return $ Left $ OpenDALError code errMsg

deleteOpRaw :: Operator -> String -> IO (Either OpenDALError ())
deleteOpRaw (Operator op) path = withForeignPtr op $ \opptr ->
  withCString path $ \cPath ->
    alloca $ \ffiResultPtr -> do
      c_blocking_delete opptr cPath ffiResultPtr
      ffiResult <- peek ffiResultPtr
      if ffiCode ffiResult == 0
        then return $ Right ()
        else do
          let code = parseErrorCode $ fromIntegral $ ffiCode ffiResult
          errMsg <- peekCString (errorMessage ffiResult)
          return $ Left $ OpenDALError code errMsg
module EVM.Exec where

import Data.ByteString (ByteString)

import Control.Monad.State.Strict (State, get)
import Control.Lens

import EVM
import EVM.Types
import EVM.Keccak (newContractAddress)

ethrunAddress :: Addr
ethrunAddress = Addr 0x00a329c0648769a73afac7f9381e08fb43dbea72

vmForEthrunCreation :: ByteString -> VM Concrete
vmForEthrunCreation creationCode =
  (makeVm $ VMOpts
    { vmoptCode = creationCode
    , vmoptCalldata = ""
    , vmoptValue = 0
    , vmoptAddress = newContractAddress ethrunAddress 1
    , vmoptCaller = ethrunAddress
    , vmoptOrigin = ethrunAddress
    , vmoptCoinbase = 0
    , vmoptNumber = 0
    , vmoptTimestamp = 0
    , vmoptGaslimit = 0
    , vmoptDifficulty = 0
    }) & set (env . contracts . at ethrunAddress)
             (Just (initialContract mempty))

exec :: State (VM Concrete) VMResult
exec =
  use EVM.result >>= \case
    Nothing -> exec1 >> exec
    Just x  -> return x

execWhile :: (VM Concrete -> Bool) -> State (VM Concrete) ()
execWhile p =
  get >>= \x -> if p x then exec1 >> execWhile p else return ()

-- locateBreakpoint :: UIState -> Text -> Int -> Maybe [(Word256, Vector Bool)]
-- locateBreakpoint ui fileName lineNo = do
--   (i, (t, s)) <-
--     flip find (Map.toList (ui ^. uiSourceCache . sourceFiles))
--       (\(_, (t, _)) -> t == fileName)
--   let ls = BS.split 0x0a s
--       l = ls !! (lineNo - 1)
--       offset = 1 + sum (map ((+ 1) . BS.length) (take (lineNo - 1) ls))
--       horizon = offset + BS.length l
--   return $ Map.elems (ui ^. uiVm . _Just . env . solc)
--     & map (\c -> (
--         c ^. solcCodehash,
--         Vector.create $ new (Seq.length (c ^. solcSrcmap)) >>= \v -> do
--           fst $ foldl' (\(!m, !j) (sm@SM { srcMapOffset = o }) ->
--             if srcMapFile sm == i && o >= offset && o < horizon
--             then (m >> write v j True, j + 1)
--             else (m >> write v j False, j + 1)) (return (), 0) (c ^. solcSrcmap)
--           return v
--       ))

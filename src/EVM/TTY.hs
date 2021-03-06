{-# Language TemplateHaskell #-}

module EVM.TTY where

import Brick
import Brick.Widgets.Border
import Brick.Widgets.Center
import Brick.Widgets.List

import EVM
import EVM.Debug
import EVM.Exec
import EVM.Solidity
import EVM.Types
import EVM.UnitTest

import Control.Lens
import Control.Monad.State.Strict hiding (state)

import Data.ByteString (ByteString)
import Data.Map (Map)
import Data.Maybe (fromJust, isJust)
import Data.Monoid ((<>))
import Data.Text (Text, unpack, pack)
import Data.Text.Encoding (decodeUtf8)
import Data.Tree (drawForest)
import Data.Foldable (toList)
import Data.Word (Word32)

import qualified Data.Map as Map
import qualified Data.Text as Text
import qualified Data.Tree.Zipper as Zipper
import qualified Data.Vector as Vec
import qualified Data.Vector.Storable as SVec
import qualified Graphics.Vty as Vty

data Name
  = AbiPane
  | StackPane
  | BytecodePane
  | LogPane
  | TracePane
  | SolidityPane
  | SolidityViewport
  | TestPickerPane
  deriving (Eq, Show, Ord)

type UiWidget = Widget Name

data UiVmState e = UiVmState
  { _uiVm             :: VM e
  , _uiVmStackList    :: List Name W256
  , _uiVmBytecodeList :: List Name (Int, Op)
  , _uiVmLogList      :: List Name Log
  , _uiVmTraceList    :: List Name String
  , _uiVmSolidityList :: List Name (Int, ByteString)
  , _uiVmSolc         :: Maybe SolcContract
  , _uiVmDapp         :: Maybe DappInfo
  }

data CodeType = Creation | Runtime
  deriving (Show, Eq, Ord)

data DappInfo = DappInfo
  { _dappRoot       :: FilePath
  , _dappSolcByName :: Map Text SolcContract
  , _dappSolcByHash :: Map W256 (CodeType, SolcContract)
  , _dappSources    :: SourceCache
  , _dappUnitTests  :: [(Text, [Text])]
  }

data UiTestPickerState = UiTestPickerState
  { _testPickerList :: List Name (Text, Text)
  , _testPickerDapp :: DappInfo
  }

data UiState e
  = UiVmScreen (UiVmState e)
  | UiTestPickerScreen UiTestPickerState

makeLenses ''DappInfo
makeLenses ''UiVmState
makeLenses ''UiTestPickerState
makePrisms ''UiState

isUnitTestContract :: Text -> DappInfo -> Bool
isUnitTestContract name dapp =
  elem name (map fst (view dappUnitTests dapp))

main :: FilePath -> FilePath -> IO ()
main root jsonFilePath = do
  readSolc jsonFilePath >>=
    \case
      Nothing ->
        error "Failed to read Solidity JSON"
      Just (contractMap, sourceCache) -> do
        let
          solcs     = Map.elems contractMap
          unitTests = findUnitTests solcs

          mkVty = do
            vty <- Vty.mkVty Vty.defaultConfig
            Vty.setMode (Vty.outputIface vty) Vty.BracketedPaste True
            return vty

          dappInfo = DappInfo
              { _dappRoot       = root
              , _dappUnitTests  = unitTests
              , _dappSolcByName = contractMap
              , _dappSources    = sourceCache
              , _dappSolcByHash =
                  mappend
                    (Map.fromList [(view runtimeCodehash c, (Runtime, c)) | c <- solcs])
                    (Map.fromList [(view creationCodehash c, (Creation, c)) | c <- solcs])
              }

          ui = UiTestPickerScreen $ UiTestPickerState
            { _testPickerList =
                list
                  TestPickerPane
                  (Vec.fromList
                   (concatMap
                    (\(a, xs) -> [(a, x) | x <- xs])
                    unitTests))
                  1
            , _testPickerDapp = dappInfo
            }

        _ <- customMain mkVty Nothing app (ui :: UiState Concrete)
        return ()

app :: App (UiState Concrete) () Name
app = App
  { appDraw = drawUi
  , appChooseCursor = neverShowCursor
  , appHandleEvent = \s e ->

      case (s, e) of
        (_, VtyEvent (Vty.EvKey Vty.KEsc []) )->
          halt s

        (UiVmScreen s', VtyEvent (Vty.EvKey (Vty.KChar 'n') [])) ->
          continue (UiVmScreen (stepOneOpcode s'))

        (UiVmScreen s', VtyEvent (Vty.EvKey (Vty.KChar 'N') [])) ->
          continue (UiVmScreen (stepOneSourcePosition s'))

        (UiTestPickerScreen s', VtyEvent (Vty.EvKey (Vty.KEnter) [])) -> do
          case listSelectedElement (view testPickerList s') of
            Nothing -> error "nothing selected"
            Just (_, x) ->
              continue . UiVmScreen $
                initialUiVmStateForTest (view testPickerDapp s') x

        (UiTestPickerScreen s', VtyEvent e') -> do
          s'' <- handleEventLensed s'
            testPickerList
            handleListEvent
            e'
          continue (UiTestPickerScreen s'')

        _ -> continue s

  , appStartEvent = return
  , appAttrMap = const (attrMap Vty.defAttr myTheme)
  }

initialUiVmStateForTest :: DappInfo -> (Text, Text) -> UiVmState Concrete
initialUiVmStateForTest dapp (theContractName, theTestName) =
  let
     Just testContract = view (dappSolcByName . at theContractName) dapp
     vm0 = initialUnitTestVm testContract (Map.elems (view dappSolcByName dapp))
     vm2 = case runState exec vm0 of
       (VMFailure e, _) -> error $ "creation error: " ++ show e
       (VMSuccess targetCode, vm1) ->
         execState (performCreation targetCode) vm1
     target = view (state . contract) vm2
     vm3 = vm2 & env . contracts . ix target . balance +~ 0xffffffffffffffffffffffff
     vm4 = flip execState vm3 $ do
       setupCall target "setUp()"
     vm = case runState exec vm4 of
       (VMFailure e, _) -> error $ "setUp() failed: " ++ show e
       (VMSuccess _, vm5) ->
         flip execState vm5 $ do
           setupCall target theTestName
           assign contextTrace (Zipper.fromForest [])
           assign logs mempty
  in
    mkUiVmState vm (Just dapp)

myTheme :: [(AttrName, Vty.Attr)]
myTheme =
  [ (selectedAttr, Vty.defAttr `Vty.withStyle` Vty.standout)
  , (dimAttr, Vty.defAttr `Vty.withStyle` Vty.dim)
  , (borderAttr, Vty.defAttr `Vty.withStyle` Vty.dim)
  , (wordAttr, fg Vty.yellow)
  , (boldAttr, Vty.defAttr `Vty.withStyle` Vty.bold)
  , (activeAttr, Vty.defAttr `Vty.withStyle` Vty.standout)
  ]

drawUi :: Machine e => UiState e -> [UiWidget]
drawUi (UiVmScreen s) = drawVm s
drawUi (UiTestPickerScreen s) = drawTestPicker s

drawTestPicker :: UiTestPickerState -> [UiWidget]
drawTestPicker ui =
  [ center . borderWithLabel (txt "Unit tests") .
      hLimit 80 $
        renderList
          (\selected (x, y) ->
             withHighlight selected $
               txt " Debug " <+> txt (contractNamePart x) <+> txt "::" <+> txt y)
          True
          (view testPickerList ui)
  ]

drawVm :: Machine e => UiVmState e -> [UiWidget]
drawVm ui =
  [ vBox
    [ vLimit 20 $ hBox
      [ drawStackPane ui <+> vBorder
      , drawLogPane ui <+> vBorder
      , drawTracePane ui
      ]
    , hBox $
      [ hLimit 72 $ drawBytecodePane ui
      , drawSolidityPane ui
      ]
    ]
  ]

stepOneOpcode :: Machine e => UiVmState e -> UiVmState e
stepOneOpcode ui =
  let
    nextVm = execState exec1 (view uiVm ui)
  in mkUiVmState nextVm (view uiVmDapp ui)

stepOneSourcePosition :: UiVmState Concrete -> UiVmState Concrete
stepOneSourcePosition ui =
  let
    vm              = view uiVm ui
    Just dapp       = view uiVmDapp ui
    initialPosition = currentSrcMap dapp vm
    stillHere s     = currentSrcMap dapp s == initialPosition
    nextVm          = execState (execWhile stillHere) vm
  in mkUiVmState nextVm (Just dapp)

currentSrcMap :: Machine e => DappInfo -> VM e -> Maybe SrcMap
currentSrcMap dapp vm =
  let
    this = vm ^?! env . contracts . ix (view (state . contract) vm)
    i = (view opIxMap this) SVec.! (view (state . pc) vm)
    h = view codehash this
  in
    case preview (dappSolcByHash . ix h) dapp of
      Nothing ->
        Nothing
      Just (Creation, solc) ->
        preview (creationSrcmap . ix i) solc
      Just (Runtime, solc) ->
        preview (runtimeSrcmap . ix i) solc

currentSolc :: Machine e => DappInfo -> VM e -> Maybe SolcContract
currentSolc dapp vm =
  let
    this = vm ^?! env . contracts . ix (view (state . contract) vm)
    h = view codehash this
  in
    preview (dappSolcByHash . ix h . _2) dapp

mkUiVmState :: Machine e => VM e -> Maybe DappInfo -> UiVmState e
mkUiVmState vm Nothing =
  let
    move = case vmOpIx vm of
             Nothing -> id
             Just x -> listMoveTo x
  in UiVmState
    { _uiVm = vm
    , _uiVmDapp = Nothing
    , _uiVmSolc = Nothing
    , _uiVmStackList =
        list StackPane (Vec.fromList $ view (state . stack) vm) 1
    , _uiVmBytecodeList =
        move $ list BytecodePane
          (Vec.imap (,) (view codeOps (fromJust (currentContract vm))))
          1
    , _uiVmLogList = list LogPane (Vec.fromList . toList $ view logs vm) 1
    , _uiVmTraceList =
        list
          TracePane
          mempty
          1
    , _uiVmSolidityList =
        list SolidityPane mempty 1
    }

mkUiVmState vm (Just dapp) =
  let
    sm = currentSrcMap dapp vm
    move = case vmOpIx vm of
             Nothing -> id
             Just x -> listMoveTo x
  in UiVmState
    { _uiVm = vm
    , _uiVmDapp = Just dapp
    , _uiVmSolc = currentSolc dapp vm
    , _uiVmStackList =
        list StackPane (Vec.fromList $ view (state . stack) vm) 1
    , _uiVmBytecodeList =
        move $ list BytecodePane
          (Vec.imap (,) (view codeOps (fromJust (currentContract vm))))
          1
    , _uiVmLogList = list LogPane (Vec.fromList . toList $ view logs vm) 1
    , _uiVmTraceList =
        list
          TracePane
          (Vec.fromList
           . lines
           . drawForest
           . fmap (fmap (unpack . showContext dapp))
           $ contextTraceForest vm)
          1
    , _uiVmSolidityList =
        list SolidityPane
          (case sm of
             Nothing -> mempty
             Just x ->
               view (dappSources
                     . sourceLines
                     . ix (srcMapFile x)
                     . to (Vec.imap (,)))
                 dapp)
          1
    }

maybeContractName :: Maybe SolcContract -> Text
maybeContractName =
  maybe "<unknown contract>" (view (contractName . to contractNamePart))

maybeAbiName :: SolcContract -> Word32 -> Maybe Text
maybeAbiName solc abi = preview (abiMap . ix abi) solc

showContext :: DappInfo -> Either Log FrameContext -> Text
showContext _ (Left (Log _ bytes topics)) =
  "LOG " <> pack (show bytes) <> " " <> pack (show topics)
showContext dapp (Right (CreationContext hash)) =
  "CREATE " <> maybeContractName (preview (dappSolcByHash . ix hash . _2) dapp)
showContext dapp (Right (CallContext _ _ hash abi _)) =
  case preview (dappSolcByHash . ix hash . _2) dapp of
    Nothing ->
      "CALL [unknown]"
    Just solc ->
      "CALL "
        <> view (contractName . to contractNamePart) solc
        <> " "
        <> maybe "[fallback function]"
             (\x -> maybe "[unknown method]" id (maybeAbiName solc x))
             abi

drawStackPane :: Machine e => UiVmState e -> UiWidget
drawStackPane ui =
  hBorderWithLabel (txt "Stack") <=>
    renderList
      (\_ x -> str (show x))
      False
      (view uiVmStackList ui)

drawBytecodePane :: Machine e => UiVmState e -> UiWidget
drawBytecodePane ui =
  hBorderWithLabel (txt "Bytecode " <+> str (show (view (uiVm . result) ui))) <=>
    renderList
      (\active x -> if not active
                    then withDefAttr dimAttr (opWidget x)
                    else withDefAttr boldAttr (opWidget x))
      False
      (view uiVmBytecodeList ui)

withHighlight :: Bool -> Widget n -> Widget n
withHighlight False = withDefAttr dimAttr
withHighlight True  = withDefAttr boldAttr

drawLogPane :: Machine e => UiVmState e -> UiWidget
drawLogPane ui =
  hBorderWithLabel (txt "Logs") <=>
    renderList
      (\_ (Log _ bs ws) -> str (show bs) <+> txt " " <+> str (show ws))
      False
      (view uiVmLogList ui)

drawTracePane :: Machine e => UiVmState e -> UiWidget
drawTracePane ui =
  hBorderWithLabel (txt "Trace") <=>
    renderList
      (\_ x -> str x)
      False
      (view uiVmTraceList ui)

drawSolidityPane :: Machine e => UiVmState e -> UiWidget
drawSolidityPane ui | not (isJust (view uiVmDapp ui)) = vBox []
drawSolidityPane ui =
  let
    Just dapp = view uiVmDapp ui
    sm = fromJust $ currentSrcMap dapp (view uiVm ui)
    rows = fromJust $ view (dappSources . sourceLines . at (srcMapFile sm)) dapp
    subrange i = lineSubrange rows (srcMapOffset sm, srcMapLength sm) i
    lineNo =
      (snd . fromJust $
        (srcMapCodePos
         (view dappSources dapp)
         sm)) - 1
  in vBox
    [ hBorderWithLabel
        (txt (maybe "<unknown>" contractNamePart
              (preview (uiVmSolc . _Just . contractName) ui)))
    , renderList
        (\_ (i, line) ->
           let s = case decodeUtf8 line of "" -> " "; y -> y
           in case subrange i of
                Nothing -> withHighlight False (txt s)
                Just (a, b) ->
                  let (x, y, z) = ( Text.take a s
                                  , Text.take b (Text.drop a s)
                                  , Text.drop (a + b) s
                                  )
                  in hBox [ withHighlight False (txt x)
                          , withHighlight True (txt y)
                          , withHighlight False (txt z)
                          ])
        False
        (listMoveTo lineNo
          (view uiVmSolidityList ui))
    ]

contractNamePart :: Text -> Text
contractNamePart x = Text.split (== ':') x !! 1

contractPathPart :: Text -> Text
contractPathPart x = Text.split (== ':') x !! 0

opWidget :: Show a => (a, Op) -> Widget n
opWidget (i, o) = str (show i ++ " ") <+> case o of
  OpStop -> txt "STOP"
  OpAdd -> txt "ADD"
  OpMul -> txt "MUL"
  OpSub -> txt "SUB"
  OpDiv -> txt "DIV"
  OpSdiv -> txt "SDIV"
  OpMod -> txt "MOD"
  OpSmod -> txt "SMOD"
  OpAddmod -> txt "ADDMOD"
  OpMulmod -> txt "MULMOD"
  OpExp -> txt "EXP"
  OpSignextend -> txt "SIGNEXTEND"
  OpLt -> txt "LT"
  OpGt -> txt "GT"
  OpSlt -> txt "SLT"
  OpSgt -> txt "SGT"
  OpEq -> txt "EQ"
  OpIszero -> txt "ISZERO"
  OpAnd -> txt "AND"
  OpOr -> txt "OR"
  OpXor -> txt "XOR"
  OpNot -> txt "NOT"
  OpByte -> txt "BYTE"
  OpSha3 -> txt "SHA3"
  OpAddress -> txt "ADDRESS"
  OpBalance -> txt "BALANCE"
  OpOrigin -> txt "ORIGIN"
  OpCaller -> txt "CALLER"
  OpCallvalue -> txt "CALLVALUE"
  OpCalldataload -> txt "CALLDATALOAD"
  OpCalldatasize -> txt "CALLDATASIZE"
  OpCalldatacopy -> txt "CALLDATACOPY"
  OpCodesize -> txt "CODESIZE"
  OpCodecopy -> txt "CODECOPY"
  OpGasprice -> txt "GASPRICE"
  OpExtcodesize -> txt "EXTCODESIZE"
  OpExtcodecopy -> txt "EXTCODECOPY"
  OpBlockhash -> txt "BLOCKHASH"
  OpCoinbase -> txt "COINBASE"
  OpTimestamp -> txt "TIMESTAMP"
  OpNumber -> txt "NUMBER"
  OpDifficulty -> txt "DIFFICULTY"
  OpGaslimit -> txt "GASLIMIT"
  OpPop -> txt "POP"
  OpMload -> txt "MLOAD"
  OpMstore -> txt "MSTORE"
  OpMstore8 -> txt "MSTORE8"
  OpSload -> txt "SLOAD"
  OpSstore -> txt "SSTORE"
  OpJump -> txt "JUMP"
  OpJumpi -> txt "JUMPI"
  OpPc -> txt "PC"
  OpMsize -> txt "MSIZE"
  OpGas -> txt "GAS"
  OpJumpdest -> txt "JUMPDEST"
  OpCreate -> txt "CREATE"
  OpCall -> txt "CALL"
  OpCallcode -> txt "CALLCODE"
  OpReturn -> txt "RETURN"
  OpDelegatecall -> txt "DELEGATECALL"
  OpSelfdestruct -> txt "SELFDESTRUCT"
  OpDup x -> txt "DUP" <+> str (show x)
  OpSwap x -> txt "SWAP" <+> str (show x)
  OpLog x -> txt "LOG" <+> str (show x)
  OpPush x -> txt "PUSH " <+> withDefAttr wordAttr (str (show x))
  OpRevert -> txt "REVERT"
  OpUnknown x -> txt "UNKNOWN " <+> str (show x)

selectedAttr :: AttrName; selectedAttr = "selected"
dimAttr :: AttrName; dimAttr = "dim"
wordAttr :: AttrName; wordAttr = "word"
boldAttr :: AttrName; boldAttr = "bold"
activeAttr :: AttrName; activeAttr = "active"
